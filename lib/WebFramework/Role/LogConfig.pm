package WebFramework::Role::LogConfig;
use v5.42.0;
use utf8::all;
use Mooish::Base -role;
require Path::Tiny;
require Data::Printer;
use File::HomeDir::Tiny ();
use Log::Handler;
use Carp;

has debugLogging => (
  is      => 'ro',
  default => 1,
);

has log_dir => (
  is      => 'ro',
  lazy    => 1,
  default => sub {
    my $self = shift;
    my $home = Path::Tiny::path(File::HomeDir::Tiny::home);
    my $ld   = $home->child(sprintf('var/log/Perl/dist/%s/', $self->log_base));

    say "self->log_dir is $ld" if $self->debugLogging;

    unless (-d $ld) {
      $ld->mkdir({ mode => 0750 });
    }
    return $ld;
  }
);

sub log_base {
  my $self = shift;
  my $log_base;

  if ($self->isa('Thunderhorse::App')) {
    say 'Called from Application class' if $self->debugLogging;
    $log_base //= $self->getConfig($self->env)->{log_base};
    say "getConfig log_base is '$log_base'" if $self->debugLogging;
  }
  elsif ($self->can('app')) {
    say 'Called from ' . blessed($self) if $self->debugLogging;
    $log_base //= $self->app->getConfig($self->app->env)->{log_base};
  }
  elsif ($self->can('config')) {
    say 'Called from ' . blessed($self) if $self->debugLogging;
    $log_base //= $self->config->{config}->{log_base};
    $log_base //= $self->config->{log_base};
  }

  if (!defined($log_base)) {
    say 'Called from ' . blessed($self) if $self->debugLogging;
    my @parts = split '::', blessed($self);
    $log_base = $parts[0];
  }

  return $log_base;
}

has 'accessLog' => (
  is   => 'rw',
  lazy => 1,
);

has 'accessLogFH' => (
  is   => 'rw',
  lazy => 1,
);

sub add_outputs ($self) {
  my $home = Path::Tiny::path(File::HomeDir::Tiny::home);

  my $systemLog = $self->log_dir->child('system.log');
  my $maxlevel  = 'warning';
  if ($self->can('app') && $self->app->env eq 'development') {
    $maxlevel = 'debug';
  }
  elsif ($self->can('app') && $self->app->env eq 'staging') {
    $maxlevel = 'info';
  }
  elsif (blessed($self) =~ /LinkCheck/) {
    $maxlevel = 'debug';
  }
  else {
    $maxlevel = 'notice';

  }
  if($self->can('app') && $self->app->can('config') && $self->app->config->get('log_config')){
    my $LogConfig =  $self->app->config->get('log_config');
    if(exists $LogConfig->{default}){
      $maxlevel = lc($LogConfig->{default});
    }
  }

  say "maxlevel is $maxlevel" if $self->debugLogging;

  # for future use
  my $logExceptions = '';
  my $destinations  = {
    file => {
      filename   => $systemLog->stringify,
      maxlevel   => $maxlevel,
      minlevel   => 'emergency',
      log_format => '[%s] [%s] %s',
      utf8       => 1,
    },
  };

  foreach my $output (keys $destinations->%*) {
    say sprintf('adding output %s', Data::Printer::np($destinations->{$output}))
      if $self->debugLogging;
    if ($self->isa('Thunderhorse::Module::Logger')) {
      push @{ $self->config->{outputs} }, $destinations->{$output};
      push @{ $self->logger->outputs },   $destinations->{$output};
    }
    else {
      delete $destinations->{$output}->{log_format};
      $self->logger->add($output => $destinations->{$output});
    }
  }
}

sub setup_access_log ($self) {
  $self->accessLog($self->log_dir->child('access.log'));
  $self->accessLog->touch;

  # Open the access log filehandle
  open(my $access_fh, '>>:utf8', $self->accessLog->stringify)
    or die "Cannot open access log: $!";
  $access_fh->autoflush(1);    # Ensure immediate writes
  $self->accessLogFH($access_fh);
}

1;
__END__
