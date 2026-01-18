
package LinkCheck::Worker;
use v5.42;
use utf8::all;

use Mooish::Base -standard;
extends 'LinkCheck::Common';
require Future::HTTP;
use Future;

use IO::Async::Loop;
use Mojo::DOM58;
use Carp;

sub mce_user_func ($self, $mce, $internal_q, $external_q) {
  my ($pid, $wid) = (MCE->pid, MCE->wid);
  $self->_internal_q($internal_q);
  $self->_external_q($external_q);

  my $max_internal = $mce->max_workers - 1;
  if ($wid != $mce->max_workers) {
    $self->main_internal_loop($mce, $pid, $wid);
    $self->_wait_all($wid, 'main_internal_loop', $max_internal);
  }
  else {
    #sleep once to let some links queue up so we don't just exit.
    select(undef, undef, undef, 2);
  }

  $self->main_external_loop($mce, $pid, $wid);
  $self->_wait_all($wid, 'main_external_loop', $mce->max_workers);
  $self->main_validation_loop($mce, $pid, $wid);
  # make sure validation is done before we return control to the master.
  $self->_wait_all($wid, 'main_validation_loop', $mce->max_workers);
}

sub _loop ($self) {
  state $loop;
  return $loop //= IO::Async::Loop->new;
}

sub _ua ($self) {
  state $ua;

  return $ua //= Future::HTTP->new(
    timeout       => $self->request_timeout // 30,
    max_redirects => 5,
    loop          => $self->_loop,
    user_agent    =>
'Mozilla/5.0 (compatible; LinkChecker/1.0; +https://github.com/lschierer/PAGI-WebServer)',

    # Only needed if you hit self-signed local https.
    # Better: gate this on host =~ /^(?:localhost|127\.0\.0\.1)$/
    # tls_options  => { SSL_verify_mode => 0 },
  );
}

sub _status_from_headers ($headers) {
  return 0 unless $headers && ref($headers) eq 'HASH';
  my $s = $headers->{Status} // $headers->{status} // $headers->{code} // 0;
  $s += 0 if defined $s;    # numeric
  return $s;
}

sub main_external_loop ($self, $mce, $pid, $wid) {
  $self->logger->notice('Start of main_external_loop');
  $self->_mark_phase($wid, 'main_external_loop', 'started');

  my $no_work_count = 0;
  my @in_progress;
  my @pending_futures;

  do {
    # Claim multiple URLs up to a batch size
    my $batch_size = $self->external_batch_size // 10;

    $self->_host_lock->lock;
    my @all_keys = $self->_external_q->keys();
    my @unchecked =
      sort grep { $self->_external_q->{$_}->{state} eq 'unchecked' } @all_keys;
    @in_progress =
      grep { $self->_external_q->{$_}->{state} eq 'in-progress' } @all_keys;

    my @claimed;
    my $now = time;

    for my $key (@unchecked) {
      last if @claimed >= $batch_size;

      my $uri  = URI->new($key);
      my $host = $uri->host;

      my $next_time = $self->_host_next_time->{$host} // 0;
      my $inflight  = $self->_host_inflight->{$host}  // 0;

      next if $now < $next_time;
      next if $inflight >= $self->external_host_slots;

      # Claim this URL
      $self->_external_q->{$key}->{state}      = 'in-progress';
      $self->_external_q->{$key}->{claimed_at} = $now;
      $self->_external_q->{$key}->{claimed_by} = "$pid/$wid";

      $self->_host_inflight->{$host} = $inflight + 1;
      my $jitter = rand($self->external_jitter);
      $self->_host_next_time->{$host} =
        $now + $self->external_min_interval + $jitter;

      push @claimed, $key;
      $self->logger->debug("pid $pid; wid $wid; claimed key $key");
    }

    $self->_host_lock->unlock;

    # Start async requests for claimed URLs
    for my $key (@claimed) {
      push @pending_futures, $self->check_external_url_async($key);
      $no_work_count = 0;
    }

    # Process event loop to make progress on pending futures
    if (@pending_futures) {
      $self->_loop->loop_once(0.01);

      # Remove completed futures
      @pending_futures = grep { !$_->is_ready } @pending_futures;
    }
    elsif (@in_progress) {
      $no_work_count = 0;
      select(undef, undef, undef, 0.1);
    }
    else {
      $no_work_count++;
      $self->logger->debug(
        "pid $pid; wid $wid; no work found (count: $no_work_count)");
      select(undef, undef, undef, 0.1) if $no_work_count < 3;
    }
  } while (@pending_futures || @in_progress || $no_work_count < 3);

  $self->_mark_phase($wid, 'main_external_loop', 'complete');
}

