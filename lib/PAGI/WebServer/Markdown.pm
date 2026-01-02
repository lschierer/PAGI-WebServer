package PAGI::WebServer::Markdown;
use v5.42.0;
use utf8::all;
use Moo;
use Pandoc;
use Path::Tiny;
use Log::Log4perl qw(get_logger);

has pd => (is => 'lazy',);

has modules => (
  is      => 'ro',
  default => sub { [] }
);

sub _build_pd {
  my $self = shift;
  my $pd   = Pandoc->new;

  # Configure pd with specified modules
  for my $module (@{ $self->modules }) {
    $pd->add_filter($module);
  }

  return $pd;
}

sub render {
  my ($self, $markdown_file, $template) = @_;

  my $logger = get_logger(__PACKAGE__);
  $logger->debug("Rendering markdown file: $markdown_file");

  my $content = path($markdown_file)->slurp_utf8;

  my $html = $self->pd->convert(
    'markdown' => 'html',
    $content
  );

  return $html;
}

1;
