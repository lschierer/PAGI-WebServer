package WebFramework::Module::Navigation;
use v5.42.0;
use utf8::all;
use Mooish::Base -standard;
with 'WebFramework::Role::Logger';
extends 'Thunderhorse::Module';

has navigation_routes => (
  is      => 'ro',
  default => sub { {} },
);

has navigation_tree => (
  is      => 'rw',
  default => sub { {} },
);

has navigation_logger => (
  is      => 'lazy',
  default => sub { Log::Handler->create_logger(__PACKAGE__) },
);

sub build ($self) {
  $self->add_method(
    controller => add_navigation_route =>
      sub ($controller, $path, $title, $options = {}) {
      $self->_add_navigation_route($path, $title, $options);
      return $controller;
      }
  );

  $self->add_method(
    controller => render_navigation => sub ($controller, $current_path = '/') {
      return $self->_render_navigation($current_path);
    }
  );

  $self->add_method(
    controller => generate_sitemap => sub ($controller, $base_url = '') {
      return $self->_generate_sitemap($base_url);
    }
  );
}

# Register a route for navigation
# When a route is registered multiple times, the entry with the lower order
# value wins. This ensures that controllers with specific knowledge (e.g.,
# Family controller registering "/Harrypedia/people/Potter" with order 20)
# take precedence over generic auto-discovery (e.g., Root controller
# registering the same path from a markdown file with order 50).
sub _add_navigation_route ($self, $path, $title, $options = {}) {
  my $new_order = $options->{order} // 999;

  if (exists $self->navigation_routes->{$path}) {
    my $existing_order = $self->navigation_routes->{$path}{order} // 999;
    if ($existing_order <= $new_order) {
      $self->navigation_logger->debug(
        "Skipping navigation route: $path => $title (order $new_order) "
        . "-- existing entry has order $existing_order"
      );
      return $self;
    }
    $self->navigation_logger->debug(
      "Overriding navigation route: $path => $title (order $new_order "
      . "beats existing order $existing_order)"
    );
  }
  else {
    $self->navigation_logger->debug("Adding navigation route: $path => $title");
  }

  $self->navigation_routes->{$path} = {
    path  => $path,
    title => $title,
    order => $new_order,
    %$options,
  };

  return $self;
}

# Build the navigation tree from registered routes
sub build_navigation_tree ($self) {
  my $tree = {};

  # Process each route and insert into tree
  for my $path (sort keys %{ $self->navigation_routes }) {
    next if $path =~ /^\/policy/i;
    my $route_data = $self->navigation_routes->{$path};
    $self->_insert_into_navigation_tree($tree, $path, $route_data);
  }

  $self->navigation_tree($tree);
  return $tree;
}

# Insert a route into the tree structure
sub _insert_into_navigation_tree ($self, $tree, $path, $data) {
  # Remove leading/trailing slashes and split path
  $path =~ s|^/||;
  $path =~ s|/$||;

  my @segments = split('/', $path);
  my $current  = $tree;

  my $accumulated_path = '';
  for my $i (0 .. $#segments) {
    my $segment = $segments[$i];
    $accumulated_path .= '/' . $segment;

    if ($i == $#segments) {
      # Leaf node - this is the actual route
      if (exists $current->{$segment}) {
        # Node already exists (probably as a parent), update its properties
        $current->{$segment}{title} = $data->{title} if $data->{title};
        $current->{$segment}{order} = $data->{order} if defined $data->{order};
        # Keep is_leaf as 0 if it has children, otherwise set to 1
        $current->{$segment}{is_leaf} =
          (keys %{ $current->{$segment}{children} } == 0) ? 1 : 0;
      }
      else {
        # New leaf node
        $current->{$segment} = {
          path     => $accumulated_path,
          title    => $data->{title},
          order    => $data->{order},
          is_leaf  => 1,
          children => {},
        };
      }
    }
    else {
      # Directory/parent node
      $current->{$segment} //= {
        path     => $accumulated_path,
        title    => $self->_navigation_path_segment_to_title($segment),
        order    => 999,    # Default high order, will be updated by index.md
        is_leaf  => 0,
        children => {},
      };
      $current = $current->{$segment}{children};
    }
  }
}

