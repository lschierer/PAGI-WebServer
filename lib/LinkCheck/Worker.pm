
package LinkCheck::Worker;
use v5.42;
use utf8::all;

use Mooish::Base -standard;
with 'WebFramework::Role::Logger';
extends 'LinkCheck::Common';

use Carp;

sub mce_user_func ($self, $mce, $internal_q) {
  my ($pid, $wid) = (MCE->pid, MCE->wid);
  my $key;
  my $no_work_count = 0;
  my @in_progress;
  do {
    $self->_host_lock->lock;

    my @all_keys = $internal_q->keys();
    my @unchecked =
      grep { $internal_q->{$_}->{state} eq 'unchecked' } @all_keys;
    @in_progress =
      grep { $internal_q->{$_}->{state} eq 'in-progress' } @all_keys;

    $key = $unchecked[0];
    if ($key) {
      $internal_q->{$key}->{state} = 'in-progress';
      $internal_q->{$key}->{claimed_at} = time;
      $internal_q->{$key}->{claimed_by} = "$pid/$wid";
      $no_work_count = 0;
      say "pid $pid; wid $wid; claimed key $key";
    }
    elsif (@in_progress) {
      # Other workers are still processing, wait for them to add more work
      $no_work_count = 0;
      say sprintf(
      'pid %s; wid %s; no unchecked keys, but work in progress, will retry',
      $pid, $wid);
    }
    else {
      # No unchecked, no in-progress = truly done
      $no_work_count++;
      say "pid $pid; wid $wid; no work found (count: $no_work_count)";
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



sub get_internal_url($self, $url) {
  return unless ($url && length($url));
  unless ($self->_internal_q->exists($url)) {
    my $errmsg = "no internal queue entry for $url";
    $self->logger->error($errmsg);
    warn($errmsg);
    return;
  }
  return if ($self->_internal_q->{$url}->{state} eq 'checked');
  say "getting internal url $url";
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

    if ($href =~ m{^#}) {
      $self->logger->debug("  -> anchor: $href");
      push @anchor_refs, $href;
    }
    elsif ($href =~ m{^/} || $href =~ /\Q$host\E/) {
      $self->logger->debug("  -> internal: $href");
      push @internal_links, $href;
    }
    else {
      push @external_links, $href;
      $self->logger->debug("  -> external: $href ");
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

sub _done ($self) {

  return $self->{_internal_q}->pending == 0
    && $self->{_external_q}->pending == 0;
}

1;
__END__
