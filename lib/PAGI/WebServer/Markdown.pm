package PAGI::WebServer::Markdown;

use strict;
use warnings;
use Moo;
use Pandoc;
use Path::Tiny;
use Log::Log4perl qw(get_logger);

has pandoc => (is => 'lazy',);

has modules => (
  is      => 'ro',
  default => sub { [] }
);

sub _build_pandoc {
  my $self   = shift;
  my $pandoc = Pandoc->new;

  # Configure pandoc with specified modules
  for my $module (@{ $self->modules }) {
    $pandoc->add_filter($module);
  }

  return $pandoc;
}

sub render {
  my ($self, $markdown_file, $template) = @_;

  my $logger = get_logger(__PACKAGE__);
  $logger->debug("Rendering markdown file: $markdown_file");

  my $content = path($markdown_file)->slurp_utf8;

  my $html = $self->pandoc->convert(
    'markdown' => 'html',
    $content
  );

  return $html;
}

1;
