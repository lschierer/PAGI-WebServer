package LinkCheck::Role::Parser;
use v5.42;
use utf8::all;

use Mooish::Base -role;
with 'LinkCheck::Role::Logger';

use LinkCheck::Util qw(normalize_url_string);

use Mojo::DOM58;
use URI;
use Scalar::Util   qw(blessed);
use HTML::Entities qw(decode_entities);

# NOTE: parse_task is a Step task sub, not a method.
# It must instantiate something that has parse_one + logger.
require LinkCheck::Worker;

sub parse_task ($mce, $chunk_ref, $chunk_id) {
  state $worker_obj = LinkCheck::Worker->new();

  my @results;
  for my $item (@$chunk_ref) {
    push @results, $worker_obj->parse_one($item);
  }

  MCE->gather(\@results);
}

sub parse_one ($self, $item) {
  # Carry through fetch metadata
  my $url          = $item->{url};
  my $content_type = $item->{content_type} // '';
  my $body         = $item->{body};

  my $out = {
    url          => $url,
    ok           => $item->{ok}          // 0,
    http_status  => $item->{http_status} // 0,
    error        => $item->{error},
    content_type => $content_type,

    discovered_internal => [],
    discovered_external => [],
    anchors             => [],
    anchor_refs         => [],
  };

  # If fetch already failed, parsing yields nothing new
  return $out unless $out->{ok};

  # Non-HTML => nothing to parse
  if ($content_type && $content_type !~ m{text/html}i) {
    delete $out->{body};
    return $out;
  }

  unless (defined($body) && length($body)) {
    $out->{error} = ($out->{error} // '') . ' (missing body)';
    return $out;
  }

  my $page_uri  = URI->new($url);
  my $base_host = lc($page_uri->host // '');

  $self->logger->debug(sprintf('parsing page "%s"', $page_uri));

  my (@internal, @external, @anchor_refs, @anchors);

  my $dom;
  eval { $dom = Mojo::DOM58->new($body); 1 } or $dom = undef;

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

    my @attrs = (
      ['a[href], area[href]'                             => 'href'],
      ['img[src], iframe[src], script[src], source[src]' => 'src'],
      ['link[href]'                                      => 'href'],
      ['object[data]'                                    => 'data'],
      ['svg a[href], svg a[xlink\:href]'                 => 'href'],
      ['svg use[href], svg use[xlink\:href]'             => 'href'],
      ['svg image[href], svg image[xlink\:href]'         => 'href'],
    );

    for my $spec (@attrs) {
      my ($sel, $attr) = @$spec;
      for my $e ($dom->find($sel)->each) {
        my $raw = $e->{$attr};
        next unless defined $raw && length $raw;
        _classify_and_record($self, $url, $raw, $base_host, \@internal,
          \@external, \@anchor_refs);
      }

      # explicitly handle xlink:href attr when present
      for my $e ($dom->find($sel)->each) {
        my $raw = $e->{'xlink:href'};
        next unless defined $raw && length $raw;
        _classify_and_record($self, $url, $raw, $base_host, \@internal,
          \@external, \@anchor_refs);
      }
    }
  }

  # Regex fallback — decode HTML entities so that e.g. &#39; doesn't get
  # misinterpreted as a URI fragment separator by URI->new.
  for my $raw (_scan_html_for_urls($body)) {
    _classify_and_record($self, $url, decode_entities($raw), $base_host,
      \@internal, \@external, \@anchor_refs);
  }

  # Dedupe
  my %seen_i;
  @internal = grep { defined && length && !$seen_i{$_}++ } @internal;
  my %seen_e;
  @external = grep { defined && length && !$seen_e{$_}++ } @external;

  my %seen_a;
  @anchors = grep { defined && length && !$seen_a{$_}++ } @anchors;

  my %seen_ar;
  @anchor_refs = grep {
    my $k = ($_->{url} // '') . ($_->{anchor} // '');
    $k && !$seen_ar{$k}++;
  } @anchor_refs;

  $out->{discovered_internal} = \@internal;
  $out->{discovered_external} = \@external;
  $out->{anchors}             = \@anchors;
  $out->{anchor_refs}         = \@anchor_refs;

  return $out;
}

sub _scan_html_for_urls ($html) {
  my @out;
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

sub _classify_and_record ($self, $page_url, $raw, $base_host, $internal_ref,
  $external_ref, $anchor_refs_ref) {
  return if $raw =~ m{^(?:mailto:|tel:|javascript:|data:)}i;

  # Pure same-page fragment
  if ($raw =~ /^#(.+)/) {
    my $a = $1;
    $a =~ s/^#//;
    push @$anchor_refs_ref, { url => $page_url, anchor => "#$a" };
    return;
  }

  my $abs;
  eval { $abs = URI->new_abs($raw, $page_url); 1 } or return;

  my $frag = $abs->fragment;
  $abs->fragment(undef);

  my $canon = normalize_url_string($abs);

  my $host = lc($abs->host // '');

  if (defined $frag && length $frag && $host eq $base_host) {
    my $frag_norm = $frag;
    $frag_norm =~ s/^#//;
    push @$anchor_refs_ref, { url => $canon, anchor => "#$frag_norm" };
  }

  if ($host eq $base_host) {
    push @$internal_ref, $canon;
  }
  else {
    push @$external_ref, $canon;
  }
}

1;
__END__
