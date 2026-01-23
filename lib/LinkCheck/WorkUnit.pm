package LinkCheck::WorkUnit;
use v5.42;
use Mooish::Base -standard;
use Scalar::Util qw(blessed);

has param url   => ( is => 'ro' );          # canonical string key
has param queue => ( is => 'ro' );          # MCE::Shared::Hash (internal_q or external_q)
has param lock  => ( is => 'ro' );          # your _phase_lock
has param state_counts => ( is => 'ro' );   # shared hash of counts
has param states => ( is => 'ro' );         # arrayref of valid states

sub entry ($self) { $self->queue->{ $self->url } }

sub state ($self) { $self->entry->{state} // 'unchecked' }

sub force_to_state ($self, $new) {
  my %valid = map { $_ => 1 } $self->states->@*;
  die "Invalid state $new" unless $valid{$new};

  $self->lock->synchronize(sub {
    my $e = $self->entry;
    my $old = $e->{state} // 'unchecked';
    return if $old eq $new;

    $e->{state} = $new;

    $self->state_counts->decr($old);
    $self->state_counts->incr($new);
  });

  return 1;
}

sub promote ($self) {
  my %idx; @idx{ $self->states->@* } = (0 .. $self->states->$#*);
  my $cur = $self->state;
  my $i = $idx{$cur} // die "Unknown current state $cur";
  my $next = $self->states->[ $i + 1 ] // return 0;
  return $self->force_to_state($next);
}

1;
__END__
