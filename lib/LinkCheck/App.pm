package LinkCheck::App;
use v5.42;
use utf8::all;

use Mooish::Base -standard;
with 'LinkCheck::Role::Logger';
with 'LinkCheck::Role::State';
with 'LinkCheck::Role::Fetcher';
use LinkCheck::Util::URL qw(canon_uri canon_url_string);

require Path::Tiny;

use Sereal       qw( encode_sereal decode_sereal );
use Time::HiRes  qw(time sleep);
use Scalar::Util qw(blessed);
use URI;

use MCE;
use MCE::Step;

use Carp;

has start => (
  required => 1,
  is       => 'ro',
  coerce   => sub ($val) {
    return ref($val) eq 'URI' ? $val : URI->new($val);
  },
);

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

  $self->start(canon_uri($self->start));
  my $start_url_str = $self->start->as_string;

  $self->logger->debug("base host is " . $self->base->{host});
  my %seen;
  my @pending = ($start->as_string);
  $seen{ $pending[0] } = 1;

  my @all_page_summaries;    # whatever Parser emits per page

  my $fetch_workers = $self->workers - 1;
  $fetch_workers = 1 if $fetch_workers < 1;
  my $parse_workers = 1;

  while (@pending) {
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
      "wave done: in=%d fetched=%d parsed=%d next=%d total_seen=%d",
      scalar(@wave),    scalar(@phase1), scalar(@phase2),
      scalar(@pending), scalar(keys %seen),
    ));
  }

  # Final validation pass (anchors, cross-page checks, etc.)
  my @validation_out = mce_step {
    task_name   => ['Validate'],
    max_workers => [$self->workers],
    } \&LinkCheck::Role::Validator::validate_task,
    \@all_page_summaries;

  my @final = map { ref($_) eq 'ARRAY' ? @$_ : $_ } @validation_out;

# Generate report from @final (or from master-owned state you updated during merges)
  $self->_done_from_results(\@final);

}

sub _done ($self) {

  # Print summary of broken links
  say "\n=== BROKEN LINKS SUMMARY ===\n";

  my $total_broken = 0;
  my @all_keys     = sort $self->_internal_q->keys();

  foreach my $url (@all_keys) {
    my $entry = $self->_internal_q->{$url};

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