sub main_internal_loop ($self, $mce, $pid, $wid) {
  $self->_mark_phase($wid, 'main_internal_loop', 'started');

  my $no_work_count = 0;
  my @in_progress;
  my @pending_futures;

  do {
    my $batch_size = $self->internal_batch_size // 20;

    $self->_host_lock->lock;

    my @all_keys = $self->_internal_q->keys();
    my @unchecked =
      sort grep { $self->_internal_q->{$_}->{state} eq 'unchecked' } @all_keys;
    @in_progress =
      grep { $self->_internal_q->{$_}->{state} eq 'in-progress' } @all_keys;

    my @claimed;
    my $now = time;

    for my $key (@unchecked) {
      last if @claimed >= $batch_size;

      $self->_internal_q->{$key}->{state}      = 'in-progress';
      $self->_internal_q->{$key}->{claimed_at} = $now;
      $self->_internal_q->{$key}->{claimed_by} = "$pid/$wid";

      push @claimed, $key;
      $self->logger->debug("pid $pid; wid $wid; claimed key $key");
    }

    $self->_host_lock->unlock;

    for my $key (@claimed) {
      push @pending_futures, $self->get_internal_url_async($key);
      $no_work_count = 0;
    }

    if (@pending_futures) {
      $self->_loop->loop_once(0.01);
      @pending_futures = grep { !$_->is_ready } @pending_futures;
    }
    elsif (@in_progress) {
      $no_work_count = 0;
      select(undef, undef, undef, 0.1);
    }
    else {
      $no_work_count++;
      $self->logger->debug(
        "pid $pid; wid $wid; no work found (count: $no_work_count)");
      select(undef, undef, undef, 0.1) if $no_work_count < 3;
    }
  } while (@pending_futures || @in_progress || $no_work_count < 3);

  $self->_mark_phase($wid, 'main_internal_loop', 'complete');
  $self->logger->info("pid $pid; wid $wid; exiting - no more work");
}

sub check_external_url_async ($self, $url) {
  return unless ($url && length($url));
  $url = $self->canon_url($url);
  unless ($self->_external_q->exists($url)) {
    my $errmsg = "no external queue entry for $url";
    $self->logger->error($errmsg);
    warn($errmsg);
    return Future->done;
  }
  return Future->done if ($self->_external_q->{$url}->{state} eq 'checked');

  my $msg = "checking external url $url";
  say $msg if ($self->verbose);
  $self->logger->info($msg);

  my $uri  = URI->new($url);
  my $host = $uri->host;

  my $ua = $self->_ua;

  my $cleanup = sub {
    $self->_host_lock->lock;
    my $inflight = $self->_host_inflight->{$host} // 1;
    $self->_host_inflight->{$host} = $inflight - 1;
    $self->_host_lock->unlock;
    $self->_external_q->{$url}->{state} = 'checked';
  };

  return $ua->http_head($url)->then(sub {
    my ($body, $headers) = @_;

    my $status = _status_from_headers($headers);
    $self->_external_q->{$url}->{http_status} = $status;

    if ($status >= 200 && $status < 400) {
      $self->logger->info("External link OK: $url (status $status)");
      return Future->done;
    }
    elsif ($status == 403 || $status == 405) {
      return $ua->http_get($url)->then(sub {
        my ($body2, $headers2) = @_;
        my $status2 = $headers2->{Status} // 0;
        $self->_external_q->{$url}->{http_status} = $status2;
        if ($status2 >= 200 && $status2 < 400) {
          $self->logger->info(
            "External link OK (via GET): $url (status $status2)");
        }
        else {
          $self->logger->warn("External link failed: $url (status $status2)");
          $self->_external_q->{$url}->{error} = "HTTP $status2";
        }
      });
    }
    else {
      $self->logger->warn("External link failed: $url (status $status)");
      $self->_external_q->{$url}->{error} = "HTTP $status";
      return Future->done;
    }
  })->catch(sub {
    my ($error) = @_;
    $self->logger->error("External link error: $url - $error");
    $self->_external_q->{$url}->{error}       = "$error";
    $self->_external_q->{$url}->{http_status} = 0;
  })->then(sub {
    $cleanup->();
    return Future->done;
  });
}

