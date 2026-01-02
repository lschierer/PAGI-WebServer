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
