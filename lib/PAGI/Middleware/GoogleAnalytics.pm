use v5.42.0;
use utf8::all;
# cspell: disable

package PAGI::Middleware::GoogleAnalytics;
use Mooish::Base -standard;
extends 'PAGI::Middleware';
use Future::AsyncAwait;

has ga_id => (is => 'ro', required => 1);

sub wrap ($self, $app) {
  return async sub ($scope, $receive, $send) {
    return await $app->($scope, $receive, $send) if $scope->{type} ne 'http';
    
    my $is_production = ($scope->{thunderhorse}->app->env // '') eq 'production';
    return await $app->($scope, $receive, $send) unless $is_production;
    
    my @body_parts;
    my $is_html = 0;
    my $original_headers;
    
    my $wrapped_send = async sub ($event) {
      if ($event->{type} eq 'http.response.start') {
        $original_headers = $event->{headers};
        $is_html = grep { lc($_->[0]) eq 'content-type' && $_->[1] =~ m{text/html} } @{$event->{headers} // []};
      }
      elsif ($event->{type} eq 'http.response.body') {
        push @body_parts, $event->{body} // '';
      }
    };
    
    await $app->($scope, $receive, $wrapped_send);
    
    my $body = join('', @body_parts);
    
    if ($is_html && $body =~ m{</head>}) {
      my $script = sprintf(
        q{<script async src="https://www.googletagmanager.com/gtag/js?id=%s"></script><script>window.dataLayer=window.dataLayer||[];function gtag(){dataLayer.push(arguments);}gtag('js',new Date());gtag('config','%s');</script>},
        $self->ga_id, $self->ga_id
      );
      $body =~ s{</head>}{$script</head>};
    }
    
    await $send->({type => 'http.response.start', status => 200, headers => $original_headers});
    await $send->({type => 'http.response.body', body => $body, more => 0});
  };
}

1;
