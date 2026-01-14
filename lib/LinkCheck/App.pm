package LinkCheck::App;
use v5.42;
use utf8::all;

use Mooish::Base -standard;
with 'WebFramework::Role::Logger';

require MCE::Mutex;
require MCE::Shared;
require Future::HTTP;
use MCE::Loop;
use MCE::Queue;
use MCE;
use Sereal::Encoder;
use Sereal::Decoder;
use Time::HiRes qw(time);
use URI;
use XML::LibXML;
use XML::LibXML::XPathContext;

use Carp;

use LinkCheck::Worker ();

has start => (
  required => 1,
  is       => 'rw',
  coerce   => sub {
    my $val = shift;
    return ref($val) eq 'URI' ? $val : URI->new($val);
  },
);

has workers => (
  is      => 'ro',
  default => 8,
);

has max_retries => (
  default => 3,
  is      => 'ro',
);

has request_timeout => (
  default => 60,
  is      => 'ro',
);

has inactive_timeout => (
  default => 30,
  is      => 'ro',
);

has job_timeout => (
  default => 60,
  is      => 'ro',
);

has max_pages => (
  default => 0,
  is      => 'ro',
);

has max_external => (
  default => 0,
  is      => 'ro',
);

has same_host_only => (
  default => 1,
  is      => 'ro',
);

has verbose => (
  default => 1,
  is      => 'ro',
);

# for use by logging
has env => (
  lazy    => 1,
  default => sub {
    my $self = shift;
    my $e    = $self->verbose ? 'development' : 'production';
    say "env is $e";
    return $e;
  },
  is => 'ro',
);


has encoder => (
  default => sub { return Sereal::Encoder->new();},
  is      => 'ro',
);

has decoder => (
  default => sub { return Sereal::Decoder->new();},
  is      => 'ro',
);

#### internal variables

has base_host => (is => 'rw',);

has base_url => (is => 'rw');


has _internal_pending_count => (
  default   => 0,
  is        => 'rw',
);

has _internal_q => (
  default => sub {
    return MCE::Shared->hash();
  },
  is => 'rw',
);

has _external_q => (
  default => sub {
    {}
  },
  is => 'rw',
);

has _broken => (
  default => sub { {} },
  is      => 'rw',
);

has _inflight  => (is => 'rw');
has _stop_sent => (is => 'rw');

has external_min_interval => (is => 'ro', default => 1.0)
  ;    # seconds between requests per host
has external_jitter => (is => 'ro', default => 0.2);  # random 0..jitter seconds
has external_host_slots => (is => 'ro', default => 1)
  ;    # max concurrent requests per host (usually 1)

has _host_lock      => (
  default   => sub { return MCE::Mutex->new; },
  is        => 'rw',
);

has _host_next_time => (is => 'rw');
has _host_inflight  => (is => 'rw');

# Do not access directly, access via
# $self->_new_queue_item;
has _queue_item => (
  default   => sub {
    return {
      pending_internal_links  => [],
      pending_external_links  => [],
      possible_anchors        => [],
      pending_anchor_refs     => [],
      successfull_internal_links  => [],
      successfull_external_links  => [],
      successfull_anchor_refs     => [],
      broken_internal_links  => [],
      broken_external_links  => [],
      broken_anchors         => [],
      broken_anchor_refs     => [],
      checked                => 0,
    }
  },
  is => 'ro',
);


# entry point
sub execute ($self) {
  $self->ensure_logging(__PACKAGE__);
  $self->start(URI->new($self->start));
  $self->base_host(lc $self->start->host);

  $self->base_url($self->start->clone);
  $self->base_url->fragment(undef);
  $self->base_url->query(undef);
  $self->base_url->path(undef);
  $self->logger->debug("base host is " . $self->base_host);
  say "About to store queue item for: " . $self->start->as_string;
  say "Queue item type: " . ref($self->_new_queue_item());
  $self->_internal_q->{$self->start->as_string} = $self->_new_queue_item();

  # Extract constructor params - don't capture $self in closure
  my $start_url = $self->start->as_string;
  my $base_url = $self->base_url->as_string;
  my $base_host = $self->base_host;
  my $workers = $self->workers;
  my $max_retries = $self->max_retries;
  my $request_timeout = $self->request_timeout;
  my $inactive_timeout = $self->inactive_timeout;
  my $job_timeout = $self->job_timeout;
  my $max_pages = $self->max_pages;
  my $max_external = $self->max_external;
  my $same_host_only = $self->same_host_only;
  my $verbose = $self->verbose;
  my $internal_q = $self->_internal_q;
  my $host_lock = $self->_host_lock;

  my $mce = MCE->new(
     max_workers  => $workers,
     user_func    => sub {
      my ($mce) = @_;

      # Create a fresh instance in this worker process
      my $worker_app = LinkCheck::App->new(
         start => $start_url,
         workers => 1,
         max_retries => $max_retries,
         request_timeout => $request_timeout,
         inactive_timeout => $inactive_timeout,
         job_timeout => $job_timeout,
         max_pages => $max_pages,
         max_external => $max_external,
         same_host_only => $same_host_only,
         verbose => $verbose,
      );

      # Set base_url and base_host that were computed in main instance
      $worker_app->base_url(URI->new($base_url));
      $worker_app->base_host($base_host);

      # Use the shared queue and lock from the parent
      $worker_app->_internal_q($internal_q);
      $worker_app->_host_lock($host_lock);

      $worker_app->mce_user_func($mce, $internal_q);
     },
     max_retries  => $max_retries,
  );
  MCE::Shared->start();

   $mce->run;
}

