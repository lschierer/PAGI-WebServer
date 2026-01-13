use v5.42.0;

package WebFramework::Role::Logger;
use utf8::all;
use Mooish::Base -role;
require Path::Tiny;
require Data::Printer;
use File::HomeDir::Tiny ();
use Log::Handler;
use Carp;

has 'accessLog' => (
  is   => 'rw',
  lazy => 1,
);

has 'accessLogFH' => (
  is   => 'rw',
  lazy => 1,
);

sub logger {
  state $l;
  unless ($l) {
    $l = Log::Handler->new();
    $l->add(
      screen => {
        log_to   => "STDERR",
        maxlevel => "warning",
        minlevel => "emergency",
        utf8     => 1,
      }
    );
  }
  return $l;
}

has debugLogging => (
  is => 'ro',
  default => 0,
);

# Thunderhorse's Logger module only adds a logger to Controllers.
# Provide a logger to this package as well.
sub logSetup ($self, $base) {
  my $home   = Path::Tiny::path(File::HomeDir::Tiny::home);
  my $key = $self->get_key_from_base($base);
  my $logdir = $home->child(
    sprintf('var/log/Perl/dist/%s/', $key));

  say "logdir is $logdir" if $self->debugLogging;

  unless (-d $logdir) {
    $logdir->mkdir({ mode => 0750 });
  }

  $self->accessLog($logdir->child('access.log'));
  $self->accessLog->touch;

  # Open the access log filehandle
  open(my $access_fh, '>>:utf8', $self->accessLog->stringify)
    or die "Cannot open access log: $!";
  $access_fh->autoflush(1);    # Ensure immediate writes
  $self->accessLogFH($access_fh);

  my $systemLog = $logdir->child('system.log');
  my $maxlevel  = 'warning';
  if ($self->env eq 'development') {
    $maxlevel = 'debug';
  }
  elsif ($self->env eq 'staging') {
    $maxlevel = 'info';
  }

  say "maxlevel is $maxlevel" if $self->debugLogging;

  # for future use
  my $logExceptions = '';
  my $outputs       = {
    file => {
      filename => $systemLog->stringify,
      maxlevel => $maxlevel,
      minlevel => 'emergency',
      utf8     => 1,
    },
  };

  foreach my $output (keys $outputs->%*) {
    say sprintf('adding output %s', Data::Printer::np($outputs->{$output})) if $self->debugLogging;
    $self->logger->add($output => $outputs->{$output});
  }
}

sub get_key_from_base($self, $base){
  my @parts  = split '::', $base;
  return join('-', @parts[0 .. $#parts - 1]);
}

sub ensure_logging ($self, $base = __PACKAGE__) {
  state %done;                 # per-process hash
  my $key = $self->get_key_from_base($base);             # or "$base|".$self->env if you want
  return if $done{$key}++;

  $self->logSetup($base);
  return;
}

1;
__END__
