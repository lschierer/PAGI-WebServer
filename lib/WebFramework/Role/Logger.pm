package WebFramework::Role::Logger;
use v5.42.0;
use utf8::all;
use Mooish::Base -role;
with 'WebFramework::Role::LogConfig';
use Log::Handler;
use Carp;

sub logger {
  my $self = shift;
  state $l;
  unless ($l) {
    $l = Log::Handler->new();
    $self->add_outputs();
  }

  return $l;
}

1;
__END__
