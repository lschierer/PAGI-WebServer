use v5.42.0;
package WebFramework::Role::Logger;
use utf8::all;
use Mooish::Base -role;
require Path::Tiny;
use File::HomeDir::Tiny ();
use Log::Handler;
use Carp;

has 'accessLog' => (
  is    => 'rw',
  lazy  => 1,
);

has 'accessLogFH' => (
  is    => 'rw',
  lazy  => 1,
);

has logger => (
  is      => 'ro',
  default => sub {
    my $l = Log::Handler->new();
    $l->add(
      screen  => {
        log_to   => "STDERR",
        maxlevel => "warning",
        minlevel => "emergency",
        utf8     => 1,
      }
    );
    return $l;
  },
);

# Thunderhorse's Logger module only adds a logger to Controllers.
# Provide a logger to this package as well.
sub logSetup ($self, $base) {
  my $home = Path::Tiny::path(File::HomeDir::Tiny::home);
  my @parts = split '::', $base;
  my $logdir = $home->child(sprintf('var/log/Perl/dist/%s/', join('-', @parts[0 .. $#parts -1 ])));
  say "logdir is $logdir";

  unless(-d $logdir){
    $logdir->mkdir({mode => 0750});
  }

  $self->accessLog($logdir->child('access.log'));
  $self->accessLog->touch;

  # Open the access log filehandle
  open(my $access_fh, '>>:utf8', $self->accessLog->stringify)
    or die "Cannot open access log: $!";
  $access_fh->autoflush(1);  # Ensure immediate writes
  $self->accessLogFH($access_fh);

  my $systemLog = $logdir->child('system.log');
  my $maxlevel = 'warning';
  if($self->env eq 'development'){
    $maxlevel = 'debug';
  }elsif($self->env eq 'staging'){
    $maxlevel = 'info';
  }

  # for future use
  my $logExceptions = '';
  my $outputs = {
    file => {
      filename      => $systemLog->stringify,
      maxlevel      => $maxlevel,
      minlevel      => 'emergency',
      utf8          => 1,
    },
  };

  foreach my $output (keys $outputs->%*){
    $self->logger->add($output => $outputs->{$output});
  }
}


1;
__END__
