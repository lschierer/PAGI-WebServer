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
    my $is_html = 0;
    my $body = '';
    
    my $wrapped_send = $self->intercept_send($send, async sub ($event, $orig_send) {
      if ($event->{type} eq 'http.response.start') {
        $is_html = grep { $_->[0] eq 'content-type' && $_->[1] =~ m{text/html} } @{$event->{headers}};
      }
      elsif ($event->{type} eq 'http.response.body' && $is_html && $scope->{thunderhorse}->app->env eq 'production') {
        $body .= $event->{body} // '';
        return if !$event->{more_body};
        
        my $script = sprintf(
          q{<script async src="https://www.googletagmanager.com/gtag/js?id=%s"></script><script>window.dataLayer=window.dataLayer||[];function gtag(){dataLayer.push(arguments);}gtag('js',new Date());gtag('config','%s');</script>},
          $self->ga_id, $self->ga_id
        );
        $body =~ s{</head>}{$script</head>};
        $event = {%$event, body => $body};
      }
      await $orig_send->($event);
    });
    
    await $app->($scope, $receive, $wrapped_send);
  };
}

1;
