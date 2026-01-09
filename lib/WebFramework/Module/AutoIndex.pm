package WebFramework::Module::AutoIndex;
use v5.42.0;
use Mooish::Base -standard;
with 'WebFramework::Role::Logger';
use experimental 'signatures';
require Log::Handler;

use Path::Tiny;

extends 'Thunderhorse::Module';

has pages_dir => (
  is  => 'rw',
  lazy => 1,
);

has  markdown => (
  lazy => 1,
  is  => 'rw',
);

sub _build_pages_dir ($self) {
  # Default to share/pages relative to project root
  use FindBin;
  return path($FindBin::Bin)->parent->child('share/pages');
}

sub _build_markdown ($self) {
  # Get markdown service from the app's loaded modules
  # This assumes MarkdownTemplate module is also loaded
  require WebFramework::Service::Markdown;
  return WebFramework::Service::Markdown->new;
}

sub build ($self) {
  weaken $self;
  my $pages_dir = $self->pages_dir;
  my $markdown  = $self->markdown;

  # Register generate_directory_index method
  $self->register(
    controller => generate_directory_index => sub ($controller, $path) {
      $self->logger->debug("Generating directory index for: $path");

      $path = path($path) unless ref $path eq 'Path::Tiny';
      $path = $path->parent if $path->basename eq 'index.md';

      my @entries;

      foreach my $child ($path->children) {
        next if $child->basename eq 'index.md';
        $self->logger->debug("Inspecting: $child");

        if ($child->is_dir) {
          $self->logger->debug("$child is a directory");

          my $name = $child->basename;
          $name =~ s/_/ /g;
          $name = join(' ', map { ucfirst lc } split ' ', $name);

          my $route = $child->relative($pages_dir);
          $route = "/$route";

          push @entries,
            {
            title => $name,
            path  => $route,
            type  => 'directory'
            };
        }
        elsif ($child->basename =~ /\.md$/) {
          $self->logger->debug("$child is a markdown file");

          # Parse frontmatter for title
          my $content = $child->slurp_utf8;
          my ($frontmatter, $markdown_content) =
            $markdown->parse_frontmatter($content);

          my $title = $frontmatter->{title}
            || $self->_titleize($child->basename =~ s/\.md$//r);
          my $basename = $child->basename =~ s/\.md$//r;

          my $route = $child->parent->relative($pages_dir);
          $route = "/$route/$basename";
          $route =~ s|//|/|g;    # Clean up double slashes

          push @entries,
            {
            title => $title,
            path  => $route,
            type  => 'file',
            order => $frontmatter->{sidebar}{order} // 999,
            };
        }
        else {
          $self->logger->warn("File with odd extension: $child");
        }
      }

      # Sort entries by order if present, then by title
      @entries = sort {
        ($a->{order} // 999) <=> ($b->{order} // 999)
          || $a->{title} cmp $b->{title}
      } @entries;

      $self->logger->debug("Generated " . scalar(@entries) . " entries");
      return \@entries;
    }
  );
}

sub _titleize ($self, $text) {
  $text =~ s/_/ /g;
  return join ' ', map { ucfirst lc } split ' ', $text;
}

1;

__END__

=head1 NAME

WebFramework::Module::AutoIndex - Thunderhorse module for directory indexing

=head1 SYNOPSIS

    # In your Thunderhorse app
    $self->load_module('AutoIndex');

    # In a controller
    my $entries = $self->generate_directory_index($directory_path);

    return $self->render('directory.tt', { entries => $entries });

=head1 DESCRIPTION

Extends Thunderhorse to add automatic directory indexing functionality.
Scans directories for markdown files and subdirectories, extracting titles
from frontmatter and generating sorted entry lists.

=head1 REGISTERED METHODS

=head2 generate_directory_index($path)

Generates a directory index for the given path. Returns an arrayref of entries,
each containing:

- title: Display title (from frontmatter or filename)
- path: URL path to the item
- type: 'file' or 'directory'
- order: Sort order (from frontmatter, defaults to 999)

Entries are sorted by order, then by title.

=cut