sub check_external_url ($self, $url) {
  $self->check_external_url_async($url)->get();
}

sub get_internal_url_async($self, $url) {
  return unless ($url && length($url));
  $url = $self->canon_url($url);
  unless ($self->_internal_q->exists($url)) {
    my $errmsg = "no internal queue entry for $url";
    $self->logger->error($errmsg);
    warn($errmsg);
    return Future->done;
  }
  return Future->done if ($self->_internal_q->{$url}->{state} eq 'checked');
  my $msg = "getting internal url $url";
  say $msg if ($self->verbose);
  $self->logger->info($msg);
  my $ua = $self->_ua;
  return $ua->http_get($url)->then(sub {
    my ($body, $headers) = @_;

    my $status = _status_from_headers($headers);
    $self->_internal_q->{$url}->{http_status} = $status;

    if ($status >= 200 && $status < 400) {
      my $extracted = $self->process_url($url, $body, $headers);

      $self->_internal_q->{$url}->{pending_internal_links} =
        $extracted->{internal_links};
      $self->_internal_q->{$url}->{pending_external_links} =
        $extracted->{external_links};
      $self->_internal_q->{$url}->{pending_anchor_refs} =
        $extracted->{anchor_refs};
      $self->_internal_q->{$url}->{possible_anchors} = $extracted->{anchors};

      foreach my $link (@{ $extracted->{internal_links} }) {
        if ($link =~ /^\//) {
          $link = sprintf('%s%s', $self->base->{url}, $link);
        }
        my $uri  = URI->new($link);
        my $host = $uri->clone;
        $host->fragment(undef);
        $host->query(undef);

        my $base_url = $self->canon_url($host->as_string) // next;
        unless (exists $self->_internal_q->{$base_url}) {
          $self->_internal_q->{$base_url} = $self->_new_queue_item;
        }
      }

      for my $ext (@{ $extracted->{external_links} // [] }) {
        my $canon = $self->canon_url($ext) // next;

        next
          if URI->new($canon)->host
          && lc(URI->new($canon)->host) eq $self->base->{host};

        unless ($self->_external_q->exists($canon)) {
          $self->_external_q->{$canon} = $self->_new_queue_item;
        }
      }
    }
    else {
      $self->logger->warn("Internal link failed: $url (status $status)");
      $self->_internal_q->{$url}->{error} = "HTTP $status";
    }
  })->catch(sub {
    my ($error) = @_;
    $self->logger->error("Internal link error: $url - $error");
    $self->_internal_q->{$url}->{error}       = "$error";
    $self->_internal_q->{$url}->{http_status} = 0;
  })->then(sub {
    $self->_internal_q->{$url}->{state} = 'checked';
    return Future->done;
  });
}

sub get_internal_url($self, $url) {
  $self->get_internal_url_async($url)->get();
}

sub process_url ($self, $url, $body, $headers) {
  my $base_host = $self->base->{host};              # already lc()
  my $base_root = $self->base->{url}->as_string;    # e.g. https://example.com

  my (@internal, @external, @anchor_refs, @anchors);

  # --------
  # 1) DOM parse (forgiving)
  # --------
  my $dom;
  eval { $dom = Mojo::DOM58->new($body) } or do { $dom = undef };

  if ($dom) {
    # anchors on this page
    for my $e ($dom->find('[id]')->each) {
      my $id = $e->{id};
      push @anchors, $id if defined $id && length $id;
    }
    for my $e ($dom->find('a[name]')->each) {
      my $name = $e->{name};
      push @anchors, $name if defined $name && length $name;
    }

    # where to look for URLs (site structure focus)
    my @attrs = (
      ['a[href], area[href]'                             => 'href'],
      ['img[src], iframe[src], script[src], source[src]' => 'src'],
      ['link[href]'                                      => 'href'],
      ['object[data]'                                    => 'data'],
      # SVG-ish (Mojo::DOM can see attributes, even if namespaced)
      ['svg a[href], svg a[xlink\:href]'         => 'href'],
      ['svg use[href], svg use[xlink\:href]'     => 'href'],
      ['svg image[href], svg image[xlink\:href]' => 'href'],
    );

    for my $spec (@attrs) {
      my ($sel, $attr) = @$spec;
      for my $e ($dom->find($sel)->each) {
        my $raw = $e->{$attr};
        next unless defined $raw && length $raw;
        _classify_and_record($self, $url, $raw, $base_host, $base_root,
          \@internal, \@external, \@anchor_refs);
      }

      # also pick up xlink:href explicitly when selector matches it
      if ($sel =~ /xlink/) {
        for my $e ($dom->find($sel)->each) {
          my $raw = $e->{'xlink:href'};
          next unless defined $raw && length $raw;
          _classify_and_record($self, $url, $raw, $base_host, $base_root,
            \@internal, \@external, \@anchor_refs);
        }
      }
    }
  }

  # --------
  # 2) Regex fallback (catches stuff DOM missed)
  # --------
  # This is intentionally dumb-but-safe: only common attrs, no JS parsing.
  # It’s here to avoid “parser dropped half the links” surprises.
  for my $raw (_scan_html_for_urls($body)) {
    _classify_and_record($self, $url, $raw, $base_host, $base_root, \@internal,
      \@external, \@anchor_refs);
  }

  # --------
  # 3) Dedupe + canonicalize list shapes
  # --------
  my %seen_i;
  @internal = grep { defined && length && !$seen_i{$_}++ } @internal;
  my %seen_e;
  @external = grep { defined && length && !$seen_e{$_}++ } @external;

  # anchors: dedupe
  my %seen_a;
  @anchors = grep { defined && length && !$seen_a{$_}++ } @anchors;

  # anchor refs: dedupe by "url#anchor"
  my %seen_ar;
  @anchor_refs = grep {
    my $k = ($_->{url} // '') . ($_->{anchor} // '');
    $k && !$seen_ar{$k}++
  } @anchor_refs;

  return {
    internal_links => \@internal,
    external_links => \@external,
    anchor_refs    => \@anchor_refs,
    anchors        => \@anchors,
  };
}

sub _scan_html_for_urls ($html) {
  my @out;

  # capture href/src/data attributes in double/single/unquoted forms
  while (
    $html =~ m{
    \b(?:href|src|data)\s*=\s*
    (?:
      "([^"]+)" |
      '([^']+)' |
      ([^\s"'<>]+)
    )
  }igx
  ) {
    push @out, (defined $1 ? $1 : defined $2 ? $2 : $3);
  }

  return @out;
}