sub mce_user_func ($self, $mce, $internal_q) {
  my ( $pid, $wid ) = ( MCE->pid, MCE->wid );
  my $key;
  my $no_work_count = 0;
  my @in_progress;
  do {
    $self->_host_lock->lock;

    my @all_keys = $internal_q->keys();
    my @unchecked = grep { $internal_q->{$_}->{state} eq 'unchecked' } @all_keys;
    @in_progress = grep { $internal_q->{$_}->{state} eq 'in-progress' } @all_keys;

    $key = $unchecked[0];
    if ($key) {
      $internal_q->{$key}->{state} = 'in-progress';
      $no_work_count = 0;
      say "pid $pid; wid $wid; claimed key $key";
    } elsif (@in_progress) {
      # Other workers are still processing, wait for them to add more work
      $no_work_count = 0;
      say "pid $pid; wid $wid; no unchecked keys, but work in progress, will retry";
    } else {
      # No unchecked, no in-progress = truly done
      $no_work_count++;
      say "pid $pid; wid $wid; no work found (count: $no_work_count)";
    }

    $self->_host_lock->unlock;

    if ($key) {
      $self->get_internal_url($key);
    } elsif (@in_progress || $no_work_count < 3) {
      # Brief sleep to avoid spinning
      select(undef, undef, undef, 0.1);
    }
  } while ($key || @in_progress || $no_work_count < 3);

  say "pid $pid; wid $wid; exiting - no more work";
}

sub _new_queue_item ($self) {
  $self->_internal_pending_count($self->_internal_pending_count + 1);
  # Return a plain hash - don't reference $self->_queue_item which has code refs
  return {
    pending_internal_links     => [],
    pending_external_links     => [],
    possible_anchors           => [],
    pending_anchor_refs        => [],
    successfull_internal_links => [],
    successfull_external_links => [],
    successfull_anchor_refs    => [],
    broken_internal_links      => [],
    broken_external_links      => [],
    broken_anchors             => [],
    broken_anchor_refs         => [],
    state                      => 'unchecked',
  };
}


sub get_internal_url($self, $url){
  return unless($url &&  length($url));
  unless($self->_internal_q->exists($url)){
    my $errmsg = "no internal queue entry for $url";
    $self->logger->error($errmsg);
    warn($errmsg);
    return;
  }
  return if($self->_internal_q->{$url}->{state} eq 'checked');
  say "getting internal url $url";
  my $ua = Future::HTTP->new();
  my $res = $ua->http_get($url)->then(sub {
      my( $body, $data ) = @_;
      my $extracted = $self->process_url($url, $body, $data);

      # Store the extracted data (plain arrays/strings only)
      $self->_internal_q->{$url}->{pending_internal_links} = $extracted->{internal_links};
      $self->_internal_q->{$url}->{pending_external_links} = $extracted->{external_links};
      $self->_internal_q->{$url}->{pending_anchor_refs} = $extracted->{anchor_refs};
      $self->_internal_q->{$url}->{possible_anchors} = $extracted->{anchors};

      foreach my $link ( @{ $extracted->{internal_links} }){
        if($link =~ /^\//){
          $link = sprintf('%s%s', $self->base_url, $link);
        }
        my $uri = URI->new($link);
        my $host = $uri->clone;
        $host->fragment(undef);  # Remove fragment (#anchor)
        $host->query(undef);     # Remove query string (?param=value)
        my $base_url = $host->as_string;
        unless(exists $self->_internal_q->{$base_url}){
          $self->_internal_q->{$base_url} = $self->_new_queue_item;
        }
      }
  })->get();
  $self->_internal_q->{$url}->{state} = 'checked';
}

sub process_url ($self, $url, $body, $data) {
  local(*STDERR);
  open STDERR, '>>', File::Spec->devnull();
  my $dom = XML::LibXML->load_xml(
    string => $body,
    recover   => 1,
    suppress_errors => 1,
  );

  my $host = $self->base_host;
  unless($self->start->host_port =~ /(?:80|443)$/ ){
    $host = sprintf('%s:%s', $host, $self->start->port);
  }
  $self->logger->debug("host is $host");

  my @all_links = $dom->findnodes('//a[@href]');
  $self->logger->debug(sprintf('Found %s total <a> tags with href', scalar(@all_links)));

  my @internal_links;
  my @external_links;
  my @anchor_refs;
  my @anchors;

  foreach my $linknode (@all_links) {
    my $href = $linknode->getAttribute('href');
    next unless $href;

    if ($href =~ m{^#} ) {
      $self->logger->debug("  -> anchor: $href");
      push @anchor_refs, $href;
    }
    elsif ($href =~ m{^/} || $href =~ /\Q$host\E/) {
      $self->logger->debug("  -> internal: $href");
      push @internal_links, $href;
    }
    else {
      push @external_links, $href;
      $self->logger->debug("  -> external: $href ");
    }
  }

  my @elements_with_id = $dom->findnodes('//*[@id]');
  $self->logger->debug(sprintf('Found %s elements with id attribute', scalar(@elements_with_id)));

  foreach my $element (@elements_with_id) {
    my $id = $element->getAttribute('id');
    if ($id) {
      $self->logger->debug("  -> anchor target: #$id");
      push @anchors, $id;
    }
  }

  $self->logger->info(sprintf('Total anchor targets found: %s', scalar(@anchors)));

  return {
    internal_links => \@internal_links,
    external_links => \@external_links,
    anchor_refs => \@anchor_refs,
    anchors => \@anchors,
  };
}

sub _done ($self) {

  return $self->{_internal_q}->pending == 0
    && $self->{_external_q}->pending == 0;
}


1;
__END__
