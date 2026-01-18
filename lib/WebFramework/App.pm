use v5.42.0;

package WebFramework::App;
use utf8::all;
use Mooish::Base -standard;
with 'WebFramework::Role::Logger';
extends 'Thunderhorse::App';

#use Encode              qw(encode decode FB_DEFAULT FB_CROAK);
require Data::Printer;
require PAGI::Server;
require Path::Tiny;
require Thunderhorse::Module::Template;
require Thunderhorse::Module::Logger;
require YAML::PP;
use File::HomeDir::Tiny ();
use FindBin;
use Future::AsyncAwait;
use IO::Async::Loop;

use Carp;

our $VERSION = '0.01';

has 'server' => (
  is   => 'rw',
  lazy => 1,
);

has local_conf_dir => (
  default => sub {
    my $self = shift;
    return $self->local_conf_dir(
      Path::Tiny::path($FindBin::Bin)->parent->child('share/conf'));
  },
  is   => 'rw',
  lazy => 1,
);

has env => (is => 'ro');

has initial_config => (
  is      => 'ro',
  lazy    => 1,
  default => sub {
    my $self   = shift;
    my $config = $self->getConfig($self->env);
    return $config;
  },
);

sub build ($self) {

  $self->SUPER::build();
  $self->load_module(
    'Logger' => {
      outputs => [
        file => {
          'utf-8'  => true,
          filename => Path::Tiny::path(File::HomeDir::Tiny::home)
            ->child(sprintf('/var/log/Perl/dist/%s/syslog',
            $self->app->config->{config}->{log_base}))
            ->absolute->stringify,
        }
      ]
    }
  );

  $self->logger->debug('WebFramework::App->build starting');
  my $router = $self->router;

  $router->add(
    '/health',
    {
      to     => 'health',
      action => 'http.get',
    }
  );

  $router->add(
    '/sitemap.xml',
    {
      to     => 'sitemap',
      action => 'http.get',
    }
  );
}

sub getConfig ($self, $env, $dirstring = undef) {
  if ($dirstring && length($dirstring)) {
    $self->local_conf_dir(Path::Tiny::path($dirstring));
  }

  unless ($self->local_conf_dir->is_dir) {
    croak(sprintf('config directory "%s" must exist.', $self->local_conf_dir));
  }

  my $file   = $self->local_conf_dir->child(sprintf('%s.yml', $env));
  my $data   = $file->slurp_utf8;
  my $config = YAML::PP->new(
    schema       => [qw/ + Perl /],
    yaml_version => ['1.2', '1.1'],
  )->load_string($data);
  return $config;
}

sub run {
  my $self = shift;

  my $pagi_stub = $self->SUPER::run();

  my $loop = IO::Async::Loop->new;

  my $conflogmsg = sprintf('WebFramework::App run sees config %s',
    Data::Printer::np($self->config));
  $self->logger->debug($conflogmsg);
  warn $conflogmsg;

  my $host    = $self->config->{config}->{server}->{host};
  my $port    = $self->config->{config}->{server}->{port};
  my $workers = $self->config->{config}->{server}->{worker_threads} // 2;

  my $msg = sprintf('Starting server on host "%s:%s"', $host, $port);
  warn $msg;
  $self->logger->info($msg);

  $self->server(PAGI::Server->new(
    app        => $pagi_stub,
    workers    => $workers,
    host       => $host,
    port       => $port,
    access_log => $self->accessLog,
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

  my $module_dump = Data::Printer::np(
    $self->modules,
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

  return $self->template(
    'health.tt',
    {
      env             => $env,
      connections     => $connections,
      max_connections => $maxconn,
      config_dump     => $config_dump,
      module_dump     => $module_dump,
    }
  );
}

sub sitemap ($self, $ctx) {
  my $base_url = $self->config->{site_url} // '';
  my $xml = $self->generate_sitemap($base_url);

  $ctx->res->header('Content-Type', 'application/xml; charset=UTF-8');

  return $xml;
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
