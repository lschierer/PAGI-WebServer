package WebFramework::Role::Navigation;
# cspell: disable
use v5.42.0;
use utf8::all;
use Mooish::Base -role;

our $_navigation_routes = {};

sub navigation_routes ($self) {
  return $_navigation_routes;
}

our $_navigation_tree = {};

sub navigation_tree ($self) {
  return $_navigation_tree;
}

has navigation_logger => (
  is      => 'lazy',
  default => sub { Log::Handler->create_logger(__PACKAGE__) },
);

sub add_navigation_route ($controller, $path, $title, $options = {}) {
  $controller->_add_navigation_route($path, $title, $options);
  return $controller;
}

sub render_navigation ($controller, $current_path = '/') {
  return $controller->_render_navigation($current_path);
}

sub generate_sitemap ($controller, $base_url = '') {
  return $controller->_generate_sitemap($base_url);
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
          . "-- existing entry has order $existing_order");
      return $self;
    }
    $self->navigation_logger->debug(
          "Overriding navigation route: $path => $title (order $new_order "
        . "beats existing order $existing_order)");
  }
  else {
    $self->navigation_logger->debug("Adding navigation route: $path => $title");
  }

  $self->navigation_routes->{$path} = {
    path       => $path,
    title      => $title,
    order      => $new_order,
    no_sitemap => $options->{no_sitemap} // 0,
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

  %$_navigation_tree = %$tree;
  return $_navigation_tree;
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
        $current->{$segment}{no_sitemap} = $data->{no_sitemap}
          if defined $data->{no_sitemap};
        # Keep is_leaf as 0 if it has children, otherwise set to 1
        $current->{$segment}{is_leaf} =
          (keys %{ $current->{$segment}{children} } == 0) ? 1 : 0;
      }
      else {
        # New leaf node
        $current->{$segment} = {
          path       => $accumulated_path,
          title      => $data->{title},
          order      => $data->{order},
          no_sitemap => $data->{no_sitemap} // 0,
          is_leaf    => 1,
          children   => {},
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

# Escape text for interpolation into an HTML attribute.
#
# Added because the chevron button's aria-label interpolates a node title into an
# attribute, where an unescaped quote would end the attribute early and corrupt the
# markup. NOTE the element text and href elsewhere in _render_navigation_tree_level are
# still interpolated raw; that is a pre-existing gap, not one this helper closes.
sub _navigation_escape_html ($self, $text) {
  return '' unless defined $text;
  $text =~ s/&/&amp;/g;
  $text =~ s/</&lt;/g;
  $text =~ s/>/&gt;/g;
  $text =~ s/"/&quot;/g;
  $text =~ s/'/&#39;/g;
  return $text;
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
  # Ensure tree is built (only builds once since it checks for existing keys)
  $self->build_navigation_tree() unless keys %{ $self->navigation_tree };

  # Normalize current path
  $current_path =~ s|^/||;
  $current_path =~ s|/$||;

  my $html =
      '<ul class="spectrum-TreeView spectrum-TreeView--quiet'
    . ' spectrum-TreeView--sizeM" role="tree">';
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
    my $should_expand = $is_current || $is_ancestor;

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

    # The id used to be "item$index", but $index is a per-sibling-list counter and this
    # renderer recurses, so every level restarted at item0 - one live page carried 1090
    # duplicate ids. Deriving it from the node's path makes it unique and stable across
    # renders. Nothing currently reads these ids; they exist so that aria and deep links
    # have something to point at.
    my $item_id = 'nav-' . ($node_path =~ s{[^A-Za-z0-9_-]+}{-}gr);
    $item_id =~ s/-+$//;

    $html .= qq|  <li id="$item_id" class="$class_str" role="treeitem"|;
    $html .= qq| aria-expanded="true"|  if $should_expand  && $has_children;
    $html .= qq| aria-expanded="false"| if !$should_expand && $has_children;
    $html .= qq|>\n|;

    # Link
    my $link_class = 'spectrum-TreeView-itemLink';
    $html .=
      qq|    <span class="$link_class spectrum-Link spectrum-Link--quiet">\n|;

    my $itemIcon;
    if ($has_children) {
      # A BUTTON, not an <iconify-icon role="img">. The icon carried the click handler but
      # was not focusable and had no button semantics, so expanding was mouse-only and
      # every collapsed branch - display:none, hence absent from the accessibility tree -
      # was unreachable by keyboard. That is a WCAG 2.1.1 (Keyboard, level A) failure, and
      # Spectrum's own tree-view guidance calls for a collapse-and-expand button.
      #
      # aria-expanded is deliberately on both this button and the <li role="treeitem">:
      # the li needs it to satisfy the tree role, the button needs it to describe what it
      # does. lib/navigation.ts keeps the two in step.
      my $expanded = $should_expand ? 'true' : 'false';
      my $label    = $self->_navigation_escape_html($node->{title});

      # Spectrum-CSS rotates the indicator 90 degrees when open, so one icon serves both
      # states. aria-hidden because the button's own label already names the action.
      $html .=
          qq|<button type="button" class="spectrum-TreeView-itemIndicator"|
        . qq| aria-expanded="$expanded" aria-label="Toggle $label">|
        . qq|<iconify-icon icon="ion:chevron-forward" aria-hidden="true"|
        . qq| class="spectrum-Icon"></iconify-icon></button>|;

      $itemIcon = "ion:folder-open-outline";
    }
    else {
      # Childless items had no indicator at all, so their label sat 10px to the left of a
      # sibling folder's - the ragged edge visible whenever folders and files interleave
      # in one sorted list. This reserves the same box without drawing anything.
      $html .=
        qq|<span class="spectrum-TreeView-itemIndicator |
        . qq|spectrum-TreeView-itemIndicator--empty" aria-hidden="true"></span>|;

      $itemIcon = "ion:document-text-outline";
    }

    # aria-current is the only machine-readable signal of which page is open. The
    # is-selected class drives the visual treatment, but a class means nothing to a
    # screen reader, so without this the current page was indicated to sighted users
    # only.
    my $aria_current = $is_current ? ' aria-current="page"' : '';

    $html .= qq|      <span class="spectrum-TreeView-itemLabel">
          <iconify-icon focusable="false" aria-hidden="true" role="img" class="spectrum-Icon spectrum-Icon--sizeM spectrum-TreeView-itemIcon" icon="${itemIcon}" ></iconify-icon>
          <a href="$node->{path}"$aria_current title="@{[ $self->_navigation_escape_html($node->{title}) ]}" class="spectrum-Link spectrum-Link--secondary spectrum-Link--quiet">$node->{title}</a>
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
  use URI;
  use Scalar::Util 'weaken';

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
        my $uri = URI->new($base_url . $current_path);
        my $url = $uri->as_string;
        # XML-escape the URL
        $url =~ s/&/&amp;/g;
        push @urls, sprintf("  <url>\n    <loc>%s</loc>\n  </url>", $url);
      }

      # Recurse into children
      if ($data->{children} && keys %{ $data->{children} }) {
        $collect_paths->($data->{children}, $current_path);
      }
    }
  };
  $self->logger->debug(
    sprintf('in _generate_sitemap navigation_tree is %s',
      Data::Printer::np($self->navigation_tree))
  );
  $collect_paths->($self->navigation_tree, '');

  # Break the circular reference: closure references $collect_paths which
  # references the closure
  undef $collect_paths;

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
