package LinkCheck::Role::State;
use v5.42;
use Mooish::Base -role;
use Type::Utils     qw(declare);
use Types::Standard qw(Enum);

use LinkCheck::Util qw(canon_uri);

our $STATES = [qw(
  unchecked fetching  pending-parse
  parsing   parsed    validating
  completed
)];

declare 'LinkCheckState', as Enum [$STATES->@*];

# Do not access directly, access via
# $self->_new_item;
has field _item => (
  is      => 'ro',
  default => sub {
    return {
      discovered_internal_links => [],
      discovered_external_links => [],
      discovered_anchor_refs    => [],
      possible_anchors          => [],
      state                     => 'unchecked',
    };
  },

);

sub _new_item ($self, $provided) {
  $self->_stateCounts->incr('unchecked');
  $u = $self->canon_uri($provided->{url});
  return { $self->_queue_item->%*, $provided->%*, base_url => $u, };
}

has field _stateCounts => (
  is      => 'rw',
  default => sub ($self) {
    my $sc = MCE::Shared->hash();
    foreach my $state ($STATES->@*) {
      $sc->set($state, 0);
    }
    return $sc;
  }
);

1;
__END__
