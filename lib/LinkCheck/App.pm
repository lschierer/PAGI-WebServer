package LinkCheck::App;
use v5.42;
use utf8::all;

use Mooish::Base -standard;
with 'WebFramework::Role::Logger';

use MCE;
use MCE::Queue;
require MCE::Shared;
require MCE::Mutex;
use URI;
use Time::HiRes qw(time);
use Carp;

use LinkCheck::Worker ();

has start => (
  required => 1,
  is       => 'rw',
);

has base_host => (is => 'rw',);

has workers => (
  is      => 'ro',
  default => 8,
);

has max_retries => (
  default => 3,
  is      => 'ro',
);

has request_timeout => (
  default => 60,
  is      => 'ro',
);

has inactive_timeout => (
  default => 30,
  is      => 'ro',
);

has job_timeout => (
  default => 60,
  is      => 'ro',
);

has max_pages => (
  default => 0,
  is      => 'ro',
);

has max_external => (
  default => 0,
  is      => 'ro',
);

has same_host_only => (
  default => 1,
  is      => 'ro',
);

has verbose => (
  default => 1,
  is      => 'ro',
);

# for use by logging
has env => (
  lazy    => 1,
  default => sub {
    my $self = shift;
    my $e    = $self->verbose ? 'development' : 'production';
    say "env is $e";
    return $e;
  },
  is => 'ro',
);

has _internal_q => (
  default => sub {
    return MCE::Queue->new();
  },
  is => 'rw',
);

has _external_q => (
  default => sub {
    return MCE::Queue->new();
  },
  is => 'rw',
);

has _scheduled_verify => (
  default => sub { {} },
  is      => 'rw',
);

has _seen => (
  default => sub { {} },
  is      => 'rw',
);

has _reached_internal => (default => sub { {} }, is => 'rw');
has _verify_only      => (default => sub { {} }, is => 'rw');

has _ok => (
  default => sub { {} },
  is      => 'rw',
);

has _anchors_for => (
  default => sub { {} },
  is      => 'rw',
);

has _pending_anchor_refs => (
  default => sub { {} },
  is      => 'rw',
);

has _broken => (
  default => sub { {} },
  is      => 'rw',
);

has _job_seq => (
  default => 0,
  is      => 'rw',
);

has _inflight  => (is => 'rw');
has _stop_sent => (is => 'rw');

has external_min_interval => (is => 'ro', default => 1.0)
  ;    # seconds between requests per host
has external_jitter => (is => 'ro', default => 0.2);  # random 0..jitter seconds
has external_host_slots => (is => 'ro', default => 1)
  ;    # max concurrent requests per host (usually 1)

has _host_lock      => (is => 'rw');
has _host_next_time => (is => 'rw');
has _host_inflight  => (is => 'rw');

has _stats => (
  is      => 'rw',
  default => sub {
    return {
      internal_done => 0,
      external_done => 0,
    };
  }
);

sub execute ($self) {
  $self->ensure_logging(__PACKAGE__);
  $self->start(URI->new($self->start));
  $self->base_host(lc $self->start->host);
  $self->_enqueue_internal($self->start->as_string);

  MCE::Shared->init;
  $self->_host_lock(MCE::Mutex->new);
  $self->_host_next_time(MCE::Shared->hash);    # host => epoch seconds
  $self->_host_inflight(MCE::Shared->hash);

  $self->_inflight(MCE::Shared->scalar(0));
  $self->_stop_sent(MCE::Shared->scalar(0));

  my $mce = MCE->new(
    max_workers => $self->workers,
    user_func   => sub { $self->_mce_worker(@_) },
    gather      => sub { $self->_mce_gather(@_) },
  );

  $mce->process([(1) x $self->workers]);

  $self->_finalize_pending_anchors;
  $self->_print_report;

  return (keys %{ $self->{_broken} }) ? 2 : 0;
}

