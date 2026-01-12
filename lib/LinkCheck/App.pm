package LinkCheck::App;
use v5.42;
use utf8::all;

use Mooish::Base -standard;
with 'WebFramework::Role::Logger';

use MCE;
use MCE::Queue;
use URI;
use Carp;

use LinkCheck::Worker ();

has start => (
  required  => 1,
  is        => 'rw',
);

has base_host => (
  is        => 'rw',
);

has workers   => (
  is          => 'ro',
  default     => 8,
);

has max_retries => (
  default   => 3,
  is        => 'ro',
);

has request_timeout => (
  default   => 60,
  is        => 'ro',
);

has inactive_timeout  => (
  default   => 30,
  is        => 'ro',
);

has job_timeout => (
  default   => 60,
  is        => 'ro',
);

has max_pages => (
  default   => 0,
  is        => 'ro',
);

has max_external  => (
  default   => 0,
  is        => 'ro',
);

has same_host_only  => (
  default   => 1,
  is        => 'ro',
);

has verbose => (
  default   => 1,
  is        => 'ro',
);

has _internal_q => (
  default   => sub {
    return MCE::Queue->new();
  },
  is        => 'rw',
);

has _external_q => (
  default   => sub {
    return MCE::Queue->new();
  },
  is        => 'rw',
);

has _scheduled_verify => (
  default => sub { {} },
  is      => 'rw',
);

has _seen => (
  default   => sub { {} },
  is        => 'rw',
);

has _reached_internal => ( default => sub { {} }, is => 'rw' );
has _verify_only      => ( default => sub { {} }, is => 'rw' );

has _ok => (
  default   => sub { {} },
  is        => 'rw',
);

has _anchors_for => (
  default   => sub { {} },
  is        => 'rw',
);

has _pending_anchor_refs => (
  default   => sub { {} },
  is        => 'rw',
);

has _broken => (
  default   => sub { {} },
  is        => 'rw',
);

has _job_seq => (
  default   => 0,
  is        => 'rw',
);

has _stats  => (
  is       => 'rw',
  default   => sub {
    return {
      internal_done => 0,
      external_done => 0,
    };
  }
);

sub execute ($self) {
  $self->start(URI->new($self->start));
  $self->base_host(lc $self->start->host);
  $self->_enqueue_internal($self->start->as_string);

  my $internal_q = $self->_internal_q;
  my $external_q = $self->_external_q;

  # gather callback runs in the manager (master)
  my $gather = sub {
    my ($mce, $chunk_id, $res) = @_;

    # Some MCE paths may call gather without $mce (depends on API / version).
    # If $mce isn't an object, shift interpretation.
    if (ref($mce) ne 'MCE') {
      ($chunk_id, $res) = @_;
    }

    return unless $res;
    $self->_merge_result($res);

    if ($internal_q->pending == 0) {
      $self->_promote_pending_anchor_bases;
    }

    return;
  };

  my $worker = sub {
    my ($mce, $chunk_ref, $chunk_id) = @_;
    $chunk_id //= 0;

    while (1) {
      my $job;
      my $u;

      if ($u = $internal_q->dequeue_nb) {
        $job = { url => $u, mode => 'internal' };
      }
      elsif ($u = $external_q->dequeue_nb) {
        $job = { url => $u, mode => 'external' };
      }
      else {
        last;
      }

      my $res;
      eval {
        $res = LinkCheck::Worker::run_job({
          %$job,
          base_host        => $self->base_host,
          max_retries      => $self->max_retries,
          request_timeout  => $self->request_timeout,
          inactive_timeout => $self->inactive_timeout,
          same_host_only   => $self->same_host_only ? 1 : 0,
        });
        1;
      } or do {
        my $err = $@ || 'unknown worker error';
        $res = {
          mode           => $job->{mode},
          page_url       => $job->{url},
          found_internal => [],
          found_external => [],
          anchors        => {},
          anchor_refs    => [],
          broken         => {
            $job->{url} => { status => 0, error => "worker exception: $err", occurrences => 1 }
          },
        };
      };

      MCE->gather($chunk_id, $res);
    }

    return;
  };

  my $mce = MCE->new(
    max_workers => $self->workers,
    user_func   => $worker,
    gather      => $gather,
  );

  # run with a dummy input; workers ignore chunk contents and pull from queues
  $mce->process([1]);

  $self->_finalize_pending_anchors;
  $self->_print_report;

  return (keys %{ $self->{_broken} }) ? 2 : 0;
}

sub _next_job ($self) {
  # stop conditions
  if ($self->{max_pages} && $self->{_stats}{internal_done} >= $self->{max_pages}) {
    # no more internal jobs
  } else {
    if (my $u = $self->{_internal_q}->dequeue_nb) {
      return { url => $u, mode => 'internal' };
    }
  }

  if ($self->{max_external} && $self->{_stats}{external_done} >= $self->{max_external}) {
    return undef;
  }

  if (my $u = $self->{_external_q}->dequeue_nb) {
    return { url => $u, mode => 'external' };
  }

  return undef;
}

sub _promote_pending_anchor_bases ($self) {
  state %scheduled;

  for my $base (keys %{ $self->{_pending_anchor_refs} }) {
    next if exists $self->{_anchors_for}{$base};  # already fetched & parsed anchors
    next if $scheduled{$base}++;

    # mark that we only pulled this because of pending anchor checks
    $self->{_verify_only}{$base} = 1
      unless $self->{_reached_internal}{$base};

    # IMPORTANT: bypass %seen gating if needed
    $self->{_external_q}->enqueue($base);
  }
}

sub _done ($self) {

  return $self->{_internal_q}->pending == 0
      && $self->{_external_q}->pending == 0;
}

# ------------------------
# State helpers
# ------------------------

