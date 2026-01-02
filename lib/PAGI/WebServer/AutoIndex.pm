package PAGI::WebServer::AutoIndex;
use v5.42.0;
use utf8::all;
use Moo;
use Path::Tiny;
use Log::Log4perl qw(get_logger);

has pages_dir => (
  is       => 'ro',
  required => 1,
);

has markdown => (
  is       => 'ro',
  required => 1,
);

sub generate_directory_index {
  my ($self, $path) = @_;

  my $logger = get_logger(__PACKAGE__);
  $logger->debug("Generating directory index for: $path");

  $path = path($path) unless ref $path eq 'Path::Tiny';
  $path = $path->parent if $path->basename eq 'index.md';

  my @entries;

  foreach my $child ($path->children) {
    next if $child->basename eq 'index.md';
    $logger->debug("Inspecting: $child");

    if ($child->is_dir) {
      $logger->debug("$child is a directory");

      my $name = $child->basename;
      $name =~ s/_/ /g;
      $name = join(' ', map { ucfirst lc } split ' ', $name);

      my $route = $child->relative($self->pages_dir);
      $route = "/$route";

      push @entries, {
        title => $name,
        path  => $route,
        type  => 'directory'
      };
    }
    elsif ($child->basename =~ /\.md$/) {
      $logger->debug("$child is a markdown file");

      # Parse frontmatter for title
      my $content = $child->slurp_utf8;
      my ($frontmatter, $markdown_content) = $self->markdown->parse_frontmatter($content);

      my $title = $frontmatter->{title} || $self->titleize($child->basename =~ s/\.md$//r);
      my $basename = $child->basename =~ s/\.md$//r;

      my $route = $child->parent->relative($self->pages_dir);
      $route = "/$route/$basename";
      $route =~ s|//|/|g;  # Clean up double slashes

      push @entries, {
        title => $title,
        path  => $route,
        type  => 'file',
        order => $frontmatter->{sidebar}{order} // 999,
      };
    }
    else {
      $logger->warn("File with odd extension: $child");
    }
  }

  # Sort entries by order if present, then by title
  @entries = sort {
    ($a->{order} // 999) <=> ($b->{order} // 999)
    || $a->{title} cmp $b->{title}
  } @entries;

  $logger->debug("Generated " . scalar(@entries) . " entries");
  return \@entries;
}

sub titleize {
  my ($self, $text) = @_;
  $text =~ s/_/ /g;
  return join ' ', map { ucfirst lc } split ' ', $text;
}

1;
