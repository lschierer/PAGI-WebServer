package PAGI::WebServer::MarkdownHandler;

use v5.42.0;
use Moo;
with 'PAGI::WebServer::Role::MarkdownPages';
use Future::AsyncAwait;
use Path::Tiny;
use Encode qw(encode_utf8);
use Log::Log4perl qw(get_logger);

has logger => (
  is      => 'ro',
  default => sub { get_logger(__PACKAGE__) },
);

has template => (
  is       => 'ro',
  required => 1,
);

has navigation => (
  is       => 'ro',
  required => 1,
);

has site_logo => (
  is      => 'ro',
  default => '',
);

async sub register_routes ($self, $nav, $router) {
  my $logger = $self->logger;
  
  # Register navigation routes by scanning markdown files
  await $self->register_markdown_routes($nav);
  
  # Register catch-all markdown route
  $router->get('*' => async sub {
    my ($scope, $receive, $send) = @_;
    await $self->handle_markdown_route($scope, $receive, $send);
  });
  
  $logger->debug("Registered markdown handler routes");
}

async sub register_markdown_routes ($self, $nav) {
  my $pages_dir = $self->pages_dir;
  
  my $iter = $pages_dir->iterator({ recurse => 1 });
  
  while (my $file = $iter->()) {
    next unless $file->is_file && $file->basename =~ /\.md$/;
    
    # Convert file path to route path
    my $rel_path = $file->relative($pages_dir);
    my $route = "/$rel_path";
    $route =~ s/\.md$//;
    $route =~ s|/index$||;  # Remove /index for index files
    
    # Parse frontmatter to get title and order
    my $content = $file->slurp_utf8;
    my ($frontmatter, $markdown_content) =
      $self->markdown->parse_frontmatter($content);
    
    # Use title from frontmatter, or generate from filename
    my $title = $frontmatter->{title};
    if (!$title) {
      $title = $file->basename;
      $title =~ s/\.md$//;
      $title =~ s/[-_]/ /g;
      $title =~ s/\b(\w)/\U$1/g;  # Capitalize words
    }
    
    # Get order from frontmatter (sidebar.order) - only if explicitly set
    my $options = {};
    if (defined $frontmatter->{sidebar}{order}) {
      $options->{order} = $frontmatter->{sidebar}{order};
    }
    
    # Add route to navigation
    $nav->add_route($route, $title, $options);
  }
}

async sub handle_markdown_route ($self, $scope, $receive, $send) {
  my $path = $scope->{path};
  $path =~ s|^/||;  # Remove leading slash
  
  # Try exact path first
  my $md_file = $self->pages_dir->child("$path.md");
  
  # If not found, try as directory with index.md
  if (!$md_file->exists) {
    $md_file = $self->pages_dir->child($path, 'index.md');
  }
  
  if ($md_file->exists) {
    my $navigation_html = $self->navigation->render($scope->{path});
    
    my $html = $self->render_markdown_page($md_file, $scope->{path}, {
      navigation => $navigation_html,
      site_logo  => $self->site_logo,
    });
    
    if ($html) {
      my $bytes = encode_utf8($html);
      
      await $send->({
        type    => 'http.response.start',
        status  => 200,
        headers => [['content-type', 'text/html; charset=utf-8']],
      });
      await $send->({
        type => 'http.response.body',
        body => $bytes,
        more => 0,
      });
      return;
    }
  }
  
  # Not found
  await $send->({
    type    => 'http.response.start',
    status  => 404,
    headers => [['content-type', 'text/plain']],
  });
  await $send->({
    type => 'http.response.body',
    body => 'Not Found',
    more => 0,
  });
}

1;

__END__

=head1 NAME

PAGI::WebServer::MarkdownHandler - Handler for serving markdown pages

=head1 SYNOPSIS

    use PAGI::WebServer::MarkdownHandler;
    
    my $handler = PAGI::WebServer::MarkdownHandler->new(
      template   => $template,
      navigation => $nav,
      site_logo  => $site_logo,
      pages_dir  => path('share/pages'),
    );
    
    await $handler->register_routes($nav, $router);

=head1 DESCRIPTION

Provides a handler that automatically registers routes for all markdown
files in a directory tree and serves them with navigation and templates.

=cut
