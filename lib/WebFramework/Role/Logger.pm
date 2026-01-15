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
    my $base = $self->log_base;
    $l = Log::Handler->get_logger($base);
    $self->add_outputs();
  }

  return $l;
}

1;
__END__
