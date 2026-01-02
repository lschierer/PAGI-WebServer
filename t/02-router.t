use Test2::V0;

use_ok 'PAGI::WebServer::Router';

my $router = PAGI::WebServer::Router->new;
isa_ok $router, 'PAGI::WebServer::Router';

# Test adding routes
$router->get('/test' => sub {'test handler'});
$router->post('/api' => sub {'api handler'});

is ref($router->routes->{GET}{'/test'}), 'CODE', 'GET route added';
is ref($router->routes->{POST}{'/api'}), 'CODE', 'POST route added';

# Test to_app returns coderef
my $app = $router->to_app;
is ref($app), 'CODE', 'to_app returns coderef';

done_testing;
