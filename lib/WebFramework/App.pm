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
#use Encode              qw(encode decode FB_DEFAULT FB_CROAK);
use File::HomeDir::Tiny ();
use Carp;
use IO::Async::Loop;

our $VERSION = '0.01';


sub build ($self) {
  $self->logger->debug('WebFramework::App->build starting');
  $self->SUPER::build();

  $self->logSetup(__PACKAGE__);

  $self->load_module('^WebFramework::Module::MarkdownTemplate');
  $self->load_module('^WebFramework::Module::AutoIndex');

  my $router = $self->router;

  $router->add(
    '/',
    {
      to     => sub ($self, $ctx) {
                                      return 'Hello?';
                              },
      action => 'http.get',
    }
  );

  $router->add(
    '/health',
    {
      to     => 'health',
      action => 'http.get',
    }
  );
}



sub run {
  my $self = shift;
  $self->logger->debug('WebFramework::App run start');
  say sprintf('WebFramework::App->env is "%s"', $self->env);
  my $pagi = $self->SUPER::run();
  my $loop = IO::Async::Loop->new;
  my $server = PAGI::Server->new(
      app  => $pagi,
      host => '127.0.0.1',
      port => 3000,
      access_log => $self->accessLogFH,
      log_level  => $self->env eq 'development' ? 'info' : 'warn',
  );
  $loop->add($server);
  $server->listen->get;  # Start accepting connections
  $loop->run;
}

async sub on_startup ($self, $state)
{
        # Called once when worker starts
        # Initialize resources, connect to databases, etc.
        $self->logger->debug("Application thread starting up");
}


sub health ($self, $ctx) {
  return 'health Hello?';
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
