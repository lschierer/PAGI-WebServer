use v5.42.0;
use utf8::all;
# cspell: disable

package PAGI::Middleware::GoogleAnalytics;
use Mooish::Base -standard;
extends 'PAGI::Middleware';
use Future::AsyncAwait;

has ga_id => (is => 'ro', required => 1);

async sub call ($self, $ctx) {
  my $response = await $self->app->($ctx);
  
  return $response unless $self->app->env eq 'production';
  return $response unless $response->content_type =~ m{text/html};
  
  my $body = $response->body;
  my $script = sprintf(
    q{<script async src="https://www.googletagmanager.com/gtag/js?id=%s"></script>
<script>window.dataLayer=window.dataLayer||[];function gtag(){dataLayer.push(arguments);}gtag('js',new Date());gtag('config','%s');</script>},
    $self->ga_id, $self->ga_id
  );
  
  $body =~ s{</head>}{$script</head>};
  $response->body($body);
  
  return $response;
}

1;
