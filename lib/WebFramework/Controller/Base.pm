package WebFramework::Controller::Base;

use v5.42.0;
use utf8::all;
use Mooish::Base -standard;
extends 'Thunderhorse::Controller';
with 'WebFramework::Role::Markdown';
with 'WebFramework::Role::LogConfig';

use Future::AsyncAwait;
use Path::Tiny;
use Encode      qw(encode_utf8);
use URI::Escape qw(uri_escape_utf8);

has app_config => (
  is      => 'ro',
  default => sub {
    my $self = shift;
    return $self->app->config;
  },
);

sub build ($self) {
  $self->SUPER::build();

}
