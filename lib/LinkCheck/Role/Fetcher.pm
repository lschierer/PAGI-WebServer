package LinkCheck::Role::Fetcher;
use v5.42;
use utf8::all;

use Mooish::Base -role;
with 'LinkCheck::Role::Logger';
require LinkCheck::Worker;

use IO::Async::Loop;
use Net::Async::HTTP;
use Scalar::Util qw(blessed);
use URI;


sub _loop  {
  state $loop;
  $loop //= IO::Async::Loop->new;
  return $loop
}

sub _ua ($self) {
    state $ua;
    return $ua if $ua;

    $ua = Net::Async::HTTP->new(
      user_agent =>
        'Mozilla/5.0 (compatible; LinkChecker/1.0; +https://github.com)',
      timeout                  => 60,    # start smaller while debugging
      max_redirects            => 5,
      max_connections_per_host => 1,
      pipeline                 => 0,
      stall_timeout            => 30,
      close_after_request      => 0,     # better for stability
    );

    $self->_loop->add($ua);
    return $ua;
  }

sub fetch_task ($mce, $chunk_ref, $chunk_id) {

  state $worker_obj = LinkCheck::Worker->new();

  my @futures;
  for my $url (@$chunk_ref) {
    push @futures, $worker_obj->fetch_one($url);
  }

  my @results;
  while (@futures) {
    $worker_obj->_loop->loop_once(0.01);

    my @ready = grep { $_->is_ready } @futures;
    @futures = grep { !$_->is_ready } @futures;

    push @results, map { $_->get } @ready;
  }

  MCE->gather(\@results);
}

sub fetch_one ($self, $url) {
  my $u = blessed($url) && $url->isa('URI') ? $url : URI->new($url);
  $self->logger->debug(sprintf('fetch_one called for "%s", a %s', $u, blessed($u)));
  my $res = {
    url          => $u->as_string,
    ok           => 0,
    http_status  => 0,
    error        => undef,
    content_type => undef,
    body => undef,    # you can omit body if you only need headers in wave 1
  };

  return $self->_ua->GET($u)->then(sub ($response) {
    $res->{http_status}  = $response->code // 0;
    $res->{content_type} = $response->header('Content-Type');

    if ($res->{http_status} >= 200 && $res->{http_status} < 400) {
      $res->{ok}   = 1;
      $res->{body} = $response->decoded_content;    # optional
    }
    else {
      $res->{error} = "HTTP $res->{http_status}";
    }

    return $res;
  })->catch(sub ($err) {
    $res->{error} = "$err";
    return $res;
  }); ###<-- line 90
}

1;
__END__
