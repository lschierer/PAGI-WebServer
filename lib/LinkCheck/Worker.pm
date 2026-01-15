
package LinkCheck::Worker;
use v5.42;
use utf8::all;

use Mooish::Base -standard;
with 'WebFramework::Role::Logger';
extends 'LinkCheck::Common';

use Carp;

sub mce_user_func ($self, $mce, $internal_q, $external_q) {
  my ($pid, $wid) = (MCE->pid, MCE->wid);
  $self->_internal_q($internal_q);
  $self->_external_q($external_q);

  $self->main_internal_loop($mce, $pid, $wid);
  $self->main_external_loop($mce, $pid, $wid);
  $self->main_validation_loop($mce, $pid, $wid);
}

sub main_external_loop ($self, $mce, $pid, $wid) {
  my $key;
  my $no_work_count = 0;
  my @in_progress;
  do {
    $self->_host_lock->lock;
    my @all_keys = $self->_external_q->keys();
    my @unchecked =
      sort grep { $self->_external_q->{$_}->{state} eq 'unchecked' } @all_keys;
    @in_progress =
      grep { $self->_external_q->{$_}->{state} eq 'in-progress' } @all_keys;

    $key = $unchecked[0];

    if ($key) {
      # Extract host from URL for throttling
      my $uri  = URI->new($key);
      my $host = $uri->host;

      # Check if we can make a request to this host
      my $now       = time;
      my $next_time = $self->_host_next_time->{$host} // 0;
      my $inflight  = $self->_host_inflight->{$host}  // 0;

      if ($now < $next_time) {
        # Too soon to request from this host, skip it
        $key = undef;
      }
      elsif ($inflight >= $self->external_host_slots) {
        # Too many concurrent requests to this host, skip it
        $key = undef;
      }
      else {
        # Claim this URL and update throttling state
        $self->_external_q->{$key}->{state}      = 'in-progress';
        $self->_external_q->{$key}->{claimed_at} = $now;
        $self->_external_q->{$key}->{claimed_by} = "$pid/$wid";

        # Update host throttling
        $self->_host_inflight->{$host} = $inflight + 1;
        my $jitter = rand($self->external_jitter);
        $self->_host_next_time->{$host} =
          $now + $self->external_min_interval + $jitter;

        $no_work_count = 0;
        my $msg = "pid $pid; wid $wid; claimed key $key";
        $self->logger->debug($msg);
        say $msg;
      }
    }
    elsif (@in_progress) {
      # Other workers are still processing, wait for them to add more work
      $no_work_count = 0;
      $self->logger->debug(sprintf(
        'pid %s; wid %s; no unchecked keys, but work in progress, will retry',
        $pid, $wid
      ));
    }
    else {
      # No unchecked, no in-progress = truly done
      $no_work_count++;
      $self->logger->debug(
        "pid $pid; wid $wid; no work found (count: $no_work_count)");
    }

    $self->_host_lock->unlock;

    if ($key) {
      $self->check_external_url($key);
    }
    elsif (@in_progress || $no_work_count < 3) {
      # Brief sleep to avoid spinning
      select(undef, undef, undef, 0.1);
    }
  } while ($key || @in_progress || $no_work_count < 3);
}

sub main_internal_loop ($self, $mce, $pid, $wid) {
  my $key;
  my $no_work_count = 0;
  my @in_progress;
  do {
    $self->_host_lock->lock;

    my @all_keys = $self->_internal_q->keys();
    my @unchecked =
      sort grep { $self->_internal_q->{$_}->{state} eq 'unchecked' } @all_keys;
    @in_progress =
      grep { $self->_internal_q->{$_}->{state} eq 'in-progress' } @all_keys;

    $key = $unchecked[0];
    if ($key) {
      $self->_internal_q->{$key}->{state}      = 'in-progress';
      $self->_internal_q->{$key}->{claimed_at} = time;
      $self->_internal_q->{$key}->{claimed_by} = "$pid/$wid";
      $no_work_count                           = 0;
      my $msg = "pid $pid; wid $wid; claimed key $key";
      $self->logger->debug($msg);
      say $msg;
    }
    elsif (@in_progress) {
      # Other workers are still processing, wait for them to add more work
      $no_work_count = 0;
      $self->logger->debug(sprintf(
        'pid %s; wid %s; no unchecked keys, but work in progress, will retry',
        $pid, $wid
      ));
    }
    else {
      # No unchecked, no in-progress = truly done
      $no_work_count++;
      $self->logger->debug(
        "pid $pid; wid $wid; no work found (count: $no_work_count)");
    }

    $self->_host_lock->unlock;

    if ($key) {
      $self->get_internal_url($key);
    }
    elsif (@in_progress || $no_work_count < 3) {
      # Brief sleep to avoid spinning
      select(undef, undef, undef, 0.1);
    }
  } while ($key || @in_progress || $no_work_count < 3);

  say "pid $pid; wid $wid; exiting - no more work";
}