sub _normalize_url ($self, $u) {
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

sub _enqueue_internal ($self, $u) {
  my $n = $self->_normalize_url($u) // return;

  $self->{_reached_internal}{$n} = 1;   # <- add this

  return if $self->{_seen}{$n}++;
  $self->{_internal_q}->enqueue($n);
}

sub _enqueue_external ($self, $u) {
  my $n = $self->_normalize_url($u) // return;
  return if $self->{_seen}{$n}++;
  $self->{_external_q}->enqueue($n);
}

sub _mark_broken ($self, %args) {
  my $link = $args{link};
  my $page = $args{page};

  $self->{_broken}{$link}{status} //= $args{status};
  $self->{_broken}{$link}{error}  //= $args{error};
  $self->{_broken}{$link}{pages}{$page} += ($args{occurrences} // 1);
}

sub _merge_result ($self, $res) {
  my $page = $res->{page_url};

  if ($res->{mode} eq 'internal') {
    $self->{_stats}{internal_done}++;
  } else {
    $self->{_stats}{external_done}++;
  }

  # Store anchors for this fetched page ASAP (so pending refs can resolve)
  if ($res->{anchors} && ref($res->{anchors}) eq 'HASH') {
    $self->_store_anchors($page, $res->{anchors});
  }

  # Record anchor refs found on this page (resolve now if possible, else pending)
  if ($res->{anchor_refs} && ref($res->{anchor_refs}) eq 'ARRAY') {
    for my $r (@{ $res->{anchor_refs} }) {
      $self->_record_anchor_ref(
        $page,
        $r->{base},
        $r->{frag},
        $r->{count} // 1
      );
    }
  }

  # page ok?
  if (!$res->{broken}{$page}) {
    $self->{_ok}{$page} = 1;
  }

  # Merge broken links found on that page
  for my $link (keys %{ $res->{broken} }) {
    my $b = $res->{broken}{$link};
    $self->_mark_broken(
      link        => $link,
      page        => $page,
      status      => $b->{status} // 0,
      error       => $b->{error}  // 'unknown error',
      occurrences => $b->{occurrences} // 1,
    );
  }

  if ($self->{_verify_only}{$page}) {
    if ($res->{broken}{$page}) {
      # page didn't exist / unreachable
      $self->_mark_broken(
        link  => $page,
        page  => '(nav)',
        status => $res->{broken}{$page}{status} // 0,
        error  => "NAV: referenced page not reachable/existing ($res->{broken}{$page}{error})",
        occurrences => 1,
      );
    } else {
      # page exists but was only discovered via fragment verification
      $self->_mark_broken(
        link  => $page,
        page  => '(nav)',
        status => 0,
        error  => "NAV: orphaned internal page (exists but not reachable from start crawl)",
        occurrences => 1,
      );
    }
  }

  # Enqueue newly found links
  for my $u (@{ $res->{found_internal} // [] }) {
    $self->_enqueue_internal($u);
  }
  for my $u (@{ $res->{found_external} // [] }) {
    $self->_enqueue_external($u);
  }
}

sub _record_anchor_ref ($self, $page, $base, $frag, $count = 1) {
  return unless defined $base && defined $frag && length $frag;

  # if we already know anchors for base, resolve immediately
  if (exists $self->{_anchors_for}{$base}) {
    if (exists $self->{_anchors_for}{$base}{$frag}) {
      return; # ok
    }

    # base fetched but anchor missing => broken
    $self->_mark_broken(
      link        => "$base#$frag",
      page        => $page,
      status      => 0,
      error       => "missing fragment #$frag",
      occurrences => $count,
    );
    return;
  }

  # base not fetched yet => pending
  $self->{_pending_anchor_refs}{$base}{$frag}{$page} += $count;
}

sub _store_anchors ($self, $base, $anchors) {
  return unless defined $base && $anchors && ref($anchors) eq 'HASH';

  $self->{_anchors_for}{$base} = $anchors;

  # resolve any pending refs now that we know anchors
  my $pending = delete $self->{_pending_anchor_refs}{$base} // return;

  for my $frag (keys %$pending) {
    for my $page (keys %{ $pending->{$frag} }) {
      my $count = $pending->{$frag}{$page};

      if (exists $anchors->{$frag}) {
        next; # ok
      }

      $self->_mark_broken(
        link        => "$base#$frag",
        page        => $page,
        status      => 0,
        error       => "missing fragment #$frag",
        occurrences => $count,
      );
    }
  }
}

sub _finalize_pending_anchors ($self) {
  for my $base (keys %{ $self->{_pending_anchor_refs} }) {
    for my $frag (keys %{ $self->{_pending_anchor_refs}{$base} }) {
      for my $page (keys %{ $self->{_pending_anchor_refs}{$base}{$frag} }) {
        my $count = $self->{_pending_anchor_refs}{$base}{$frag}{$page};

        # At this point we never fetched $base, so we can't know.
        # You can choose policy: treat as broken or "unverified".
        $self->_mark_broken(
          link        => "$base#$frag",
          page        => $page,
          status      => 0,
          error       => "fragment unverified (base not fetched): $base",
          occurrences => $count,
        );
      }
    }
  }

  $self->{_pending_anchor_refs} = {};
}

sub _print_report ($self) {
  say "Checked internal: $self->{_stats}{internal_done}";
  say "Checked external: $self->{_stats}{external_done}";
  say "Broken links: " . scalar(keys %{ $self->{_broken} });

  for my $link (sort keys %{ $self->{_broken} }) {
    my $e = $self->{_broken}{$link}{error} // '';
    say "\n$link\n  error: $e";
    for my $p (sort keys %{ $self->{_broken}{$link}{pages} }) {
      say "  on: $p (x$self->{_broken}{$link}{pages}{$p})";
    }
  }
}

1;
