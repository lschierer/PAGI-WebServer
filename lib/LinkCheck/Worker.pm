
package LinkCheck::Worker;
use v5.42;
use utf8::all;

use Mooish::Base -standard;
extends 'LinkCheck::Common';
require Future::HTTP;
require Data::Printer;
use Future;

use IO::Async::Loop;
use Net::Async::HTTP;
use Mojo::DOM58;
use Time::HiRes    qw(time);
use Scalar::Util   qw(blessed);
use List::AllUtils qw(min);
use Carp;

has field _loop => (
  is        => 'ro',
  predicate => -hidden,
  default   => sub ($self) {
    state $loop;
    return $loop //= IO::Async::Loop->new;
  }
);

has field _states => (
  predicate   => -hidden,
  is          => 'ro',
  default     => sub {
    return [qw(
      unchecked fetching  pending-parse
      parsing   parsed    validating
      completed
    )];
  }
)

has field _stateCounts => (
  predicate => -hidden,
  is        => 'rw',
  default   => sub ($self) {
    state $sc;
    foreach my $state ($self->_states->@*){
      $sc->{$state} = 0;
    }
    return $sc;
  }
);

sub mce_user_func ($self, $mce) {
  my ($pid, $wid) = (MCE->pid, MCE->wid);

  $self->logger->notice("pid $pid; wid $wid; starting unified worker loop");

# Unified state machine loop
# States: unchecked -> fetching -> pending-parse -> parsing -> parsed -> validating -> completed

  my $no_work_count = 0;
  my @pending_futures;
  my $all_completed = 0;
  state $loopCounter = 0;

  do {
    $loopCounter++;
    my $did_work = 0;

    # Always give the event loop a chance to progress network IO first.
    if (@pending_futures) {
      $self->_loop->loop_once(0.01);
      @pending_futures = grep { !$_->is_ready } @pending_futures;
      $did_work        = 1;
    }

    # If *any* fetch is in flight (internal or external),
    # we only schedule more fetches.
    # We deliberately do NOT parse/validate while
    # sockets are active to avoid starving IO.
    my $fetch_in_flight = @pending_futures ? 1 : 0;

    # Phase 1: Fetch unchecked internal URLs
    my @candidates =
      $self->_find_items_in_state($self->_internal_q, 'unchecked');
    state $uncheckedCount;
    $uncheckedCount //= 0;
    # only log on one worker to avoid spamming the logs
    # only log periodically to avoid spamming the logs.
    # *do* log when the count increases instead of decreases
    if (
      $wid == 1
      && ( $#candidates < ($uncheckedCount - 10)
        || $#candidates > $uncheckedCount
        || ($loopCounter % 5 == 0 && $uncheckedCount < 10)
        )
    ) {
      $uncheckedCount = scalar(@candidates);
      my $stateCounts = {
        unchecked       => 0,
        fetching        => 0,
        'pending-parse' => 0,
        parsing         => 0,
        parsed          => 0,
        validating      => 0,
        completed       => 0,
      };

      my $iter = $self->_internal_q->iterator;
      while (my ($key, $val) = $iter->()) {
        my $s = $val->{state};
        $stateCounts->{$s}++;
      }

      $self->logger->debug(sprintf(
        '_internal_q has items in states: %s; fetch_in_flight is %s',
        Data::Printer::np($stateCounts, multiline => 0),
        $fetch_in_flight
      ));
    }

    # a small queue here actually works to
    # ensure we parse pages at right rate.
    my $maxIndex = min($#candidates, 2);
    for my $index (0 .. $maxIndex) {
      my $url = $candidates[$index];
      next if ($url eq $self->start && $wid != 1);
      my $uri  = URI->new($url);
      my $host = $uri->host // '';
      my $now  = time;

      my $claimed = 0;

      # Shared per-host throttling across workers
      $self->_host_lock->synchronize(sub {
        my $next_time = $self->_host_next_time->{$host} // 0;
        my $inflight  = $self->_host_inflight->{$host}  // 0;

        return if $now < $next_time;
        return if $inflight >= $self->external_host_slots;

        $self->_host_inflight->{$host} = $inflight + 1;
        $claimed = 1;
      });

      next unless $claimed;

      # Atomically claim the URL (prevents duplicate fetch across workers).
      my $url_claimed = 0;

      $self->_phase_lock->synchronize(sub {
        my $entry = $self->_internal_q->get($url);
        my $st    = $entry->{state} // '';
        return unless $st eq 'unchecked';
        $self->logger->debug(
          sprintf('wid %s marking "%s" from "%s" to fetching', $wid, $url, $st)
        );
        $entry->{state} = 'fetching';
        $self->_internal_q->set($url, $entry);
        $url_claimed = 1;
      });

     # If we lost the race to another worker, release the host slot and move on.
      unless ($url_claimed) {
        $self->_host_lock->synchronize(sub {
          my $cur = $self->_host_inflight->{$host} // 0;
          $cur-- if $cur > 0;
          $self->_host_inflight->{$host} = $cur;
        });
        next;
      }
      push @pending_futures, $self->_fetch_internal_url($url)->on_ready(sub {
        # Release host slot + set next allowed time (shared across workers)
        my $jitter = rand($self->external_jitter);
        my $t      = time + $self->external_min_interval + $jitter;
        $self->_host_lock->synchronize(sub {
          my $cur = $self->_host_inflight->{$host} // 0;
          $cur-- if $cur > 0;
          $self->_host_inflight->{$host}  = $cur;
          $self->_host_next_time->{$host} = $t;
        });
      });

      $did_work        = 1;
      $fetch_in_flight = 1;

      # Don’t try to claim too many at once; let other workers get a turn.
      last if ($url_claimed);
    }

# Phase 2: Fetch unchecked external URLs (also safe while other fetches are in flight)
    my @ext_candidates =
      $self->_find_items_in_state($self->_external_q, 'unchecked', 25);

    for my $url (@ext_candidates) {
      my $uri  = URI->new($url);
      my $host = $uri->host // '';
      my $now  = time;

      my $claimed = 0;
      $self->_host_lock->synchronize(sub {
        my $next_time = $self->_host_next_time->{$host} // 0;
        my $inflight  = $self->_host_inflight->{$host}  // 0;

        return if $now < $next_time;
        return if $inflight >= $self->external_host_slots;

        $self->_host_inflight->{$host} = $inflight + 1;
        $claimed = 1;
      });

      next unless $claimed;

      my $url_claimed = 0;
      $self->_phase_lock->synchronize(sub {
        my $entry = $self->_external_q->get($url);
        my $st    = $entry->{state} // '';
        return unless $st eq 'unchecked';
        $self->logger->debug(
          sprintf('wid %s marking "%s" as fetching', $wid, $url));
        $entry->{state} = 'fetching';
        $self->_external_q->set($url, $entry);
        $url_claimed = 1;
      });

      unless ($url_claimed) {
        $self->_host_lock->synchronize(sub {
          my $cur = $self->_host_inflight->{$host} // 0;
          $cur-- if $cur > 0;
          $self->_host_inflight->{$host} = $cur;
        });
        next;
      }

      push @pending_futures, $self->_fetch_external_url($url)->on_ready(sub {
        my $jitter = rand($self->external_jitter);
        my $t      = time + $self->external_min_interval + $jitter;
        $self->_host_lock->synchronize(sub {
          my $cur = $self->_host_inflight->{$host} // 0;
          $cur-- if $cur > 0;
          $self->_host_inflight->{$host}  = $cur;
          $self->_host_next_time->{$host} = $t;
        });
      });

      $did_work        = 1;
      $fetch_in_flight = 1;
      last;
    }

    # Decision point: ONLY parse/validate
    # when we know there are no active fetches.
    $fetch_in_flight =
      (    !$self->_any_in_states($self->_internal_q, [qw(unchecked fetching)])
        && !$self->_any_in_states($self->_external_q, [qw(unchecked fetching)])
      );
    if ($fetch_in_flight) {

      # 1) If there are backlogged pages to parse,
      # parse ONE page, then loop again.
      my @to_parse =
        $self->_find_items_in_state($self->_internal_q, 'pending-parse');

      while (my $url = shift @to_parse) {
        # Tiny yield before CPU work so we never fully starve the loop.
        $self->_loop->loop_once(0);
        next unless ($self->_internal_q->{$url}->{state} eq 'pending-parse');

        $self->logger->debug(
          sprintf('wid %s selected %s for parsing', $wid, $url));
        $self->_process_fetched_page($url);


        $did_work = 1;

      }

      # 2) If nothing is left to parse/fetch, we may validate.
      my $ready_to_validate = (
        !$self->_any_in_states($self->_internal_q,
          [qw(unchecked fetching pending-parse parsing)])
          && !$self->_any_in_states($self->_external_q,
          [qw(unchecked fetching)])
      );

      if ($ready_to_validate) {
        my @to_validate = $self->_internal_q()->keys("key eq parsed");
        @to_validate = splice(@to_validate, 0, 5);

        for my $url (@to_validate) {
          $self->_phase_lock->synchronize(sub {
            my $entry = $self->_internal_q->get($url);
            $entry->{state} = 'validating';
            $self->_internal_q->set($url, $entry);
          });

          my $done = $self->validate_links($url);

          $self->_phase_lock->synchronize(sub {
            # Only mark completed if validate_links was able to fully decide everything.
            my $entry = $self->_internal_q->get($url);
            $entry->{state} = $done ? 'completed' : 'parsed';
            $self->_internal_q->set($url, $entry);
          });

          $did_work = 1;
        }
      }
    }

    # Process event loop for pending futures
    if (@pending_futures) {
      $self->_loop->loop_once(0.01);
      @pending_futures = grep { !$_->is_ready } @pending_futures;
      $did_work        = 1;
    }

    # Check if we're done - only exit when everything is completed
    $all_completed = 1;
    $self->_phase_lock->synchronize(sub {
      for my $key ($self->_internal_q->keys()) {
        if (($self->_internal_q->{$key}->{state} // '') ne 'completed') {
          $all_completed = 0;
          last;
        }
      }
    });

    if ($all_completed) {
      # Check external queue too
      $self->_phase_lock->synchronize(sub {
        for my $key ($self->_external_q->keys()) {
          if (($self->_external_q->{$key}->{state} // '') ne 'completed') {
            $all_completed = 0;
            last;
          }
        }
      });

    }

    # If we didn't do any work this iteration, sleep a bit
    if (!$did_work && !@pending_futures) {
      select(undef, undef, undef, 0.1);
    }
  } while ($all_completed == 0);

  $self->logger->notice("pid $pid; wid $wid; all items completed, exiting");
}

sub _find_items_in_state ($self, $queue, $state, $limit = undef) {
  my @items;
  my $iter = $self->_internal_q->iterator;
  while (my ($key, $val) = $iter->()) {
    my $s = $val->{state};
    if ($s eq $state) {
      push @items, $key;
      if(defined($limit) && scalar(@items) >= $limit){
        last;
      }
    }
  }

  return sort @items;
}

sub _any_in_states ($self, $queue, $states) {
  my $wanted = {};

  my $found = 0;

  foreach my $s ($states->@*) {
    $wanted->{$s}++;
  }

  my $iter = $self->_internal_q->iterator;
  while (my ($key, $val) = $iter->()) {
    my $s = $val->{state};
    if (exists $wanted->{$s}) {
      $found = 1;
      last;
    }
  }

  return $found;
}

sub _fetch_internal_url ($self, $url) {
  my $ua = $self->_ua;
  return $ua->GET($url)->then(sub {
    my ($response) = @_;
    my $status     = $response->code;
    my $body       = $response->decoded_content;

    if ($status >= 200 && $status < 400 && defined($body)) {
      $self->_host_lock->synchronize(sub {
        my $entry = $self->_internal_q->get($url);
        $entry->{http_status}   = $status;
        $entry->{response_body} = $body;
        $entry->{content_type}  = $response->header('Content-Type');
        $entry->{state}         = 'pending-parse';
        delete $entry->{retry_count};
        $self->_internal_q->set($url, $entry);
      });
    }
    else {
      $self->logger->warn("Internal link failed: $url (status $status)");
      $self->_phase_lock->synchronize(sub {
        my $entry = $self->_internal_q->get($url);
        $entry->{http_status} = $status;
        $entry->{error}       = "HTTP $status";
        $entry->{state}       = 'completed';
        $self->_internal_q->set($url, $entry);
      });
    }
    return Future->done;
  })->catch(sub {
    my ($error) = @_;

    # Check if it's a timeout and retry
    if ($error =~ /timed out/i) {
      my $entry       = $self->_internal_q->get($url);
      my $retry_count = $entry->{retry_count} // 0;
      if ($retry_count < 2) {
        $self->logger->warn("Internal link timeout: $url - retrying (attempt "
            . ($retry_count + 1)
            . ")");
        $self->_host_lock->synchronize(sub {
          my $e = $self->_internal_q->get($url);
          $e->{retry_count} = $retry_count + 1;
          $e->{state}       = 'unchecked';
          $self->_internal_q->set($url, $e);
        });
        return Future->done;
      }
    }

    $self->logger->error("Internal link error: $url - $error");
    $self->_host_lock->synchronize(sub {
      my $entry = $self->_internal_q->get($url);
      $entry->{error}       = "$error";
      $entry->{http_status} = 0;
      $entry->{state}       = 'completed';
      $self->_internal_q->set($url, $entry);
    });
    return Future->done;
  });
}

sub _fetch_external_url ($self, $url) {
  my $ua = $self->_ua;
  return $ua->HEAD($url)->then(sub {
    my ($response) = @_;
    my $status = $response->code;

    if ($status >= 200 && $status < 400) {
      $self->logger->info("External link OK: $url (status $status)");
      $self->_phase_lock->synchronize(sub {
        my $entry = $self->_external_q->get($url);
        $entry->{http_status} = $status;
        $entry->{state}       = 'completed';
        $self->_external_q->set($url, $entry);
      });
    }
    elsif ($status == 403 || $status == 405) {
      # Retry with GET
      return $ua->GET($url)->then(sub {
        my ($response2) = @_;
        my $status2 = $response2->code;

        $self->_phase_lock->synchronize(sub {
          my $entry = $self->_external_q->get($url);
          $entry->{http_status} = $status2;
          if ($status2 >= 200 && $status2 < 400) {
            $self->logger->info(
              "External link OK (via GET): $url (status $status2)");
          }
          else {
            $self->logger->warn("External link failed: $url (status $status2)");
            $entry->{error} = "HTTP $status2";
          }
          $entry->{state} = 'completed';
          $self->_external_q->set($url, $entry);
        });
        return Future->done;
      });
    }
    else {
      $self->logger->warn("External link failed: $url (status $status)");
      $self->_phase_lock->synchronize(sub {
        my $entry = $self->_external_q->get($url);
        $entry->{http_status} = $status;
        $entry->{error}       = "HTTP $status";
        $entry->{state}       = 'completed';
        $self->_external_q->set($url, $entry);
      });
    }
    return Future->done;
  })->catch(sub {
    my ($error) = @_;

    # Check if it's a timeout and retry
    if ( $error =~ /timed out/i
      || $error =~ /Connection closed while awaiting header/i
      || $error =~ /Spurious on_read of connection while idle/i) {
      my $entry       = $self->_external_q->get($url);
      my $retry_count = $entry->{retry_count} // 0;
      if ($retry_count < 2) {
        $self->logger->warn("External link timeout: $url - retrying (attempt "
            . ($retry_count + 1)
            . ")");
        $self->_phase_lock->synchronize(sub {
          my $e = $self->_external_q->get($url);
          $e->{retry_count} = $retry_count + 1;
          $e->{state}       = 'unchecked';    # Requeue
          $self->_external_q->set($url, $e);
        });
        return Future->done;
      }
    }

    $self->logger->error("External link error: $url - $error");
    $self->_phase_lock->synchronize(sub {
      my $entry = $self->_external_q->get($url);
      $entry->{error}       = "$error";
      $entry->{http_status} = 0;
      $entry->{state}       = 'completed';
      $self->_external_q->set($url, $entry);
    });
    return Future->done;
  });
}



sub _process_fetched_page ($self, $url) {
  # Defensive check - ensure entry exists before processing
  my $can_proceed = 0;
  $self->_phase_lock->synchronize(sub {
    unless ($self->_internal_q->exists($url)) {
      $self->logger->error(
        "_process_fetched_page called with non-existent URL: '$url'");
      return;
    }
    my $entry = $self->_internal_q->get($url);
    return unless ($entry->{state} eq 'pending-parse');

    $entry->{state} = 'parsing';
    $self->_internal_q->set($url, $entry);
    $can_proceed = 1;
  });
  return unless $can_proceed;
  $self->logger->debug(sprintf('processing "%s"', $url));

  my $body         = $self->_internal_q->{$url}->{response_body};
  my $content_type = $self->_internal_q->{$url}->{content_type} // '';

  # Skip processing for non-HTML content (but assume HTML if no content-type)
  if ($content_type && $content_type !~ m{text/html}i) {
    $self->logger->debug("Skipping non-HTML content: $url ($content_type)");
    $self->_phase_lock->synchronize(sub {

      my $entry = $self->_internal_q->get($url);
      $entry->{pending_internal_links} = [];
      $entry->{pending_external_links} = [];
      $entry->{pending_anchor_refs}    = [];
      $entry->{possible_anchors}       = [];
      $entry->{state}                  = 'parsed';

      delete $entry->{response_body};
      delete $entry->{content_type};

      $self->_internal_q->set($url, $entry);
    });
    return;
  }

  my $headers = {
    Status         => $self->_internal_q->{$url}->{http_status},
    'content-type' => $content_type || 'text/html',
  };

  my $extracted = $self->process_url($url, $body, $headers);

  $self->_phase_lock->synchronize(sub {
    my $e = $self->_internal_q->get($url);

    $e->{pending_internal_links} = $extracted->{internal_links} // [];
    $e->{pending_external_links} = $extracted->{external_links} // [];
    $e->{pending_anchor_refs}    = $extracted->{anchor_refs}    // [];
    $e->{possible_anchors}       = $extracted->{anchors}        // [];

    $self->_internal_q->set($url, $e);
  });

  foreach my $link (@{ $extracted->{internal_links} }) {
    # Skip if link is not a string (shouldn't happen, but defensive)
    if (ref($link)) {
      $self->logger->error("INVALID: internal_link is a ref: " . ref($link));
      next;
    }

    if ($link =~ /^\//) {
      $link = sprintf('%s%s', $self->base->{url}, $link);
    }
    my $uri  = URI->new($link);
    my $host = $uri->clone;
    $host->fragment(undef);
    $host->query(undef);

    my $base_url = $self->canon_url($host->as_string) // next;

    # Validate base_url is a proper string, not a reference
    if (ref($base_url)) {
      $self->logger->error(
        "INVALID base_url is a ref: " . ref($base_url) . " from link '$link'");
      next;
    }

    $self->_phase_lock->synchronize(sub {
      unless (exists $self->_internal_q->{$base_url}) {
        $self->logger->debug(
          "about to add base_url '$base_url' to _internal_q");
        $self->_internal_q->set("$base_url", $self->_new_queue_item());
      }
    });
  }

  for my $ext (@{ $extracted->{external_links} // [] }) {
    my $canon = $self->canon_url($ext) // next;

    next
      if URI->new($canon)->host
      && lc(URI->new($canon)->host) eq $self->base->{host};

    $self->_phase_lock->synchronize(sub {
      unless ($self->_external_q->exists($canon)) {
        $self->logger->debug("about to add '$canon' to external_q");
        $self->_external_q->set($canon, $self->_new_queue_item());
      }
    });
  }

  # Clean up stored response data and mark as parsed
  $self->_phase_lock->synchronize(sub {
    my $entry = $self->_internal_q->get($url);
    delete $entry->{response_body};
    delete $entry->{content_type};
    $entry->{state} = 'parsed';
    $self->_internal_q->set($url, $entry);
  });
}

sub process_url ($self, $url, $body, $headers) {
  my $base_host = $self->base->{host};              # already lc()
  my $base_root = $self->base->{url}->as_string;    # e.g. https://example.com

  my (@internal, @external, @anchor_refs, @anchors);

  unless (defined($body) && length($body)) {
    $self->logger->error("invalid body for url '$url' in process_url");
    $self->logger->debug(sprintf(
      'body of invalid url "%s" is %s',
      $url, defined($body) ? ref($body) : 'undef'
    ));
    # return a valid shape to preserve the api
    return {
      internal_links => [],
      external_links => [],
      anchor_refs    => [],
      anchors        => [],
    };
  }

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

sub validate_links ($self, $url) {
  my $entry = $self->_internal_q->{$url};

  # Defensive: ensure arrays are initialized
  # Ensure arrays are initialized
  $entry->{broken_internal_links}      //= [];
  $entry->{broken_external_links}      //= [];
  $entry->{broken_anchor_refs}         //= [];
  $entry->{successfull_internal_links} //= [];
  $entry->{successfull_external_links} //= [];
  $entry->{successfull_anchor_refs}    //= [];

  $entry->{pending_internal_links} //= [];
  $entry->{pending_external_links} //= [];
  $entry->{pending_anchor_refs}    //= [];

  $self->logger->debug(sprintf(
'validating "%s" with %s pending links, %s broken internal and %s broken external',
    $url,
    scalar(@{ $entry->{pending_internal_links} }) +
      scalar(@{ $entry->{pending_external_links} }),
    scalar(@{ $entry->{broken_internal_links} }),
    scalar(@{ $entry->{broken_external_links} }),
  ));

  my (@still_pending_internal, @still_pending_external, @still_pending_anchors);

# Internal links:
# - If target doesn't exist in queue => broken (can't ever be resolved)
# - If target is still in-flight (or not yet completed) with no error => keep pending
# - If completed, decide based on status / error
  foreach my $link (@{ $entry->{pending_internal_links} }) {
    my $canon = $self->canon_url($link);
    unless (defined $canon && length $canon) {
      push @{ $entry->{broken_internal_links} }, $link;
      next;
    }

    unless ($self->_internal_q->exists($canon)) {
      $self->logger->debug(
        "Link $link marked broken: not in queue (canon: $canon)");
      push @{ $entry->{broken_internal_links} }, $link;
      next;
    }

    my $t  = $self->_internal_q->{$canon};
    my $st = $t->{state} // '';

    # Not fully finished yet and no error => defer decision
    if ($st ne 'completed' && !$t->{error}) {
      push @still_pending_internal, $link;
      next;
    }

    if ($t->{error}) {
      $self->logger->debug(
        "Link $link marked broken: has error " . $t->{error});
      push @{ $entry->{broken_internal_links} }, $link;
      next;
    }

    my $status = $t->{http_status} // 0;
    if ($status >= 200 && $status < 400) {
      push @{ $entry->{successfull_internal_links} }, $link;
    }
    else {
      push @{ $entry->{broken_internal_links} }, $link;
    }
  }

  # External links
  foreach my $link (@{ $entry->{pending_external_links} }) {
    my $canon = $self->canon_url($link);
    unless (defined $canon && length $canon) {
      push @{ $entry->{broken_external_links} }, $link;
      next;
    }

    unless ($self->_external_q->exists($canon)) {
      push @{ $entry->{broken_external_links} }, $link;
      next;
    }

    my $t  = $self->_external_q->{$canon};
    my $st = $t->{state} // '';

    if ($st ne 'completed' && !$t->{error}) {
      push @still_pending_external, $link;
      next;
    }

    if ($t->{error}) {
      push @{ $entry->{broken_external_links} }, $link;
      next;
    }

    my $status = $t->{http_status} // 0;
    if ($status >= 200 && $status < 400) {
      push @{ $entry->{successfull_external_links} }, $link;
    }
    else {
      push @{ $entry->{broken_external_links} }, $link;
    }
  }

  # Anchor refs
  foreach my $anchor_ref (@{ $entry->{pending_anchor_refs} }) {
    my $target_url = $anchor_ref->{url};
    my $anchor     = $anchor_ref->{anchor};

    $anchor //= '';
    $anchor =~ s/^#//;

    my $canon_url = $self->canon_url($target_url);
    unless (defined $canon_url && length $canon_url) {
      push @{ $entry->{broken_anchor_refs} }, $anchor_ref;
      next;
    }

    unless ($self->_internal_q->exists($canon_url)) {
      push @{ $entry->{broken_anchor_refs} }, $anchor_ref;
      next;
    }

    my $t  = $self->_internal_q->{$canon_url};
    my $st = $t->{state} // '';

    # We can only validate anchors once the target page is at least parsed.
    if ((
           $st eq 'unchecked'
        || $st eq 'fetching'
        || $st eq 'pending-parse'
        || $st eq 'parsing'
      )
      && !$t->{error}
    ) {
      push @still_pending_anchors, $anchor_ref;
      next;
    }

    if ($t->{error}) {
      push @{ $entry->{broken_anchor_refs} }, $anchor_ref;
      next;
    }

    my $status = $t->{http_status} // 0;
    if ($status >= 200 && $status < 400) {
      my $target_anchors = $t->{possible_anchors} // [];
      if (grep { $_ eq $anchor } @$target_anchors) {
        push @{ $entry->{successfull_anchor_refs} }, $anchor_ref;
      }
      else {
        push @{ $entry->{broken_anchor_refs} }, $anchor_ref;
      }
    }
    else {
      push @{ $entry->{broken_anchor_refs} }, $anchor_ref;
    }
  }

# Preserve unresolved work so we can retry validation later if we were invoked early.
  @{ $entry->{pending_internal_links} } = @still_pending_internal;
  @{ $entry->{pending_external_links} } = @still_pending_external;
  @{ $entry->{pending_anchor_refs} }    = @still_pending_anchors;

  # Return true only if everything was decided.
  return (@still_pending_internal
      || @still_pending_external
      || @still_pending_anchors) ? 0 : 1;

}

1;
__END__
