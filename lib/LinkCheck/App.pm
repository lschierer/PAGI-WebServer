package LinkCheck::App;
use v5.42;
use utf8::all;

use Mooish::Base -standard;
with 'LinkCheck::Role::Logger';
with 'LinkCheck::Role::State';
with 'LinkCheck::Role::Fetcher';
with 'LinkCheck::Role::Validator';
use LinkCheck::Util qw(canon_uri canon_url_string);

require Path::Tiny;

use Sereal       qw( encode_sereal decode_sereal );
use Time::HiRes  qw(time sleep);
use Scalar::Util qw(blessed);
use URI;

use MCE;
use MCE::Step;

use Carp;

has param start => (
  required => 1,
  is       => 'rw',
  coerce   => sub  ($val) {
    return ref($val) eq 'URI' ? $val : URI->new($val);
  },
  default => sub {
    return URI->new('http://localhost:300');
  }
);

sub base {
    my $self = shift;
    my $u  = $self->start->clone;
    say "start is $u";
    $u->fragment(undef);
    $u->query(undef);
    $u->path('/');
    my $h = {
      host => lc($u->host),
      url  => $u,
    };
    return $h;
  }



has param workers => (
  is      => 'ro',
  default => 8,
);

has option chunk_size => (
  is      => 'ro',
  default => 1,
);

# entry point
sub execute ($self) {
  MCE::Shared->start();
  MCE::Shared->init();
  MCE::Step->init(
    chunk_size  => $self->chunk_size,
    max_workers => $self->workers,
    freeze      => \&encode_sereal,
    thaw        => \&decode_sereal,
  );

  my $start_url_str = $self->start->as_string;

  unless(defined($self->start) && blessed($self->start)){
    croak('start must be defined as a URI');
    return;
  }
  $self->logger->notice(sprintf('starting url is "%s"', $self->start));

  my @pending = ($self->start->as_string);
  my %seen;
  $seen{ $pending[0] } = 1;

  my @all_page_summaries;    # whatever Parser emits per page

  my $fetch_workers = $self->workers - 1;
  $fetch_workers = 1 if $fetch_workers < 1;
  my $parse_workers = 1;

  my $wave_num = 0;
  while (@pending) {
    $wave_num++;
    my @wave = @pending;
    @pending = ();

    my @phase1 = mce_step {
      task_name   => ['Fetcher'],
      max_workers => [$self->workers],
      },
      \&LinkCheck::Role::Fetcher::fetch_task, \@wave;

    my @flat = map { ref($_) eq 'ARRAY' ? @$_ : $_ } @phase1;

    my @phase2 = mce_step {
      task_name   => ['Parser'],
      max_workers => [$self->workers],
      },
      \&LinkCheck::Role::Parser::parse_task, \@flat;

    @flat = map { ref($_) eq 'ARRAY' ? @$_ : $_ } @phase2;
    push @all_page_summaries, @flat;

    for my $page (@flat) {
      for my $u (@{ $page->{discovered_internal} // [] }) {
        my $canon = canon_uri($u)->as_string;
        next if $seen{$canon}++;
        push @pending, $canon;
      }
      # stash external for later
    }
    $self->logger->info(sprintf(
      "wave %d done: in=%d fetched=%d parsed=%d next=%d total_seen=%d",
      $wave_num,        scalar(@wave),    scalar(@phase1), scalar(@phase2),
      scalar(@pending), scalar(keys %seen),
    ));
  }

  # set context for the duration of this mce_step call
  my $page_index = MCE::Shared->hash();
  for my $p (@all_page_summaries) {
    my $url = $p->{url} // next;
    $url = canon_url_string($url);
    
    # Debug logging for the specific page
    if ($url =~ m{/Harrypedia/History$}) {
      $self->logger->debug("Found History page in summaries: url=$url, ok=" . ($p->{ok} // 'undef') . ", http_status=" . ($p->{http_status} // 'undef'));
    }
    
    # Store what you need for validation
    $page_index->set(
      $url,
      {
        ok          => $p->{ok} ? 1 : 0,
        http_status => 0+ ($p->{http_status} // 0),
      }
    );
  }
  my $known_pages = MCE::Shared->hash();
  $known_pages->set($_, 1) for keys %seen;
  local $LinkCheck::Role::Validator::CTX = {
    known_pages => $known_pages,
    page_index  => $page_index,
    # anchors_by_page => $anchors_by_page,
  };

  # Final validation pass (anchors, cross-page checks, etc.)
  my @validation_out = mce_step {
    task_name   => ['Validate'],
    max_workers => [$self->workers],
    }, \&LinkCheck::Role::Validator::validate_task,
    \@all_page_summaries;

  my @final = map { ref($_) eq 'ARRAY' ? @$_ : $_ } @validation_out;

# Generate report from @final (or from master-owned state you updated during merges)
  $self->_done(\@final);

}

sub _done ($self, $final_results) {

  # Print summary of broken links
  say "\n=== BROKEN LINKS SUMMARY ===\n";

  my $total_broken = 0;

  @{ $final_results } = sort { $a->{source_url} cmp $b->{source_url} } $final_results->@*;

  foreach my $entry (@{ $final_results }) {
    my $url = $entry->{source_url};

    my @broken_internal = @{ $entry->{broken_internal_links} // [] };
    my @broken_external = @{ $entry->{broken_external_links} // [] };
    my @broken_anchors  = @{ $entry->{broken_anchor_refs}    // [] };

    next unless (@broken_internal || @broken_external || @broken_anchors);

    say "Page: $url";

    if (@broken_internal) {
      say "  Broken internal links:";
      say "    - $_" for @broken_internal;
    }

    if (@broken_external) {
      say "  Broken external links:";
      say "    - $_" for @broken_external;
    }

    if (@broken_anchors) {
      say "  Broken anchor refs:";
      say "    - $_->{url}$_->{anchor}" for @broken_anchors;
    }

    say "";
    $total_broken++;
  }

  say $total_broken
    ? "Found broken links on $total_broken pages"
    : "No broken links found!";

}

1;
__END__
my $mce = MCE->new(
  max_workers => $workers,
  job_delay   => 0.060,
  user_func   => sub {
    my ($mce) = @_;

    # Create a fresh instance in this worker process
    my $worker_app = LinkCheck::Worker->new(
      start            => $self->start->as_string,
      workers          => $self->workers,
      max_retries      => $self->max_retries,
      request_timeout  => $self->request_timeout,
      inactive_timeout => $self->inactive_timeout,
      job_timeout      => $self->job_timeout,
      same_host_only   => $self->same_host_only,
      verbose          => $self->verbose,
    );

    # Set base_url and base_host that were computed in main instance

    # Use the shared queue and lock from the parent
    $worker_app->_external_q($self->_external_q);
    $worker_app->_host_inflight($self->_host_inflight);
    $worker_app->_host_lock($self->_host_lock);
    $worker_app->_host_next_time($self->_host_next_time);
    $worker_app->_internal_q($self->_internal_q);
    $worker_app->_phase_lock($self->_phase_lock);
    $worker_app->_stateCounts($self->_stateCounts);

    $worker_app->mce_user_func($mce);
  },
  max_retries => $max_retries,
);
