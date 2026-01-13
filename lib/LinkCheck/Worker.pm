package LinkCheck::Worker;
use v5.42;
use utf8::all;

use Mooish::Base -standard;
with 'WebFramework::Role::Logger';

use Future;
use IO::Async::Loop;
use Net::Async::HTTP;
use Scalar::Util qw(blessed);
use Mojo::DOM;
use Time::HiRes qw(time sleep);
use URI;

has verbose => (
  default   => 1,
  is        => 'ro',
);

# for use by logging
has env => (
  lazy      => 1,
  default   => sub {
    my $self = shift;
    my $e = $self->verbose ? 'development' : 'production';
    say "env is $e";
    return $e;
  },
  is        => 'ro',
);


sub run_job ($self, $job) {
  my $url  = $job->{url};
  my $mode = $job->{mode}; # internal|external
  my $base = $job->{base_host};

  my $loop = IO::Async::Loop->new;

  my $http = Net::Async::HTTP->new(
    user_agent => "perl-link-checker/0.1",
    timeout    => $job->{request_timeout},
    max_connections_per_host => 4,
  );
  $loop->add($http);

  _throttle_external_host($job, $url);
  my ($html, $page_status, $page_error, $retry_after);

  eval {
    $self->logger->info(sprintf('FETCH start mode "%s" for url "%s" on PID %s; ',
    $job->{mode}, $url, $$,  ));
    ($html, $page_status, $page_error, $retry_after) =
      _fetch_with_retries($loop, $http, $url, $job);
    $self->logger->debug(sprintf(
    'FETCH complete for "%s" with status %s', $url, $page_status));
    1;
  } or do {
    $page_error  = $@ || "fetch died on PID $$";
    $page_status = 0;
  };

  _release_external_host_slot($job, $url);

  if (($job->{mode} // '') eq 'external' && defined $retry_after) {
    my $u    = URI->new($url);
    my $host = lc($u->host // '');
    if ($host && $job->{host_lock} && $job->{host_next_time}) {
      $job->{host_lock}->lock;
      my $now = time;
      my $cur = $job->{host_next_time}->{$host} // 0;
      my $new = $now + $retry_after;
      $job->{host_next_time}->{$host} = $new if $new > $cur;
      $job->{host_lock}->unlock;
    }
  }

  my @found_internal;
  my @found_external;
  my %broken;

  # Page itself broken?
  if (!defined $html) {
    $broken{$url} = {
      status      => $page_status // 0,
      error       => $page_error  // "fetch failed",
      occurrences => 1,
    };

    return {
      mode          => $mode,
      page_url      => $url,
      found_internal => [],
      found_external => [],
      broken        => \%broken,
    };
  }

  my %anchors;
  my %anchor_refs; # base -> frag -> count

  if ($job->{mode} eq 'internal' && length $html) {
    my $page_uri = URI->new($url);
    my $dom = Mojo::DOM->new($html);
    $self->logger->info(sprintf('parsing page "%s" for more to check', $url));

    my $anchors = extract_anchors($dom);
    %anchors = %$anchors if $anchors;

    for my $u (extract_links($dom, $page_uri)) {
      my $frag = normalize_fragment($u->fragment);
      $u->fragment(undef);

      my $base_url = _normalize_url($u->as_string) // next;

      # record anchor ref if fragment exists
      if (defined $frag) {
        $anchor_refs{$base_url}{$frag}++;
      }

      # classify for crawl / external queue
      my $host = lc($u->host // '');
      if ($host eq $base) {
        push @found_internal, $base_url if $mode eq 'internal';
      } else {
        push @found_external, $base_url;
      }
    }
  }

  # Flatten anchor_refs into an array for master (less nested structure)
  my @anchor_refs_out;
  for my $base_url (keys %anchor_refs) {
    for my $frag (keys %{ $anchor_refs{$base_url} }) {
      push @anchor_refs_out, {
        base  => $base_url,
        frag  => $frag,
        count => $anchor_refs{$base_url}{$frag},
      };
    }
  }

  # Dedupe
  my %di; @found_internal = grep { !$di{$_}++ } @found_internal;
  my %de; @found_external = grep { !$de{$_}++ } @found_external;

  return {
      mode           => $mode,
      page_url       => $url,
      found_internal => \@found_internal,
      found_external => \@found_external,
      anchors        => \%anchors,
      anchor_refs    => \@anchor_refs_out,
      broken         => \%broken,
    };
}

sub extract_links ($dom, $page_uri) {
  my @out;

  # Regular HTML-ish
  for my $e ($dom->find('a[href], area[href]')->each) {
    push @out, $e->{href} if defined $e->{href};
  }

  # SVG links (xlink + href)
  for my $e ($dom->find('svg a[href], svg a[xlink\:href]')->each) {
    push @out, $e->{href}        if defined $e->{href};
    push @out, $e->{'xlink:href'} if defined $e->{'xlink:href'};
  }

  # Optionally also consider <use> and <image> hrefs
  for my $e ($dom->find('svg use[href], svg use[xlink\:href], svg image[href], svg image[xlink\:href]')->each) {
    push @out, $e->{href}          if defined $e->{href};
    push @out, $e->{'xlink:href'}  if defined $e->{'xlink:href'};
  }

  for my $e ($dom->find('svg image[href], svg image[xlink\:href], svg script[href], svg script[xlink\:href]')->each) {
    push @out, $e->{href}         if defined $e->{href};
    push @out, $e->{'xlink:href'} if defined $e->{'xlink:href'};
  }

  # Resources
  for my $e ($dom->find('img[src], script[src], iframe[src], source[src]')->each) {
    push @out, $e->{src} if defined $e->{src};
  }

  for my $e ($dom->find('link[href]')->each) {
    push @out, $e->{href} if defined $e->{href};
  }

  for my $e ($dom->find('object[data]')->each) {
    push @out, $e->{data} if defined $e->{data};
  }

  # Resolve to absolute + split base/fragment
  my @links;
  for my $raw (@out) {
    next unless defined $raw && length $raw;
    next if $raw =~ m{^(?:mailto:|tel:|javascript:|data:)}i;

    my $abs = URI->new_abs($raw, $page_uri);
    push @links, $abs;
  }

  return @links; # list of URI objects
}

sub extract_anchors ($dom) {
  my %a;

  for my $e ($dom->find('[id]')->each) {
    my $id = $e->{id};
    $a{$id} = 1 if defined $id && length $id;
  }

  for my $e ($dom->find('a[name]')->each) {
    my $name = $e->{name};
    $a{$name} = 1 if defined $name && length $name;
  }

  return \%a;
}

sub _throttle_external_host ($job, $url) {
  return unless ($job->{mode} // '') eq 'external';

  my $u    = URI->new($url);
  my $host = lc($u->host // '');
  return unless length $host;

  my $min_interval = $job->{external_min_interval} // 1.0;
  my $jitter       = $job->{external_jitter} // 0.0;
  my $slots        = $job->{external_host_slots} // 1;

  my $lock     = $job->{host_lock}      or return;
  my $next_h   = $job->{host_next_time} or return;
  my $inflight = $job->{host_inflight}  or return;

  while (1) {
    my $wait = 0;

    $lock->lock;

    my $now   = time;
    my $next  = $next_h->{$host} // 0;
    my $in    = $inflight->{$host} // 0;

    if ($in >= $slots) {
      # too many concurrent requests to this host: wait a bit
      $wait = 0.10;
    } else {
      $wait = $next > $now ? ($next - $now) : 0;
      if ($wait <= 0) {
        # claim a slot and set next-allowed timestamp
        $inflight->{$host} = $in + 1;

        my $extra = $jitter ? rand($jitter) : 0;
        $next_h->{$host} = $now + $min_interval + $extra;

        $lock->unlock;
        return;
      }
    }

    $lock->unlock;
    sleep($wait > 0 ? $wait : 0.05);
  }
}

sub _release_external_host_slot ($job, $url) {
  return unless ($job->{mode} // '') eq 'external';

  my $u    = URI->new($url);
  my $host = lc($u->host // '');
  return unless length $host;

  my $lock     = $job->{host_lock}     or return;
  my $inflight = $job->{host_inflight} or return;

  $lock->lock;
  my $in = $inflight->{$host} // 0;
  $inflight->{$host} = $in > 0 ? ($in - 1) : 0;
  $lock->unlock;
}

sub _normalize_url ($u) {
  my $uri = URI->new($u);
  return undef unless ($uri->scheme // '') =~ /^https?$/;
  $uri->fragment(undef);
  $uri->host(lc $uri->host) if $uri->host;

  if (($uri->scheme eq 'http'  && ($uri->port // 80)  == 80) ||
      ($uri->scheme eq 'https' && ($uri->port // 443) == 443)) {
    $uri->port(undef);
  }

  return $uri->as_string;
}

sub normalize_fragment ($frag) {
  return undef unless defined $frag;
  $frag =~ s/^#//;
  return undef unless length $frag;

  # decode percent escapes (common in generated links)
  my $decoded = URI->new("http://x/#$frag")->fragment; # URI decodes
  return $decoded // $frag;
}

sub _fetch_with_retries ($loop, $http, $url, $job) {
  my $last_err;
  my $last_status;

  for (my $try = 1; $try <= $job->{max_retries}; $try++) {

    my $req_f = $http->GET(
      $url,
      headers => [
        'accept' => 'text/html,application/xhtml+xml;q=0.9,image/svg+xml;q=0.9,*/*;q=0.8',
      ],
    );

    my $deadline = time + ($job->{inactive_timeout} // 30);

    # Drive the loop until the request completes or deadline hits
    while (!$req_f->is_ready) {
      $loop->loop_once(0.05);

      if (time >= $deadline) {
        $req_f->cancel;
        last;
      }
    }

    my $resp;
    eval {
      ($resp) = $req_f->get;   # will die on cancel/fail
      1;
    } or do {
      my $err = $@ || "request failed";
      $last_err = (time >= $deadline)
        ? "inactive timeout after $job->{inactive_timeout}s"
        : $err;
      $last_status = 0;
      _backoff($loop, $try);
      next;
    };

    if ($resp && $resp->is_success) {
      my $ct = $resp->content_type // '';
      my $body = ($ct =~ m{text/html|application/xhtml\+xml|image/svg\+xml}i)
        ? $resp->decoded_content(charset => 'none')
        : '';
      return ($body, $resp->code, undef);
    }

    $last_status = $resp ? $resp->code : 0;
    $last_err    = $resp ? ("HTTP " . $resp->code) : "no response";

    if ($resp && $resp->code == 429) {
      my $ra = $resp->header('Retry-After');
      my $retry_after = ($ra && $ra =~ /^\d+$/) ? $ra : undef;

      $last_status = 429;
      $last_err    = "HTTP 429";

      return (undef, 429, $last_err, $retry_after);
    }

    my %retryable = map { $_ => 1 } qw(408 425 500 502 503 504);
    last if $resp && !$retryable{$resp->code};
    _backoff($loop, $try);
  }

  return (undef, $last_status, $last_err);
}

sub _backoff ($loop, $try) {
  my $t = 0.25 * (2 ** ($try - 1));
  $t = 4 if $t > 4;

  my $until = time + $t;
  while (time < $until) {
    $loop->loop_once(0.05);
  }
}

1;