# Convert path segment to title (e.g., "fan-fiction" => "Fan Fiction")
sub _navigation_path_segment_to_title ($self, $segment) {
  # Capitalize each word, replace hyphens/underscores with spaces
  my $title = $segment;
  $title =~ s/[-_]/ /g;
  $title =~ s/\b(\w)/\U$1/g;

  return $title;
}

# Render the navigation tree as HTML
sub _render_navigation ($self, $current_path = '/') {
  # Ensure tree is built
  $self->build_navigation_tree() unless keys %{ $self->navigation_tree };

  # Normalize current path
  $current_path =~ s|^/||;
  $current_path =~ s|/$||;

  my $html =
'<ul class="spectrum-TreeView spectrum-TreeView--quiet spectrum-TreeView--sizeM" role="tree">';
  $html .=
    $self->_render_navigation_tree_level($self->navigation_tree, $current_path,
    '', 0);
  $html .= '</ul>';

  return $html;
}

# Render a level of the tree
sub _render_navigation_tree_level ($self, $nodes, $current_path, $parent_path,
  $depth) {
  my $html = '';

  # Sort nodes by order, then by title
  my @sorted_keys = sort {
         ($nodes->{$a}{order} // 999) <=> ($nodes->{$b}{order} // 999)
      || ($nodes->{$a}{title} cmp $nodes->{$b}{title})
  } keys %$nodes;

  for my $index (0 .. $#sorted_keys) {
    my $key       = $sorted_keys[$index];
    my $node      = $nodes->{$key};
    my $node_path = $node->{path};
    $node_path =~ s|^/||;

    my $is_current  = ($node_path eq $current_path);
    my $is_ancestor = $current_path =~ m|^\Q$node_path\E/|;
    my $is_sibling  = $self->_navigation_is_sibling($node_path, $current_path);
    my $is_child =
      $self->_navigation_is_immediate_child($node_path, $current_path);
    my $is_top_level = ($depth == 0);

    # Determine if this node should be expanded (showing children)
    my $should_expand = $is_current || $is_ancestor || $is_top_level;

    # Determine if this node itself should be visible
    my $parent_is_ancestor = 0;
    if ($parent_path) {
      my $parent_path_normalized = $parent_path;
      $parent_path_normalized =~ s|^/||;
      $parent_is_ancestor = $current_path =~ m|^\Q$parent_path_normalized\E/|;
    }
    my $should_be_visible =
         $is_top_level
      || $is_ancestor
      || $is_current
      || $is_sibling
      || $is_child
      || $parent_is_ancestor;

    my $has_children = keys %{ $node->{children} } > 0;

    # Build class list
    my @classes = ('spectrum-TreeView-item');
    push @classes, 'is-selected' if $is_current;
    push @classes, 'is-open'     if $should_expand && $has_children;
    push @classes, 'nav-hidden' unless $should_be_visible;  # CSS will hide this

    my $class_str = join(' ', @classes);

    $html .= qq|  <li id="item${index}" class="$class_str" role="treeitem"|;
    $html .= qq| aria-expanded="true"|  if $should_expand  && $has_children;
    $html .= qq| aria-expanded="false"| if !$should_expand && $has_children;
    $html .= qq|>\n|;

    # Link
    my $link_class = 'spectrum-TreeView-itemLink';
    $html .=
      qq|    <span class="$link_class spectrum-Link spectrum-Link--quiet">\n|;

    my $itemIcon;
    # Icon for expandable items
    if ($has_children) {
      # Spectrum-CSS rotates the icon 90 degrees when open,
      # so use the same icon for both
      my $icon = 'ion:chevron-forward';
      $html .=
qq|    <iconify-icon icon="$icon" class="spectrum-TreeView-itemIndicator spectrum-Icon spectrum-Icon--medium" role="img" ></iconify-icon>\n|;
      $itemIcon = "ion:folder-open-outline";
    }
    else {
      $itemIcon = "ion:document-text-outline";
    }

    $html .= qq|      <span class="spectrum-TreeView-itemLabel">
          <iconify-icon focusable="false" aria-hidden="true" role="img" class="spectrum-Icon spectrum-Icon--sizeM spectrum-TreeView-itemIcon" icon="${itemIcon}" ></iconify-icon>
          <a href="$node->{path}" class="spectrum-Link spectrum-Link--secondary spectrum-Link--quiet">$node->{title}</a>
         </span>\n|;
    $html .= qq|    </span>\n|;

    # ALWAYS render children,
    # but they'll be hidden by CSS if parent is not expanded
    if ($has_children) {
      my @child_classes =
        ('spectrum-TreeView spectrum-TreeView--quiet spectrum-TreeView--sizeM');
      push @child_classes, 'nav-collapsed'
        unless $should_expand;    # CSS will hide this
      my $child_class_str = join(' ', @child_classes);

      $html .= qq|    <ul class="$child_class_str" role="group">\n|;
      $html .=
        $self->_render_navigation_tree_level($node->{children}, $current_path,
        $node_path, $depth + 1);
      $html .= qq|    </ul>\n|;
    }

    $html .= qq|  </li>\n|;
  }

  return $html;
}

# Check if two paths are siblings
sub _navigation_is_sibling ($self, $path1, $path2) {
  return 0 if $path1 eq $path2;

  my @parts1 = split('/', $path1);
  my @parts2 = split('/', $path2);

  # Same depth and same parent
  return 0 if @parts1 != @parts2;
  return 0 if @parts1 < 2;

  # Check if all parts except last are the same
  for my $i (0 .. $#parts1 - 1) {
    return 0 if $parts1[$i] ne $parts2[$i];
  }

  return 1;
}

# Check if path1 is an immediate child of path2
sub _navigation_is_immediate_child ($self, $path1, $path2) {
  return 0 if $path1 eq $path2;

  my @parts1 = split('/', $path1);
  my @parts2 = split('/', $path2);

  # Must be exactly one level deeper
  return 0 if @parts1 != @parts2 + 1;

  # Check if all parent parts match
  for my $i (0 .. $#parts2) {
    return 0 if $parts1[$i] ne $parts2[$i];
  }

  return 1;
}

sub _generate_sitemap ($self, $base_url = '') {
  use URI::Escape qw(uri_escape uri_unescape);


  # Remove trailing slash from base_url
  $base_url =~ s|/$||;

  # Build the tree to ensure all intermediate paths are included
  $self->build_navigation_tree() unless keys %{ $self->navigation_tree };

  my @urls;

  # Collect all paths from the tree recursively
  my $collect_paths;
  $collect_paths = sub {
    my ($node, $path) = @_;

    for my $segment (sort keys %$node) {
      my $current_path = $path . '/' . $segment;
      my $data         = $node->{$segment};

      # Skip if marked as no_sitemap
      next if $data->{no_sitemap};

      # Add this path if it has a title (meaning it's a real route)
      if ($data->{title}) {
        my $full_url = $base_url . $current_path;
        push @urls,
          sprintf("  <url>\n    <loc>%s</loc>\n  </url>",
          uri_escape($full_url));
      }

      # Recurse into children
      if ($data->{children} && keys %{ $data->{children} }) {
        $collect_paths->($data->{children}, $current_path);
      }
    }
  };

  $collect_paths->($self->navigation_tree, '');

  my $xml = qq{<?xml version="1.0" encoding="UTF-8"?>\n};
  $xml .= qq{<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">\n};
  $xml .= join("\n", @urls) . "\n";
  $xml .= qq{</urlset>};

  return $xml;
}

1;

__END__

=head1 NAME

WebFramework::Role::Navigation - Navigation role for Thunderhorse controllers

=head1 SYNOPSIS

    package MyApp::Controller::Main;
    use Moo;
    extends 'Thunderhorse::Controller';
    with 'WebFramework::Role::Navigation';

    sub some_action ($self, $ctx) {
        # Register routes
        $self->add_navigation_route('/home', 'Home', { order => 1 });
        $self->add_navigation_route('/about', 'About', { order => 2 });

        # Render navigation
        my $nav_html = $self->render_navigation($ctx->path);

        return $self->render('page.tt', { navigation => $nav_html });
    }

=head1 DESCRIPTION

Provides hierarchical navigation functionality for Thunderhorse controllers.
Builds and renders navigation trees using Spectrum CSS TreeView components.

=head1 METHODS

=head2 add_navigation_route($path, $title, $options)

Register a route for navigation. Options include 'order' for sorting.

=head2 render_navigation($current_path)

Render the navigation tree as HTML with intelligent expansion.

=head2 build_navigation_tree()

Build the tree structure from registered routes.

=head2 generate_sitemap()

Generate an XML sitemap from registered navigation routes.

=cut
