package LinkCheck::Role::Fetcher;
use v5.42;
use utf8::all;

use Mooish::Base -role;
require Future::HTTP;
require Data::Printer;
use Future;

use IO::Async::Loop;
use Net::Async::HTTP;
use Time::HiRes    qw(time);
use Scalar::Util   qw(blessed);
use List::AllUtils qw(min);
use Carp;

has field _ua => (
  is      => 'ro',
  default => sub ($self) {
    state $ua;

    unless ($ua) {
      # Initialize the specific Net::Async::HTTP client
      $ua = Net::Async::HTTP->new(
        user_agent =>
          'Mozilla/5.0 (compatible; LinkChecker/1.0; +https://github.com)',
        timeout                   => 300,
        max_redirects             => 5,
        max_connections_per_host  => 1,     # Reduced to avoid timeouts
        pipeline                  => 0,    # Disable pipelining to avoid spurious reads
        stall_timeout             => 60,
        close_after_request       => 1,
      );

      # Add it to your IO::Async::Loop
      $self->_loop->add($ua);
    }

    return $ua;
  }
);

sub pick_next_internal ($self) {


}

1;
__END__
