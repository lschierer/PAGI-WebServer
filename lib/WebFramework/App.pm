use v5.42.0;

package WebFramework::App;
use utf8::all;
use Mooish::Base -standard;
with 'WebFramework::Role::Logger';
extends 'Thunderhorse::App';

use Future::AsyncAwait;
require PAGI::Server;
require Path::Tiny;
require Thunderhorse::Module::Logger;
require Thunderhorse::Module::Template;
require Data::Printer;
require YAML::PP;
#use Encode              qw(encode decode FB_DEFAULT FB_CROAK);
use File::HomeDir::Tiny ();
use Carp;
use IO::Async::Loop;

our $VERSION = '0.01';

has 'server' => (
  is   => 'rw',
  lazy => 1,
);

sub build ($self) {
  $self->logger->debug('WebFramework::App->build starting');
  $self->SUPER::build();

  $self->logSetup(__PACKAGE__);

  $self->load_module('^WebFramework::Module::SiteLogo');
  $self->load_module('^WebFramework::Module::Navigation');

  $self->load_module('^WebFramework::Module::AutoIndex');

  my $router = $self->router;

  $router->add(
    '/health',
    {
      to     => 'health',
      action => 'http.get',
    }
  );
}

sub getConfig ($class, $env, $dirstring) {
  use FindBin;
  my $configdir = Path::Tiny::path($FindBin::Bin)->parent->child($dirstring);
  unless ($configdir->is_dir) {
    croak("config directory '$configdir' must exist.");
  }
  my $file   = $configdir->child(sprintf('%s.yml', $env));
  my $data   = $file->slurp_utf8;
  my $config = YAML::PP->new(
    schema       => [qw/ + Perl /],
    yaml_version => ['1.2', '1.1'],
  )->load_string($data);
  return $config;
}

sub run {
  my $self = shift;
  $self->logger->debug('WebFramework::App run start');
  $self->logger->debug(sprintf('WebFramework::App->env is "%s"', $self->env));

  my $pagi_stub = $self->SUPER::run();
  my $loop      = IO::Async::Loop->new;

  my $conflogmsg = sprintf('WebFramework::App run sees config %s',
    Data::Printer::np($self->config));
  $self->logger->debug($conflogmsg);
  warn $conflogmsg;

  my $host    = $self->config->{config}->{server}->{host};
  my $port    = $self->config->{config}->{server}->{port};
  my $workers = $self->config->{config}->{server}->{worker_threads} // 2;
  my $msg     = sprintf('Starting server on host "%s:%s"', $host, $port);
  warn $msg;
  $self->logger->info($msg);

  $self->server(PAGI::Server->new(
    app        => $pagi_stub,
    workers    => $workers,
    host       => $host,
    port       => $port,
    access_log => $self->accessLogFH,
    log_level  => $self->env eq 'development' ? 'info' : 'warn',
  ));

  $loop->add($self->server);
  $self->server->listen->get;    # Start accepting connections
  $loop->run;
}

async sub on_startup ($self, $state) {
  # Called once when worker starts
  # Initialize resources, connect to databases, etc.
  $self->logger->debug("Application thread starting up");
}

sub health ($self, $ctx) {
  my $env         = $self->env;
  my $connections = $self->server->connection_count;
  my $maxconn     = $self->server->effective_max_connections;

  # Use Data::Printer's plain text output for clean formatting
  use Data::Printer;
  my $config_dump = Data::Printer::np(
    $self->config,
    multiline => 1,
    colored   => 0,            # Disable colors to avoid ANSI codes
    theme     => 'Material',
  );

  # Debug: check template configuration
  use Cwd;
  my $cwd = getcwd();
  $self->logger->debug("Current working directory: $cwd");
  my $tc = $self->config->{template} // {};
  $self->logger->debug(
    sprintf('Template config: "%s"', Data::Printer::np($tc) // ''));

  return $self->render(
    'health.tt',
    {
      env             => $env,
      connections     => $connections,
      max_connections => $maxconn,
      config_dump     => $config_dump,
    }
  );
}

1;

__END__

=head1 NAME

PAGI::WebServer - Common web server framework for multiple projects

=head1 SYNOPSIS

    use PAGI::WebServer;

    my $server = PAGI::WebServer->new(
        config_file => 'myapp.yml'
    );

    $server->start;

=head1 DESCRIPTION

A common framework for serving Markdown content with Pandoc, handling CSS/TypeScript compilation,
and providing configurable logging across multiple related projects.

=cut