sub _classify_and_record ($self, $page_url, $raw, $base_host, $base_root,
  $internal_ref, $external_ref, $anchor_refs_ref) {

  # ignore schemes we never want
  return if $raw =~ m{^(?:mailto:|tel:|javascript:|data:)}i;

  # Pure same-page fragment
  if ($raw =~ /^#(.+)/) {
    push @$anchor_refs_ref, { url => $page_url, anchor => "#$1" };
    return;
  }

  my $abs;
  eval {
    $abs = URI->new_abs($raw, $page_url);
    1;
  } or return;

  # split fragment for anchor bookkeeping
  my $frag = $abs->fragment;
  $abs->fragment(undef);

# normalize base url (your canon_url does host lc, strips frag, strips query, trims trailing slash)
  my $base = $self->canon_url($abs->as_string) // return;

  # anchor refs: only for internal targets
  if (defined $frag && length $frag) {
    my $frag_norm = $frag;
    $frag_norm =~ s/^#//;
    # record only if internal; external anchors are intentionally ignored
    my $host = lc($abs->host // '');
    if ($host eq $base_host) {
      push @$anchor_refs_ref, { url => $base, anchor => "#$frag_norm" };
    }
  }

  # classify
  my $host = lc($abs->host // '');
  if ($host eq $base_host) {
    push @$internal_ref, $base;
  }
  else {
    push @$external_ref, $base;
  }
}

sub main_validation_loop ($self, $mce, $pid, $wid) {
  $self->_mark_phase($wid, 'main_validation_loop', 'started');
  my $key;
  my $no_work_count = 0;

  do {
    $self->_host_lock->lock;

    my @all_keys    = sort $self->_internal_q->keys();
    my @unvalidated = grep { !$self->_internal_q->{$_}->{validated} } @all_keys;

    $key = $unvalidated[0];
    if ($key) {
      $self->_internal_q->{$key}->{validated} = 1;
      $no_work_count = 0;
      $self->logger->info("pid $pid; wid $wid; validating $key");
    }
    else {
      $no_work_count++;
    }

    $self->_host_lock->unlock;

    if ($key) {
      $self->validate_links($key);
    }
    elsif ($no_work_count < 3) {
      select(undef, undef, undef, 0.1);
    }
  } while ($key);

  $self->_mark_phase($wid, 'main_validation_loop', 'complete');
  $self->logger->notice("pid $pid; wid $wid; validation complete");
}

sub validate_links ($self, $url) {
  my $entry = $self->_internal_q->{$url};

  # Validate internal links
  foreach my $link (@{ $entry->{pending_internal_links} }) {
    my $canon = $self->canon_url($link);
    if ( $self->_internal_q->exists($canon)
      && $self->_internal_q->{$canon}->{state} eq 'checked'
      && !$self->_internal_q->{$canon}->{error}) {
      my $status = $self->_internal_q->{$canon}->{http_status} // 0;
      if ($status >= 200 && $status < 400) {
        push @{ $entry->{successfull_internal_links} }, $link;
      }
      else {
        push @{ $entry->{broken_internal_links} }, $link;
      }
    }
    else {
      push @{ $entry->{broken_internal_links} }, $link;
    }
  }

  # Validate external links
  foreach my $link (@{ $entry->{pending_external_links} }) {
    my $canon = $self->canon_url($link);
    if ( $self->_external_q->exists($canon)
      && $self->_external_q->{$canon}->{state} eq 'checked'
      && !$self->_external_q->{$canon}->{error}) {
      my $status = $self->_external_q->{$canon}->{http_status} // 0;
      if ($status >= 200 && $status < 400) {
        push @{ $entry->{successfull_external_links} }, $link;
      }
      else {
        push @{ $entry->{broken_external_links} }, $link;
      }
    }
    else {
      push @{ $entry->{broken_external_links} }, $link;
    }
  }

  # Validate anchor refs
  foreach my $anchor_ref (@{ $entry->{pending_anchor_refs} }) {
    my $target_url = $anchor_ref->{url};
    my $anchor     = $anchor_ref->{anchor};
    $anchor =~ s/^#//;

    my $canon_url = $self->canon_url($target_url);

    # Check if target page exists, was fetched successfully, and has the anchor
    if ( $self->_internal_q->exists($canon_url)
      && $self->_internal_q->{$canon_url}->{state} eq 'checked'
      && !$self->_internal_q->{$canon_url}->{error}) {
      my $status = $self->_internal_q->{$canon_url}->{http_status} // 0;
      if ($status >= 200 && $status < 400) {
        my $target_anchors =
          $self->_internal_q->{$canon_url}->{possible_anchors} // [];
        if (grep { $_ eq $anchor } @$target_anchors) {
          push @{ $entry->{successfull_anchor_refs} }, $anchor_ref;
        }
        else {
          push @{ $entry->{broken_anchor_refs} }, $anchor_ref;
        }
      }
      else {
        # Target page returned an error status
        push @{ $entry->{broken_anchor_refs} }, $anchor_ref;
      }
    }
    else {
      # Target page doesn't exist, wasn't checked, or had an error
      push @{ $entry->{broken_anchor_refs} }, $anchor_ref;
    }
  }
}

1;
__END__