sub _mce_worker ($self, $mce, $chunk_ref, $chunk_id) {
  $chunk_id //= 0;

  my $internal_q = $self->_internal_q;
  my $external_q = $self->_external_q;
  my $inflight   = $self->_inflight;

  while (1) {
    my ($u, $mode);

    # Prefer internal; block briefly so workers don't exit too early
    $u = $internal_q->dequeue_timed(0.25);
    if (defined $u) {
      $mode = 'internal';
    }
    else {
      $u = $external_q->dequeue_timed(0.25);
      next unless defined $u;
      $mode = 'external';
    }

    last if $u eq '__STOP__';

    $inflight->incr;

    my $job = { url => $u, mode => $mode };

    my $res;
    eval {
      local $SIG{ALRM} = sub { die "job alarm timeout\n" };
      alarm($self->job_timeout);

      state $worker_obj = LinkCheck::Worker->new(env => $self->env,);
      $worker_obj->ensure_logging('LinkCheck::Worker');
      $res = $worker_obj->run_job({
        %$job,
        base_host             => $self->base_host,
        max_retries           => $self->max_retries,
        request_timeout       => $self->request_timeout,
        inactive_timeout      => $self->inactive_timeout,
        same_host_only        => $self->same_host_only ? 1 : 0,
        external_min_interval => $self->external_min_interval,
        external_jitter       => $self->external_jitter,
        external_host_slots   => $self->external_host_slots,
        host_lock             => $self->_host_lock,
        host_next_time        => $self->_host_next_time,
        host_inflight         => $self->_host_inflight,
        verbose               => $self->verbose,

      });

      alarm(0);
      1;
    } or do {
      alarm(0);
      my $err = $@ || 'unknown worker error';
      $res = {
        mode           => $mode,
        page_url       => $u,
        found_internal => [],
        found_external => [],
        anchors        => {},
        anchor_refs    => [],
        broken         => {
          $u => {
            status      => 0,
            error       => "worker exception: $err",
            occurrences => 1
          }
        },
      };
    };

    MCE->gather($chunk_id, $res);
  }

  return;
}

sub _mce_gather ($self, @args) {
  my ($mce, $chunk_id, $res) = @args;

  # Some MCE versions call gather($chunk_id, $data)
  if (ref($mce) ne 'MCE') {
    ($chunk_id, $res) = @args;
  }

  return unless $res;

  my $internal_q = $self->_internal_q;
  my $external_q = $self->_external_q;
  my $inflight   = $self->_inflight;
  my $stop_sent  = $self->_stop_sent;

  $self->_merge_result($res);

  $inflight->decr;

  # once internal drained, promote anchor bases etc.
  if ($internal_q->pending == 0) {
    $self->_promote_pending_anchor_bases;
  }

  # stop condition: nothing queued + nothing inflight + no pending anchor refs
  if (!$stop_sent->get
    && $internal_q->pending == 0
    && $external_q->pending == 0
    && $inflight->get == 0
    && !keys %{ $self->{_pending_anchor_refs} }) {

    $stop_sent->set(1);

    # Send stop sentinels so workers exit cleanly
    $internal_q->enqueue(('__STOP__') x $self->workers);
    $external_q->enqueue(('__STOP__') x $self->workers);
  }

  return;
}

