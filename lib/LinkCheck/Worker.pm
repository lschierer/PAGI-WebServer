package LinkCheck::Worker;
use v5.42;
use utf8::all;

use Mooish::Base -standard;
with 'WebFramework::Role::Logger';

use Future;
use IO::Async::Loop;
use Net::Async::HTTP;

use Mojo::DOM;
use URI;

sub run_job ($job) {
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

  my ($html, $page_status, $page_error) = _fetch_with_retries($loop, $http, $url, $job);

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

  if (length $html) {
    my $page_uri = URI->new($url);
    my $dom = Mojo::DOM->new($html);

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

    my $inactive_f = $loop->delay_future(after => $job->{inactive_timeout})
      ->then(sub {
        $req_f->cancel;
        Future->fail("inactive timeout after $job->{inactive_timeout}s");
      });

    my $done = Future->wait_any($req_f, $inactive_f);

    my ($winner, @vals);
    eval {
      ($winner, @vals) = $loop->await($done);
      1;
    } or do {
      $last_err = $@ || "unknown error";
      $last_status = 0;
      _backoff($loop, $try);
      next;
    };

    # If the inactivity future won, it should have failed; but handle defensively.
    if ($winner != $req_f) {
      # winner is the timeout future (or something else)
      my $err = eval { $winner->failure } || "request canceled/timeout";
      $last_err = $err;
      $last_status = 0;
      _backoff($loop, $try);
      next;
    }

    # req_f won; its first value should be an HTTP::Response
    my ($resp) = @vals;

    if ($resp && $resp->is_success) {
      my $ct = $resp->content_type // '';
      my $body = ($ct =~ m{text/html|application/xhtml\+xml|image/svg\+xml}i)
        ? $resp->decoded_content(charset => 'none')
        : '';
      return ($body, $resp->code, undef);
    }

    $last_status = $resp ? $resp->code : 0;
    $last_err    = $resp ? ("HTTP " . $resp->code) : "no response";

    my %retryable = map { $_ => 1 } qw(408 425 429 500 502 503 504);
    last if $resp && !$retryable{$resp->code};

    _backoff($loop, $try);
  }

  return (undef, $last_status, $last_err);
}

sub _backoff ($loop, $try) {
  my $t = 0.25 * (2 ** ($try - 1));
  $t = 4 if $t > 4;
  $loop->await($loop->delay_future(after => $t));
}

1;
