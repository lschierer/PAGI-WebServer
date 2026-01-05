package PAGI::WebServer::Router;
use v5.42.0;
use utf8::all;
use Moo;
use Future::AsyncAwait;

has routes => (
  is      => 'ro',
  default => sub { {} }
);

sub get {
  my ($self, $path, $handler) = @_;
  $self->routes->{GET}{$path} = $handler;
}

sub post {
  my ($self, $path, $handler) = @_;
  $self->routes->{POST}{$path} = $handler;
}

sub to_app {
  my ($self) = @_;

  return async sub {
    my ($scope, $receive, $send) = @_;

    if ($scope->{type} eq 'http') {
      my $method = $scope->{method} // 'GET';
      my $path   = $scope->{path}   // '/';

      # Redirect paths with trailing slashes (except root '/') to non-trailing version
      if ($path ne '/' && $path =~ m{/$}) {
        my $redirect_path = $path;
        $redirect_path =~ s{/$}{};

        # Preserve query string if present
        my $query_string = $scope->{query_string} // '';
        my $location = $query_string ? "$redirect_path?$query_string" : $redirect_path;

        await $send->({
          type    => 'http.response.start',
          status  => 301,
          headers => [
            ['location', $location],
            ['content-type', 'text/plain'],
          ],
        });
        await $send->({
          type => 'http.response.body',
          body => 'Moved Permanently',
          more => 0,
        });
        return;
      }

      # Treat HEAD requests as GET for routing purposes
      my $route_method = $method eq 'HEAD' ? 'GET' : $method;

      my $handler = $self->routes->{$route_method}{$path};

      # If exact match found, use it
      if ($handler) {
        await $handler->($scope, $receive, $send);
        return;
      }

      # Try pattern matches (sort by specificity - longer prefixes first)
      my @patterns = sort { length($b) <=> length($a) }
        keys %{ $self->routes->{$route_method} };
      for my $pattern (@patterns) {
        if ($pattern =~ /\*$/) {
          my $prefix = $pattern;
          $prefix =~ s/\*$//;
          if ($path =~ /^\Q$prefix\E/) {
            $handler = $self->routes->{$route_method}{$pattern};
            await $handler->($scope, $receive, $send);
            return;
          }
        }
      }

      # Try wildcard handler
      $handler = $self->routes->{$route_method}{'*'};
      if ($handler) {
        await $handler->($scope, $receive, $send);
        return;
      }

      # No handler found
      await $send->({
        type    => 'http.response.start',
        status  => 404,
        headers => [['content-type', 'text/plain']],
      });
      await $send->({
        type => 'http.response.body',
        body => 'Not Found',
        more => 0,
      });
    }
  };
}

1;
