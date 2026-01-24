package LinkCheck::Role::Logger;
use v5.42;
use utf8::all;

use Mooish::Base -role;

require Path::Tiny;

use File::HomeDir::Tiny ();
use Log::Handler;
use Scalar::Util qw(blessed);

has field _logfile => (
  is      => 'ro',
  default => sub {
    my $self     = shift;
    my $home     = Path::Tiny::path(File::HomeDir::Tiny::home);
    my @parts    = split '::', blessed($self);
    my $log_base = $parts[0];
    my $lf =
      $home->child(sprintf('var/log/Perl/dist/%s/system.log', $log_base));

    unless (-d $lf->parent) {
      $lf->parent->mkdir({ mode => 0750 });
    }
    return $lf;
  },
);

has logger => (
  is      => 'ro',
  default => sub {
    my $self = shift;
    my $log  = Log::Handler->new();
    $log->add(
      file => {
        filename    => $self->_logfile,
        maxlevel    => "debug",
        minlevel    => "emergency",
        autoflush   => 1,
        utf8        => 1,
        debug_trace => 1,
      }
    );
    return $log;
  }
);

1;
__END__
