package WebFramework::Middleware::Markdown;

use v5.42.0;
use utf8::all;
use Mooish::Base -standard;
with 'WebFramework::Role::Logger';
with 'WebFramework::Role::Markdown';
extends 'PAGI::Middleware';

use Path::Tiny;
use Future;

has app_config => (
  is       => 'ro',
  required => 1,
);

has path => (
  is       => 'ro',
  required => 1,
);

has pass_through => (
  is      => 'ro',
  default => 1,
);

sub wrap ($self, $app) {
  return sub {
    my ($env) = @_;

    # Check if this is a real HTTP request
    unless ($env->{REQUEST_METHOD}) {
      $self->logger->warn(
        "Middleware called without REQUEST_METHOD - skipping");
      return $app->($env);
    }

    my $request_path = $env->{PATH_INFO}    || '/';
    my $request_uri  = $env->{REQUEST_URI}  || 'no REQUEST_URI';
    my $query_string = $env->{QUERY_STRING} || 'no QUERY_STRING';
    my $method       = $env->{REQUEST_METHOD};

    $self->logger->warn(
"Middleware: METHOD=$method, PATH_INFO='$request_path', REQUEST_URI='$request_uri', QUERY='$query_string'"
    );

    # Convert request path to potential markdown file path
    my $md_file = $self->_path_to_markdown_file($request_path);

    if ($md_file && $md_file->exists) {
      $self->logger->warn("Found markdown file: $md_file - serving it");
      return $self->_serve_markdown($md_file, $env);
    }

    # Pass through if no markdown file found
    if ($self->pass_through) {
      $self->logger->warn("No markdown file found, passing through to app");
      return $app->($env);
    }

    # Return 404 if not passing through
    return Future->done([404, ['Content-Type' => 'text/plain'], ['Not Found']]);
  };
}

sub _path_to_markdown_file ($self, $request_path) {
  my $base_dir = Path::Tiny::path($self->path);

  # Remove leading slash and add .md extension
  $request_path =~ s|^/||;
  $request_path = 'index' if $request_path eq '';

  my $md_path = $base_dir->child("$request_path.md");

  # Also try index.md in subdirectories
  if (!$md_path->exists && $request_path ne 'index') {
    $md_path = $base_dir->child($request_path, 'index.md');
  }

  return $md_path->exists ? $md_path : undef;
}

sub _serve_markdown ($self, $md_file, $env) {
  my $request_path = $env->{PATH_INFO} || '/';
  my $content      = $md_file->slurp_utf8;

  # Return a proper PSGI response
  my $response = [
    200, ['Content-Type' => 'text/html; charset=utf-8'],
    ["<pre>$content</pre>"]
  ];

  return Future->done($response);
}

1;
