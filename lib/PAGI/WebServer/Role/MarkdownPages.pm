package PAGI::WebServer::Role::MarkdownPages;

use v5.42.0;
use Moo::Role;
use Path::Tiny;
use PAGI::WebServer::Markdown;
use Encode qw(encode_utf8);

requires 'template';

has markdown => (
  is      => 'lazy',
  default => sub { PAGI::WebServer::Markdown->new },
);

has pages_dir => (
  is      => 'ro',
  default => sub { 
    use FindBin;
    path($FindBin::Bin)->parent->child('share/pages');
  },
);

sub render_markdown_page {
  my ($self, $md_file, $path, $extra_vars) = @_;
  $extra_vars //= {};
  
  return unless $md_file->exists;

  my ($frontmatter, $content_html) =
    $self->markdown->render_with_frontmatter($md_file->stringify);

  # Use title from frontmatter or generate from path
  my $title = $frontmatter->{title};
  if (!$title) {
    my $md_path = $path;
    $md_path =~ s|^/||;
    $title = $md_path;
    $title =~ s|/| - |g;
    $title =~ s/[-_]/ /g;
    $title =~ s/\b(\w)/\U$1/g;
  }

  my $current_year = (localtime)[5] + 1900;

  # Build default vars
  my $vars = {
    content      => $content_html,
    title        => $title,
    current_year => $current_year,
    css_files    => ['/css/navigation.css'],
    sidebar      => 1,
    %$extra_vars,  # Allow caller to override/extend
  };

  my $html = $self->template->render('page/markdown.tt', $vars,
    { layout => 'layouts/default.tt' });

  return $html;
}

1;

__END__

=head1 NAME

PAGI::WebServer::Role::MarkdownPages - Role for rendering markdown pages

=head1 SYNOPSIS

    package MyHandler;
    use Moo;
    with 'PAGI::WebServer::Role::MarkdownPages';
    
    has template => (...);
    
    sub some_method {
      my $self = shift;
      my $md_file = $self->pages_dir->child('some/page.md');
      my $html = $self->render_markdown_page($md_file, '/some/page', {
        navigation => $nav_html,
        site_logo => $logo,
      });
    }

=head1 DESCRIPTION

Provides core markdown rendering functionality with frontmatter support,
template rendering, and navigation integration.

=head1 METHODS

=head2 render_markdown_page($md_file, $path, $extra_vars)

Renders a markdown file to HTML. Returns undef if file doesn't exist.

Parameters:
- $md_file: Path::Tiny object pointing to the markdown file
- $path: URL path (used for title generation if no frontmatter)
- $extra_vars: Optional hashref of additional template variables

=cut
