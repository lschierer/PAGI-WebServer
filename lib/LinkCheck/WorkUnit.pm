package LinkCheck::WorkUnit;
use v5.42;
use Mooish::Base -standard;
with 'LinkCheck::Role::State';

use Scalar::Util qw(blessed);
use Carp;

has param url => (
  required => 1,
  is       => 'ro',
  coerce   => sub {
    my $val = shift;
    return ref($val) eq 'URI' ? $val : URI->new($val);
  },
);

has field entry => (
  is      => 'lazy',
  writer  => -hidden,
  reader  => -public,
  default => sub ($self) {
    return $self->_queue_item;
  }
);

sub force_to_state ($self, $new) {
  my %valid = map { $_ => 1 } $LinkCheck::Role::State::STATES->@*;
  croak "Invalid state $new" unless $valid{$new};

  my $old = $self->entry->{state} // 'unchecked';
  return if $old eq $new;

  $self->entry->{state} = $new;

  $self->_stateCounts->decr($old);
  $self->_stateCounts->incr($new);

  return 1;
}

sub promote ($self) {
  my %idx;
  @idx{ $LinkCheck::Role::State::STATES->@* } =
    (0 .. $LinkCheck::Role::State::STATES->$#*);
  my $cur  = $self->entry->{state};
  my $i    = $idx{$cur} // croak "Unknown current state $cur";
  my $next = $LinkCheck::Role::State::STATES->[$i + 1] // return 0;
  return $self->force_to_state($next);
}

1;
__END__