sub _next_job ($self) {
  # stop conditions
  if ( $self->{max_pages}
    && $self->{_stats}{internal_done} >= $self->{max_pages}) {
    # no more internal jobs
  }
  else {
    if (my $u = $self->{_internal_q}->dequeue_nb) {
      return { url => $u, mode => 'internal' };
    }
  }

  if ( $self->{max_external}
    && $self->{_stats}{external_done} >= $self->{max_external}) {
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
    next
      if exists $self->{_anchors_for}{$base}; # already fetched & parsed anchors
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

  if ( ($uri->scheme eq 'http' && ($uri->port // 80) == 80)
    || ($uri->scheme eq 'https' && ($uri->port // 443) == 443)) {
    $uri->port(undef);
  }

  return $uri->as_string;
}

sub _enqueue_internal ($self, $u) {
  my $n = $self->_normalize_url($u) // return;

  $self->{_reached_internal}{$n} = 1;    # <- add this

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
  }
  else {
    $self->{_stats}{external_done}++;
  }

  # Store anchors for this fetched page ASAP (so pending refs can resolve)
  if ($res->{anchors} && ref($res->{anchors}) eq 'HASH') {
    $self->_store_anchors($page, $res->{anchors});
  }

 # Record anchor refs found on this page (resolve now if possible, else pending)
  if ($res->{anchor_refs} && ref($res->{anchor_refs}) eq 'ARRAY') {
    for my $r (@{ $res->{anchor_refs} }) {
      $self->_record_anchor_ref($page, $r->{base}, $r->{frag},
        $r->{count} // 1);
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
      status      => $b->{status}      // 0,
      error       => $b->{error}       // 'unknown error',
      occurrences => $b->{occurrences} // 1,
    );
  }

  if ($self->{_verify_only}{$page}) {
    if ($res->{broken}{$page}) {
      # page didn't exist / unreachable
      $self->_mark_broken(
        link   => $page,
        page   => '(nav)',
        status => $res->{broken}{$page}{status} // 0,
        error  =>
"NAV: referenced page not reachable/existing ($res->{broken}{$page}{error})",
        occurrences => 1,
      );
    }
    else {
      # page exists but was only discovered via fragment verification
      $self->_mark_broken(
        link   => $page,
        page   => '(nav)',
        status => 0,
        error  =>
"NAV: orphaned internal page (exists but not reachable from start crawl)",
        occurrences => 1,
      );
    }
  }

  # Enqueue newly found links
  if (($res->{mode} // '') eq 'internal') {
    for my $u (@{ $res->{found_internal} // [] }) {
      $self->_enqueue_internal($u);
    }
    for my $u (@{ $res->{found_external} // [] }) {
      $self->_enqueue_external($u);
    }
  }
}

sub _record_anchor_ref ($self, $page, $base, $frag, $count = 1) {
  return unless defined $base && defined $frag && length $frag;

  # if we already know anchors for base, resolve immediately
  if (exists $self->{_anchors_for}{$base}) {
    if (exists $self->{_anchors_for}{$base}{$frag}) {
      return;    # ok
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
        next;    # ok
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

sub _broken_by_page ($self) {
  my %by_page;

  for my $link (keys %{ $self->{_broken} }) {
    my $e = $self->{_broken}{$link};

    for my $page (keys %{ $e->{pages} // {} }) {
      $by_page{$page}{$link} = {
        occurrences => $e->{pages}{$page},
        status      => $e->{status} // 0,
        error       => $e->{error}  // '',
      };
    }
  }

  return \%by_page;
}

sub _print_report ($self) {
  $self->logger->notice("Checked internal: $self->{_stats}{internal_done}");
  $self->logger->notice("Checked external: $self->{_stats}{external_done}");
  $self->logger->warn("Broken links: " . scalar(keys %{ $self->{_broken} }));

  # View 1: by page (best for fixing site content)
  my $by_page = $self->_broken_by_page;

  for my $page (sort keys %$by_page) {
    $self->logger->warn("\nPAGE: $page");
    for my $link (sort keys %{ $by_page->{$page} }) {
      my $d = $by_page->{$page}{$link};
      $self->logger->warn(sprintf(
        "  - %s (x%d) status=%s err=%s",
        $link, $d->{occurrences}, $d->{status}, ($d->{error} // '')
      ));
    }
  }

  # View 2: by link (good for deduping / spotting common failures)
  for my $link (sort keys %{ $self->{_broken} }) {
    my $e = $self->{_broken}{$link}{error} // '';
    $self->logger->warn("\nLINK: $link\n  error: $e");
    for my $p (sort keys %{ $self->{_broken}{$link}{pages} }) {
      $self->logger->warn("  on: $p (x$self->{_broken}{$link}{pages}{$p})");
    }
  }
}

1;
__END__
