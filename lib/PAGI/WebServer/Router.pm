package PAGI::WebServer::Router;
use v5.42.0;
use utf8::all;
use Moo;
use Future::AsyncAwait;

has routes => (
    is => 'ro',
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
            my $path = $scope->{path} // '/';

            my $handler = $self->routes->{$method}{$path};

            # If exact match found, use it
            if ($handler) {
                await $handler->($scope, $receive, $send);
                return;
            }

            # Try pattern matches
            for my $pattern (keys %{$self->routes->{$method}}) {
                if ($pattern =~ /\*$/) {
                    my $prefix = $pattern;
                    $prefix =~ s/\*$//;
                    if ($path =~ /^\Q$prefix\E/) {
                        $handler = $self->routes->{$method}{$pattern};
                        await $handler->($scope, $receive, $send);
                        return;
                    }
                }
            }

            # Try wildcard handler
            $handler = $self->routes->{$method}{'*'};
            if ($handler) {
                await $handler->($scope, $receive, $send);
                return;
            }

            # No handler found
            await $send->({
                type => 'http.response.start',
                status => 404,
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
