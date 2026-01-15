package LinkCheck::Common;
use v5.42;
use utf8::all;

use Mooish::Base -standard;
with 'WebFramework::Role::Logger';

require MCE::Mutex;
require MCE::Shared;
require Future::HTTP;
require IO::FDPass;
use MCE::Loop;
use MCE::Queue;
use MCE;
use Sereal::Encoder;
use Sereal::Decoder;
use Time::HiRes qw(time);
use URI;
use Time::HiRes qw(sleep);

use Carp;

has start => (
  required => 1,
  is       => 'rw',
  coerce   => sub {
    my $val = shift;
    return ref($val) eq 'URI' ? $val : URI->new($val);
  },
);

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

has encoder => (
  default => sub { return Sereal::Encoder->new(); },
  is      => 'ro',
);

has decoder => (
  default => sub { return Sereal::Decoder->new(); },
  is      => 'ro',
);

#### internal variables

has base => (
  is      => 'rw',
  lazy    => 1,
  default => sub {
    my $self = shift;
    my $url  = $self->start->clone;
    $url->fragment(undef);
    $url->query(undef);
    $url->path('/');
    my $h = {
      host => lc($url->host),
      url  => $url,
    };
    return $h;
  }
);

has _internal_pending_count => (
  default => 0,
  is      => 'rw',
);

has _internal_q => (
  default => sub {
    my @data = ();
    return  MCE::Shared->hash({ _DEEPLY_ => 1, });

  },
  is => 'rw',
);

has _external_q => (
  default => sub {
    my @data = ();
    return  MCE::Shared->hash({ _DEEPLY_ => 1, });

  },
  is => 'rw',
);

has _worker_phase => (
  default => sub {
    my @data = ();
    return  MCE::Shared->hash({ _DEEPLY_ => 1, });

  },
  is => 'rw',
);

has _phase_lock => (
  default => sub { return MCE::Mutex->new },
  lazy    => 1,
  is      => 'rw',
);

has _broken => (
  default => sub { {} },
  is      => 'rw',
);

has _host_lock => (
  default => sub { return MCE::Mutex->new },
  lazy    => 1,
  is      => 'rw',
);

has _host_next_time => (
  is      => 'rw',
  default => sub { MCE::Shared->hash() },
);

has _host_inflight => (
  is      => 'rw',
  default => sub { MCE::Shared->hash() },
);

has external_min_interval => (is => 'ro', default => 1.0)
  ;    # seconds between requests per host
has external_jitter => (is => 'ro', default => 0.2);  # random 0..jitter seconds
has external_host_slots => (is => 'ro', default => 1)
  ;    # max concurrent requests per host

# Do not access directly, access via
# $self->_new_queue_item;
has _queue_item => (
  default => sub {
    return {
      pending_internal_links     => [],
      pending_external_links     => [],
      possible_anchors           => [],
      pending_anchor_refs        => [],
      successfull_internal_links => [],
      successfull_external_links => [],
      successfull_anchor_refs    => [],
      broken_internal_links      => [],
      broken_external_links      => [],
      broken_anchors             => [],
      broken_anchor_refs         => [],
      state                      => 'unchecked',
    };
  },
  is => 'ro',
);

sub _new_queue_item ($self) {
  $self->_internal_pending_count($self->_internal_pending_count + 1);
  # Return a plain hash - don't reference $self->_queue_item which has code refs
  return {
    pending_internal_links     => [],
    pending_external_links     => [],
    possible_anchors           => [],
    pending_anchor_refs        => [],
    successfull_internal_links => [],
    successfull_external_links => [],
    successfull_anchor_refs    => [],
    broken_internal_links      => [],
    broken_external_links      => [],
    broken_anchors             => [],
    broken_anchor_refs         => [],
    state                      => 'unchecked',
  };
}

sub canon_url ($self, $u) {
  return undef unless defined $u && length $u;

  my $uri = URI->new($u);
  return undef unless ($uri->scheme // '') =~ /^https?$/;

  $uri->fragment(undef);

  # Optional: if you don't want to treat query pages as distinct:
  $uri->query(undef);

  $uri->host(lc $uri->host) if $uri->host;

  # normalize default ports
  if ( ($uri->scheme eq 'http' && ($uri->port // 80) == 80)
    || ($uri->scheme eq 'https' && ($uri->port // 443) == 443)) {
    $uri->port(undef);
  }

  my $path = $uri->path;
  $path = '/' if !defined($path) || $path eq '';    # IMPORTANT

  $path =~ s{//+}{/}g;
  $path =~ s{/$}{} if $path ne '/';
  $uri->path($path);

  return $uri->as_string;
}

sub _mark_phase ($self, $wid, $phase, $value) {
  $self->_phase_lock->synchronize(sub {
    my $cur = $self->_worker_phase->{$wid}->{$phase} // '';

    my %rank = ( '' => 0, started => 1, complete => 2 );
    if ($rank{$value} > ($rank{$cur} // 0)) {
      $self->_worker_phase->{$wid}->{$phase} = $value;
    }
  });
}

sub _wait_all ($self, $wid, $phase, $total_workers) {

  my $done;
  do {
    $done = 0;

    $self->_phase_lock->synchronize( sub {
      for my $w (1 .. $total_workers) {
        if (($self->_worker_phase->{$w}->{$phase} // '') eq 'complete'){
          $self->logger->debug("wid $wid detects wid $w has completed phase $phase");
          $done++;
        } else {
          $self->logger->debug(sprintf('wid %s detects wid %s has not completed phase "%s": %s',
          $wid, $w, $phase, ($self->_worker_phase->{$w}->{$phase} // '') ));
        }
      }
    });

    select(undef, undef, undef, 0.05);
  } while ($done != $total_workers);
}

1;
__END__
