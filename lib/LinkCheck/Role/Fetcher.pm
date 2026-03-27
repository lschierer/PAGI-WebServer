package LinkCheck::Role::Fetcher;
# cspell: disable
use v5.42;
use utf8::all;

use Mooish::Base -role;

use IO::Async::Loop;
use Net::Async::HTTP;
use Scalar::Util qw(blessed);
use URI;

sub _loop {
  state $loop;
  $loop //= IO::Async::Loop->new;
  return $loop;
}

sub _ua ($self) {
  state $ua;
  return $ua if $ua;

  $ua = Net::Async::HTTP->new(
    user_agent =>
      'Mozilla/5.0 (compatible; LinkChecker/1.0; +https://github.com)',
    timeout                  => 120,    # increased for slow pages
    max_redirects            => 5,
    max_connections_per_host => 1,
    pipeline                 => 0,
    stall_timeout            => 60,     # increased for slow pages
    close_after_request      => 0,      # better for stability
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

sub fetch_one ($self, $url, $attempt = 0) {
  my $max_retries = 2;
  my $u = blessed($url) && $url->isa('URI') ? $url : URI->new($url);
  $self->logger->debug(
    sprintf('fetch_one called for "%s", a %s', $u, blessed($u)));
  my $res = {
    url          => $u->as_string,
    ok           => 0,
    http_status  => 0,
    error        => undef,
    content_type => undef,
    body => undef,    # you can omit body if you only need headers in wave 1
  };

  return $self->_ua->GET($u)->then(sub ($response) {
    $self->get_handler($res, $u, $response);
  })->catch(sub ($err, @) {
    if ($attempt < $max_retries) {
      $self->logger->debug("fetch_one retry ${\($attempt+1)} for $u: $err");
      return $self->_loop->delay_future(after => 0.5 * (2 ** $attempt))
        ->then(sub { $self->fetch_one($u, $attempt + 1) });
    }
    $self->logger->debug("fetch_one FAILED after ${\($attempt+1)} attempts for $u: $err");
    $self->get_err_handler($res, $u, $err);
  });
}

sub get_handler ($self, $res, $u, $response) {
  $res->{http_status}  = $response->code // 0;
  $res->{content_type} = $response->header('Content-Type');

  if ($res->{http_status} >= 200 && $res->{http_status} < 400) {
    $res->{ok} = 1;
    my $body = $response->decoded_content;
    # Ensure body is a proper UTF-8 string, not bytes
    utf8::decode($body) unless utf8::is_utf8($body);
    $res->{body} = $body;
  }
  else {
    $res->{error} = "HTTP $res->{http_status}";
    $self->logger->debug("fetch non-ok status for $u: HTTP $res->{http_status}");
  }

  # Debug logging for History page
  if ($u->as_string =~ m{/Harrypedia/History$}) {
    $self->logger->debug(
"Fetched History page: http_status=$res->{http_status}, ok=$res->{ok}, error="
        . ($res->{error} // 'none'));
  }

  return $res;
}

sub get_err_handler ($self, $res, $u, $err) {
  $res->{error} = "$err";

  # Debug logging for History page
  if ($u->as_string =~ m{/Harrypedia/History$}) {
    $self->logger->debug("Fetch failed for History page: error=$err");
  }

  return $res;
}

1;
__END__
