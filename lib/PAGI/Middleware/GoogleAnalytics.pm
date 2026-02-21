package PAGI::Middleware::GoogleAnalytics;
# cspell: disable

use strict;
use warnings;
use parent 'PAGI::Middleware';
use Future::AsyncAwait;

sub _init {
  my ($self, $config) = @_;

  $self->{ga_id} = $config->{ga_id} // die "GoogleAnalytics middleware requires 'ga_id' option";
  $self->{env}   = $config->{env}   // 'development';
}

sub wrap {
  my ($self, $app) = @_;

  return async sub {
    my ($scope, $receive, $send) = @_;

    # Only process HTTP requests in production
    if ($scope->{type} ne 'http' || $self->{env} ne 'production') {
      await $app->($scope, $receive, $send);
      return;
    }

    my @body_parts;
    my $is_html       = 0;
    my $original_start;
    my $headers_sent   = 0;

    my $wrapped_send = async sub {
      my ($event) = @_;

      if ($event->{type} eq 'http.response.start') {
        $original_start = $event;
        $is_html = grep {
          lc($_->[0]) eq 'content-type' && $_->[1] =~ m{text/html}
        } @{ $event->{headers} // [] };

        # Non-HTML: forward immediately, don't buffer
        unless ($is_html) {
          await $send->($event);
          $headers_sent = 1;
        }
      }
      elsif ($event->{type} eq 'http.response.body') {
        if ($headers_sent) {
          # Non-HTML or streaming: pass through directly
          await $send->($event);
        }
        else {
          # HTML: buffer body parts
          push @body_parts, $event->{body} // '';
        }
      }
      else {
        await $send->($event);
      }
    };

    await $app->($scope, $receive, $wrapped_send);

    # If headers already sent (non-HTML), we're done
    return if $headers_sent;

    # Combine buffered HTML body
    my $body = join('', @body_parts);

    # Inject GA script before </head>
    if ($body =~ m{</head>}) {
      my $script = sprintf(
        q{<script async src="https://www.googletagmanager.com/gtag/js?id=%s"></script><script>window.dataLayer=window.dataLayer||[];function gtag(){dataLayer.push(arguments);}gtag('js',new Date());gtag('config','%s');</script>},
        $self->{ga_id}, $self->{ga_id}
      );
      $body =~ s{</head>}{$script</head>};
    }

    # Update content-length to reflect modified body
    my @new_headers;
    for my $h (@{ $original_start->{headers} // [] }) {
      next if lc($h->[0]) eq 'content-length';
      push @new_headers, $h;
    }
    push @new_headers, ['content-length', length($body)];

    await $send->({
      type    => 'http.response.start',
      status  => $original_start->{status},
      headers => \@new_headers,
    });
    await $send->({
      type => 'http.response.body',
      body => $body,
      more => 0,
    });
  };
}

1;

__END__

=head1 NAME

PAGI::Middleware::GoogleAnalytics - Inject Google Analytics into HTML responses

=head1 SYNOPSIS

    $self->load_module(
      'Middleware' => {
        GoogleAnalytics => { ga_id => 'G-XXXXXXX', env => $self->env },
      }
    );

=head1 DESCRIPTION

Injects the Google Analytics gtag.js snippet before C<< </head> >> in HTML
responses. Only active in production; all other environments pass through
unmodified. Non-HTML responses (CSS, JS, images, etc.) are never buffered.

=cut
