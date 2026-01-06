package WebFramework::Service::Markdown;
use v5.42.0;
use utf8::all;
use Mooish::Base -standard;
use Pandoc;
use Path::Tiny;
use Log::Log4perl qw(get_logger);
use YAML::XS qw(Load);

has pd => (is => 'lazy',);

has modules => (
  is      => 'ro',
  default => sub { [] }
);

sub build ($self) {
  $self->pd($self->_build_pd);

}

sub _build_pd {
  my $self = shift;
  my $pd   = Pandoc->new;

  # Configure pd with specified modules
  for my $module (@{ $self->modules }) {
    $pd->add_filter($module);
  }

  return $pd;
}

sub parse_frontmatter {
  my ($self, $content) = @_;

  my $logger = get_logger(__PACKAGE__);

  # Check for YAML frontmatter (--- at start, --- after frontmatter)
  if ($content =~ /^---\n(.*?)\n---\n(.*)$/s) {
    my ($yaml_str, $markdown) = ($1, $2);

    my $frontmatter;
    eval {
      $frontmatter = Load($yaml_str);
      $logger->debug("Parsed frontmatter: " . (ref $frontmatter ? "hash" : "scalar"));
    };

    if ($@) {
      $logger->warn("Failed to parse YAML frontmatter: $@");
      return ({}, $content);
    }

    return ($frontmatter, $markdown);
  }

  # No frontmatter found
  return ({}, $content);
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

sub render_with_frontmatter {
  my ($self, $markdown_file) = @_;

  my $logger = get_logger(__PACKAGE__);
  $logger->debug("Rendering markdown file with frontmatter: $markdown_file");

  my $content = path($markdown_file)->slurp_utf8;
  my ($frontmatter, $markdown) = $self->parse_frontmatter($content);

  my $html = $self->pd->convert(
    'markdown' => 'html',
    $markdown
  );

  return ($frontmatter, $html);
}

1;
