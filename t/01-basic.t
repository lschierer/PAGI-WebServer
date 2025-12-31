use Test2::V0;

use_ok 'PAGI::WebServer';

my $server = PAGI::WebServer->new;
isa_ok $server, 'PAGI::WebServer';

is $server->stage,          'localDev',     'default stage is localDev';
is $server->css_dir,        'share/styles', 'default css_dir';
is $server->typescript_dir, 'src/ts',       'default typescript_dir';
is $server->worker_threads, '4',            'default worker_threads';

done_testing;
