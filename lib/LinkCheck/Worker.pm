package LinkCheck::Worker;
# cspell: disable
use v5.42;
use utf8::all;

use Mooish::Base -standard;
with 'LinkCheck::Role::Logger';
with 'LinkCheck::Role::Fetcher';
with 'LinkCheck::Role::Parser';
with 'LinkCheck::Role::Validator';

#this is a skeleton to call the roles it composes from.

1;
__END__
