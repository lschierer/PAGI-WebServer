#!/usr/bin/env perl
use v5.42.0;
use utf8::all;
use lib 'lib';
require WebFramework::App;
require PAGI::Server;
use Future::AsyncAwait;
use IO::Async::Loop;
use Getopt::Long;
use Carp;

my $config_file = 'config.yml';
my $mode        = 'development';

GetOptions(
  'config=s' => \$config_file,
  'mode=s'   => \$mode,
) or die "Error in command line arguments\n";

unless($mode =~ /(development|staging|production)/ ){
  croak("mode must be one of development|staging|production, not '$mode'.");
}

my $config_dir = 'share/conf';
my $local_config = WebFramework::App->getConfig($mode, $config_dir);

WebFramework::App->new(
  initial_config  => $local_config,
  env             => $mode,
)->run;
