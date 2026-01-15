package LinkCheck::App;
use v5.42;
use utf8::all;

use Mooish::Base -standard;
with 'WebFramework::Role::Logger';
extends 'LinkCheck::Common';

use Carp;

use LinkCheck::Worker ();

# entry point
sub execute ($self) {
  MCE::Shared->start();
  MCE::Shared->init();
  $self->start($self->canon_url($self->start));

  $self->logger->debug("base host is " . $self->base->{host});
  say "About to store queue item for: " . $self->start->as_string;
  say "Queue item type: " . ref($self->_new_queue_item());
  $self->_internal_q->{ $self->start->as_string } = $self->_new_queue_item();

  # Extract constructor params - don't capture $self in closure
  my $start_url        = $self->start->as_string;
  my $base_url         = $self->base->{url}->as_string;
  my $base_host        = $self->base->{host};
  my $workers          = $self->workers;
  my $max_retries      = $self->max_retries;
  my $request_timeout  = $self->request_timeout;
  my $inactive_timeout = $self->inactive_timeout;
  my $job_timeout      = $self->job_timeout;
  my $same_host_only   = $self->same_host_only;
  my $verbose          = $self->verbose;
  my $internal_q       = $self->_internal_q;
  my $host_lock        = $self->_host_lock;

  my $mce = MCE->new(
    max_workers => $workers,
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
      $worker_app->_internal_q($self->_internal_q);
      $worker_app->_external_q($self->_external_q);
      $worker_app->_worker_phase($self->_worker_phase);
      $worker_app->_phase_lock($self->_phase_lock);
      $worker_app->_host_lock($self->_host_lock);

      $worker_app->mce_user_func($mce, $self->_internal_q, $self->_external_q);
    },
    max_retries => $max_retries,
  );

  $mce->run;
  $self->_done;
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
