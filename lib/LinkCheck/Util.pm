package LinkCheck::Util;
use v5.42;
use utf8::all;

use Exporter 'import';
our @EXPORT_OK =
  qw(normalize_url normalize_url_string canon_uri canon_url_string);

use Scalar::Util qw(blessed);
use URI;

sub normalize_url ($u) {
  return undef unless defined $u && length $u;

  my $uri = blessed($u) && $u->isa('URI') ? $u->clone : URI->new($u);

  # Lowercase host
  $uri->host(lc $uri->host) if $uri->host;

  # Normalize default ports
  if ( ($uri->scheme eq 'http' && ($uri->port // 80) == 80)
    || ($uri->scheme eq 'https' && ($uri->port // 443) == 443)) {
    $uri->port(undef);
  }

  my $path = $uri->path;
  $path = '/' if !defined($path) || $path eq '';
  $path =~ s{//+}{/}g;
  $path =~ s{/$}{} if $path ne '/';
  $uri->path($path);

  return $uri;
}

sub canon_uri ($u) {
  return undef unless defined $u && length $u;

  my $uri = normalize_url($u) or return undef;

  return undef unless ($uri->scheme // '') =~ /^https?$/;

  # Crawl policy
  $uri->fragment(undef);
  $uri->query(undef);

  return $uri;
}

sub canon_url_string ($uri) {
  return canon_uri($uri)->as_string;
}

sub normalize_url_string ($uri) {
  return normalize_url($uri)->as_string;
}

1;
__END__
