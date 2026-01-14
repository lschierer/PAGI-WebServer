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
  $self->ensure_logging(__PACKAGE__);
  $self->start(URI->new($self->start));

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
        start            => $start_url,
        workers          => 1,
        max_retries      => $max_retries,
        request_timeout  => $request_timeout,
        inactive_timeout => $inactive_timeout,
        job_timeout      => $job_timeout,
        same_host_only   => $same_host_only,
        verbose          => $verbose,
      );

      # Set base_url and base_host that were computed in main instance

      # Use the shared queue and lock from the parent
      $worker_app->_internal_q($internal_q);
      $worker_app->_host_lock($host_lock);

      $worker_app->mce_user_func($mce, $internal_q);
    },
    max_retries => $max_retries,
  );

  $mce->run;
}

sub _done ($self) {

  return $self->{_internal_q}->pending == 0
    && $self->{_external_q}->pending == 0;
}

1;
__END__