sub check_external_url ($self, $url) {
  return unless ($url && length($url));
  $url = $self->canon_url($url);
  unless ($self->_external_q->exists($url)) {
    my $errmsg = "no external queue entry for $url";
    $self->logger->error($errmsg);
    warn($errmsg);
    return;
  }
  return if ($self->_external_q->{$url}->{state} eq 'checked');

  my $msg = "checking external url $url";
  say $msg;
  $self->logger->info($msg);

  my $uri  = URI->new($url);
  my $host = $uri->host;

  my $ua  = Future::HTTP->new();
  my $res = $ua->http_head($url)->then(sub {
    my ($body, $headers) = @_;

    # Check status code from headers
    my $status = $headers->{Status} // 0;

    if ($status >= 200 && $status < 400) {
      # Success or redirect - link is valid
      $self->logger->info("External link OK: $url (status $status)");
    }
    elsif ($status == 403 || $status == 405) {
      # Forbidden or Method Not Allowed - try GET instead
      return $ua->http_get($url)->then(sub {
        my ($body2, $headers2) = @_;
        my $status2 = $headers2->{Status} // 0;
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
      # Error
      $self->logger->warn("External link failed: $url (status $status)");
      $self->_external_q->{$url}->{error} = "HTTP $status";
    }
  })->catch(sub {
    my ($error) = @_;
    $self->logger->error("External link error: $url - $error");
    $self->_external_q->{$url}->{error} = "$error";
  })->finally(sub {
    # Decrement inflight count for this host
    $self->_host_lock->lock;
    my $inflight = $self->_host_inflight->{$host} // 1;
    $self->_host_inflight->{$host} = $inflight - 1;
    $self->_host_lock->unlock;
  })->get();

  $self->_external_q->{$url}->{state} = 'checked';
}

sub get_internal_url($self, $url) {
  return unless ($url && length($url));
  $url = $self->canon_url($url);
  unless ($self->_internal_q->exists($url)) {
    my $errmsg = "no internal queue entry for $url";
    $self->logger->error($errmsg);
    warn($errmsg);
    return;
  }
  return if ($self->_internal_q->{$url}->{state} eq 'checked');
  my $msg = "getting internal url $url";
  say $msg;
  $self->logger->info($msg);
  my $ua  = Future::HTTP->new();
  my $res = $ua->http_get($url)->then(sub {
    my ($body, $data) = @_;
    my $extracted = $self->process_url($url, $body, $data);

    # Store the extracted data (plain arrays/strings only)
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
      $host->fragment(undef);    # Remove fragment (#anchor)
      $host->query(undef);       # Remove query string (?param=value)

      my $base_url = $self->canon_url($host->as_string) // next;
      unless (exists $self->_internal_q->{$base_url}) {
        $self->_internal_q->{$base_url} = $self->_new_queue_item;
      }
    }
  })->get();
  $self->_internal_q->{$url}->{state} = 'checked';
}

sub process_url ($self, $url, $body, $data) {
  local (*STDERR);
  open STDERR, '>>', File::Spec->devnull();
  my $dom = XML::LibXML->load_xml(
    string          => $body,
    recover         => 1,
    suppress_errors => 1,
  );

  my $host = $self->base->{host};
  unless ($self->start->host_port =~ /(?:80|443)$/) {
    $host = sprintf('%s:%s', $host, $self->start->port);
  }
  $self->logger->debug("host is $host");

  my @all_links = $dom->findnodes('//a[@href]');
  $self->logger->debug(
    sprintf('Found %s total <a> tags with href', scalar(@all_links)));

  my @internal_links;
  my @external_links;
  my @anchor_refs;
  my @anchors;

  foreach my $linknode (@all_links) {
    my $href = $linknode->getAttribute('href');
    next unless $href;

    # Check if it has an anchor fragment
    my $has_anchor = $href =~ /#/;

    if ($href =~ m{^#}) {
      # Pure anchor reference on same page
      $self->logger->debug("  -> anchor ref (same page): $href");
      push @anchor_refs, { url => $url, anchor => $href };
    }
    elsif ($href =~ m{^/} || $href =~ /\Q$host\E/) {
      # Internal link
      $self->logger->debug("  -> internal: $href");
      push @internal_links, $href;

      # Extract anchor if present
      if ($has_anchor && $href =~ m{^(/[^#]+)(#.+)$}) {
        my ($path, $anchor) = ($1, $2);
        my $target_url = sprintf('%s%s', $self->base->{url}, $path);
        push @anchor_refs, { url => $target_url, anchor => $anchor };
        $self->logger->debug("  -> anchor ref (internal): $target_url $anchor");
      }
      elsif ($has_anchor && $href =~ m{^(https?://[^#]+)(#.+)$}) {
        my ($target_url, $anchor) = ($1, $2);
        push @anchor_refs, { url => $target_url, anchor => $anchor };
        $self->logger->debug(
          "  -> anchor ref (internal full): $target_url $anchor");
      }
    }
    else {
      # External link - don't track anchors for external links
      my $href_no_anchor = $href;
      $href_no_anchor =~ s/#.*$//;
      push @external_links, $href_no_anchor;
      $self->logger->debug("  -> external: $href_no_anchor");
    }
  }

  my @elements_with_id = $dom->findnodes('//*[@id]');
  $self->logger->debug(
    sprintf('Found %s elements with id attribute', scalar(@elements_with_id)));

  foreach my $element (@elements_with_id) {
    my $id = $element->getAttribute('id');
    if ($id) {
      $self->logger->debug("  -> anchor target: #$id");
      push @anchors, $id;
    }
  }

  $self->logger->info(
    sprintf('Total anchor targets found: %s', scalar(@anchors)));

  return {
    internal_links => \@internal_links,
    external_links => \@external_links,
    anchor_refs    => \@anchor_refs,
    anchors        => \@anchors,
  };
}

sub main_validation_loop ($self, $mce, $pid, $wid) {
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
      say "pid $pid; wid $wid; validating $key";
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
  } while ($key || $no_work_count < 3);

  say "pid $pid; wid $wid; validation complete";
}

sub validate_links ($self, $url) {
  my $entry = $self->_internal_q->{$url};

  # Validate internal links
  foreach my $link (@{ $entry->{pending_internal_links} }) {
    my $canon = $self->canon_url($link);
    if ( $self->_internal_q->exists($canon)
      && $self->_internal_q->{$canon}->{state} eq 'checked') {
      push @{ $entry->{successfull_internal_links} }, $link;
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
      push @{ $entry->{successfull_external_links} }, $link;
    }
    else {
      push @{ $entry->{broken_external_links} }, $link;
    }
  }

  # Validate anchor refs
  foreach my $anchor (@{ $entry->{pending_anchor_refs} }) {
    my $anchor_id = $anchor;
    $anchor_id =~ s/^#//;
    if (grep { $_ eq $anchor_id } @{ $entry->{possible_anchors} }) {
      push @{ $entry->{successfull_anchor_refs} }, $anchor;
    }
    else {
      push @{ $entry->{broken_anchor_refs} }, $anchor;
    }
  }
}

sub main_validation_loop ($self, $mce, $pid, $wid) {
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
      say "pid $pid; wid $wid; validating $key";
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
  } while ($key || $no_work_count < 3);

  say "pid $pid; wid $wid; validation complete";
}

sub validate_links ($self, $url) {
  my $entry = $self->_internal_q->{$url};

  # Validate internal links
  foreach my $link (@{ $entry->{pending_internal_links} }) {
    my $canon = $self->canon_url($link);
    if ( $self->_internal_q->exists($canon)
      && $self->_internal_q->{$canon}->{state} eq 'checked') {
      push @{ $entry->{successfull_internal_links} }, $link;
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
      push @{ $entry->{successfull_external_links} }, $link;
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

    # Check if target page exists and has the anchor
    if ( $self->_internal_q->exists($canon_url)
      && $self->_internal_q->{$canon_url}->{state} eq 'checked') {
      my $target_anchors = $self->_internal_q->{$canon_url}->{possible_anchors};
      if (grep { $_ eq $anchor } @$target_anchors) {
        push @{ $entry->{successfull_anchor_refs} }, $anchor_ref;
      }
      else {
        push @{ $entry->{broken_anchor_refs} }, $anchor_ref;
      }
    }
    else {
      # Target page doesn't exist or wasn't checked
      push @{ $entry->{broken_anchor_refs} }, $anchor_ref;
    }
  }
}

1;
__END__
