#!/usr/bin/env perl

use strict;
use warnings;
use lib 'lib';
use PAGI::WebServer;
use PAGI::WebServer::Router;
use PAGI::Server;
use Future::AsyncAwait;
use Getopt::Long;

my $config_file = 'config.yml';
my $mode = 'development';

GetOptions(
    'config=s' => \$config_file,
    'mode=s'   => \$mode,
) or die "Error in command line arguments\n";

my $framework = PAGI::WebServer->new(
    config_file => $config_file
);

$framework->setup_logging;

# Create router and add routes
my $router = PAGI::WebServer::Router->new;

$router->get('/' => async sub {
    my ($scope, $receive, $send) = @_;
    
    await $send->({
        type => 'http.response.start',
        status => 200,
        headers => [['content-type', 'text/plain']],
    });
    await $send->({
        type => 'http.response.body',
        body => 'PAGI WebServer Framework',
        more => 0,
    });
});

$router->get('/health' => async sub {
    my ($scope, $receive, $send) = @_;
    
    my $json = '{"status":"ok","timestamp":' . time . '}';
    await $send->({
        type => 'http.response.start',
        status => 200,
        headers => [['content-type', 'application/json']],
    });
    await $send->({
        type => 'http.response.body',
        body => $json,
        more => 0,
    });
});

# Create and run server
my $server = PAGI::Server->new(
    app => $router->to_app,
    port => 3000,
);

$server->run;
