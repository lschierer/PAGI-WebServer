package LinkCheck::Role::Validator;
use v5.42;
use utf8::all;
# cspell: disable

use Mooish::Base -role;

use LinkCheck::Util qw(canon_url_string);

use URI;
use Scalar::Util qw(blessed);

# NOTE: parse_task is a Step task sub, not a method.
# It must instantiate something that has parse_one + logger.
require LinkCheck::Worker;

# context slot for data from the master
our $CTX;
sub ctx () {$CTX}

sub validate_task ($mce, $chunk_ref, $chunk_id) {
  state $worker_obj = LinkCheck::Worker->new();

  my @results;
  for my $item (@$chunk_ref) {
    push @results, $worker_obj->validate_one($item);
  }

  MCE->gather(\@results);
}

sub validate_one($self, $item) {
  my $ctx         = LinkCheck::Role::Validator::ctx();
  my $known_pages = $ctx->{known_pages};                 # MCE::Shared::Hash
  my $page_index  = $ctx->{page_index};                  # MCE::Shared::Hash

  my $source_url = $item->{url} // '(unknown)';

  my $entry = {
    source_url                 => $source_url,
    broken_internal_links      => [],
    broken_external_links      => [],
    broken_anchor_refs         => [],
    successfull_internal_links => [],
    successfull_external_links => [],
    successfull_anchor_refs    => [],
  };

  my $di = $item->{discovered_internal} // [];
  my $de = $item->{discovered_external} // [];

  $self->logger->debug(sprintf(
    'validating "%s" with %d discovered links',
    $source_url, scalar(@$di) + scalar(@$de),
  ));

  foreach my $link (@{$di}) {
    my $canon = canon_url_string($link);
    unless (defined $canon && length $canon) {
      push @{ $entry->{broken_internal_links} }, $link;
      next;
    }

    unless ($known_pages->get($canon)) {
      $self->logger->debug(
        "Link $link marked broken: not in known_pages (canon: $canon)");
      push @{ $entry->{broken_internal_links} }, $link;
      next;
    }

    my $t = $page_index->get($canon);
    unless ($t && ref($t) eq 'HASH') {
      $self->logger->debug(
        "Link $link marked broken: missing page_index entry (canon: $canon)");
      push @{ $entry->{broken_internal_links} }, $link;
      next;
    }

    if ($t->{ok} == 0) {
      $self->logger->debug(
        "Link $link marked broken: page_index indicates failure (ok is 0)");
      push @{ $entry->{broken_internal_links} }, $link;
      next;
    }

    my $status = $t->{http_status} // 0;
    # not authorized means the page exists,
    # that's a success code for a crawler
    if ($status >= 200 && ($status < 400 || $status == 401)) {
      push @{ $entry->{successfull_internal_links} }, $link;
    }
    else {
      push @{ $entry->{broken_internal_links} }, $link;
    }
  }

  # TODO: external links
  # TODO: anchors
  # TODO: anchor refs

  return $entry;
}

1;
__END__
