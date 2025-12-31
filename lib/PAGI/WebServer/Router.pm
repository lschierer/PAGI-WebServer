package PAGI::WebServer::Router;

use strict;
use warnings;
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
            
            if ($handler) {
                await $handler->($scope, $receive, $send);
            } else {
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
        }
    };
}

1;
