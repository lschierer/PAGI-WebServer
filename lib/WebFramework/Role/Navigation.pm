package WebFramework::Role::Navigation;
# cspell: disable
use v5.42.0;
use utf8::all;
use Mooish::Base -role;

require Path::Tiny;
require WebFramework::UI;

# The navigation tree used to live in THIS PACKAGE's globals ($_navigation_routes etc.), shared by
# every consumer only because a role's package subs are the same subs no matter which instance calls
# them -- an accident of how roles compose, not a real shared store. That accident also meant the
# only way to read the tree was to re-render the WHOLE thing inline into every page: nothing outside
# "ask any instance, they all hit the same globals" identified the data as the app's.
#
# Storage is now $self->config->config (Gears::Config's own live, shared hashref): one Gears::Config
# instance per app, handed to every controller via Gears::App::_build_controller's `app => $self`, so
# $self->config resolves to the identical object whether asked from a controller or from
# WebFramework::App itself (which also consumes this role, for /sitemap.xml). That is the same kind
# of shared, app-scoped store the framework already uses for configuration -- not a second, parallel
# sharing mechanism -- and it is what lets a dedicated endpoint (WebFramework::Controller::Base's
# POST /navigation) read the SAME tree a page's own render would, on demand, instead of only ever
# being able to embed it inline.
my $NAV_KEY = '_navigation';

sub _navigation_store ($self) {
  my $conf = $self->config->config;
  return $conf->{$NAV_KEY} //= { routes => {}, tree => {}, built_for_count => -1 };
}

# The three icons the tree needs, as raw <svg> markup (share/icons/*.svg, sibling to lib/), read
# ONCE per process and cached -- never a per-node file read. Inlined directly into each <li> instead
# of an <iconify-icon> custom element: that element was measured (a controlled headless-Chrome test,
# not a guess) at roughly 4x the real DOM node count and 33x the JS heap of the same number of plain
# elements, because each instance builds its own shadow DOM internally, REGARDLESS of whether it is
# ever visible -- and a typical page here renders a few hundred visible nodes against tens of
# thousands of permanently display:none ones (nav-hidden), so that per-instance cost was being paid
# tens of thousands of times over for nothing anyone ever saw. A real captured page's worth of
# <iconify-icon> tags measured at ~1GB of actual browser process memory for that reason alone. Raw
# inline SVG has no shadow DOM and no JS component instantiation at all: the earlier measurement's
# "plain span" control, but with the real icon shape drawn via markup instead of a custom element.
my %_ICON_CACHE;

sub _icon_svg ( $self, $name ) {
  return $_ICON_CACHE{$name} //= do {
    my $file = Path::Tiny::path(__FILE__)->absolute->parent(4)
      ->child("share/icons/$name.svg");    # lib/WebFramework/Role/Navigation.pm -> repo root
    my $svg = $file->is_file ? $file->slurp_utf8 : '';
    $svg =~ s/\A<\?xml[^>]*\?>\s*//;        # strip an XML prolog if the source file has one
    $svg =~ s/\s+\z//;
    $svg;
  };
}

sub navigation_routes ($self) {
  return $self->_navigation_store->{routes};
}

sub navigation_tree ($self) {
  return $self->_navigation_store->{tree};
}

has navigation_logger => (
  is      => 'lazy',
  default => sub { Log::Handler->create_logger(__PACKAGE__) },
);

# A module-level logger, shared with the `navigation_logger` attribute's default, for
# code paths that call the navigation API as a class method rather than on a live,
# already-built controller instance -- e.g. a non-controller object (RunStore) that
# learns of new routes (new clan pages) only after a long-running computation finishes,
# well outside any request/controller lifecycle, and has no live controller instance to
# call through. `->navigation_logger` is a Mooish attribute accessor: it reads/writes an
# instance slot, so calling it on a bare class name fails ("can't use string as a HASH
# reference") before ever reaching the logging call it guards. This free function has no
# such requirement.
my $_navigation_class_logger;

sub _navigation_logger_for ($controller_or_self) {
  return $controller_or_self->navigation_logger
    if ref $controller_or_self;
  return $_navigation_class_logger //= Log::Handler->create_logger(__PACKAGE__);
}

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
  my $log       = _navigation_logger_for($self);
  my $routes    = $self->navigation_routes;

  if (exists $routes->{$path}) {
    my $existing_order = $routes->{$path}{order} // 999;
    if ($existing_order <= $new_order) {
      $log->debug(
            "Skipping navigation route: $path => $title (order $new_order) "
          . "-- existing entry has order $existing_order");
      return $self;
    }
    $log->debug(
          "Overriding navigation route: $path => $title (order $new_order "
        . "beats existing order $existing_order)");
  }
  else {
    $log->debug("Adding navigation route: $path => $title");
  }

  $routes->{$path} = {
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
  my $tree  = {};
  my $store = $self->_navigation_store;

  # Process each route and insert into tree
  for my $path (sort keys %{ $self->navigation_routes }) {
    next if $path =~ /^\/policy/i;
    my $route_data = $self->navigation_routes->{$path};
    $self->_insert_into_navigation_tree($tree, $path, $route_data);
  }

  %{ $store->{tree} }      = %$tree;
  $store->{built_for_count} = scalar keys %{ $self->navigation_routes };
  return $store->{tree};
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
  my $store = $self->_navigation_store;

  # Rebuild whenever routes have been added since the tree was last built -- not just
  # the first time, since a controller may register routes (e.g. per-clan pages) once
  # their data becomes known well after the process starts and the first page renders.
  $self->build_navigation_tree()
    if scalar keys %{ $self->navigation_routes } != $store->{built_for_count};

  # Normalize current path
  $current_path =~ s|^/||;
  $current_path =~ s|/$||;

  my $ui = WebFramework::UI->profile($self->config->config->{ui_profile});
  if (($ui->{tree_markup} // '') eq 'site') {
    return '<ul class="site-tree-list">'
      . $self->_render_navigation_site_level($self->navigation_tree,
      $current_path, '', 0, $ui)
      . '</ul>';
  }

  my $html =
      '<ul class="spectrum-TreeView spectrum-TreeView--quiet'
    . ' spectrum-TreeView--sizeM" role="tree">';
  $html .=
    $self->_render_navigation_tree_level($self->navigation_tree, $current_path,
    '', 0);
  $html .= '</ul>';

  return $html;
}

# How one node is to be drawn: which flags decide whether it is expanded, shown, selected.
# Shared by both renderers (_render_navigation_tree_level for the @spectrum-css markup,
# _render_navigation_site_level for the `site` markup) so that they cannot disagree about
# what is open or visible. $node_path, $is_current etc. keep the names they had when this
# lived inline.
sub _navigation_node_state ($self, $node, $current_path, $parent_path, $depth) {
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

  # The id used to be "item$index", but $index is a per-sibling-list counter and this
  # renderer recurses, so every level restarted at item0 - one live page carried 1090
  # duplicate ids. Deriving it from the node's path makes it unique and stable across
  # renders. Nothing currently reads these ids; they exist so that aria and deep links
  # have something to point at.
  my $item_id = 'nav-' . ($node_path =~ s{[^A-Za-z0-9_-]+}{-}gr);
  $item_id =~ s/-+$//;

  return {
    node_path         => $node_path,
    is_current        => $is_current,
    should_expand     => $should_expand,
    should_be_visible => $should_be_visible,
    has_children      => scalar(keys %{ $node->{children} }) > 0,
    item_id           => $item_id,
  };
}

# Render a level of the tree
sub _render_navigation_tree_level ($self, $nodes, $current_path, $parent_path,
  $depth) {
  my $html = '';

  # Class vocabulary for the links below; 'spectrum-css' unless the site opts in. See
  # WebFramework::UI. Looked up per level, not per node.
  my $ui = WebFramework::UI->profile($self->config->config->{ui_profile});

  # Sort nodes by order, then by title
  my @sorted_keys = sort {
         ($nodes->{$a}{order} // 999) <=> ($nodes->{$b}{order} // 999)
      || ($nodes->{$a}{title} cmp $nodes->{$b}{title})
  } keys %$nodes;

  for my $index (0 .. $#sorted_keys) {
    my $key  = $sorted_keys[$index];
    my $node = $nodes->{$key};

    my $state =
      $self->_navigation_node_state($node, $current_path, $parent_path, $depth);
    my ($node_path, $is_current, $should_expand, $should_be_visible,
      $has_children)
      = @{$state}
      {qw(node_path is_current should_expand should_be_visible has_children)};

    # Build class list
    my @classes = ('spectrum-TreeView-item');
    push @classes, 'is-selected' if $is_current;
    push @classes, 'is-open'     if $should_expand && $has_children;
    push @classes, 'nav-hidden' unless $should_be_visible;  # CSS will hide this

    my $class_str = join(' ', @classes);

    my $item_id = $state->{item_id};

    $html .= qq|  <li id="$item_id" class="$class_str" role="treeitem"|;
    $html .= qq| aria-expanded="true"|  if $should_expand  && $has_children;
    $html .= qq| aria-expanded="false"| if !$should_expand && $has_children;
    $html .= qq|>\n|;

    # Link
    my $link_class = join(' ', grep { defined } 'spectrum-TreeView-itemLink',
      $ui->{tree_row_link});
    $html .= qq|    <span class="$link_class">\n|;

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
      # The chevron is inline SVG (see _icon_svg), not an <iconify-icon> custom element --
      # see this file's header comment for why: raw SVG carries no shadow DOM and
      # instantiates no JS component, where an <iconify-icon> paid that cost even for the
      # ~95% of nodes that stay display:none their whole life.
      $html .=
          qq|<button type="button" class="spectrum-TreeView-itemIndicator"|
        . qq| aria-expanded="$expanded" aria-label="Toggle $label">|
        . $self->_icon_svg('ion--chevron-forward')
        . qq|</button>|;

      $itemIcon = 'ion--folder-open-outline';
    }
    else {
      # Childless items had no indicator at all, so their label sat 10px to the left of a
      # sibling folder's - the ragged edge visible whenever folders and files interleave
      # in one sorted list. This reserves the same box without drawing anything.
      $html .=
        qq|<span class="spectrum-TreeView-itemIndicator |
        . qq|spectrum-TreeView-itemIndicator--empty" aria-hidden="true"></span>|;

      $itemIcon = 'ion--document-text-outline';
    }

    # aria-current is the only machine-readable signal of which page is open. The
    # is-selected class drives the visual treatment, but a class means nothing to a
    # screen reader, so without this the current page was indicated to sighted users
    # only.
    my $aria_current = $is_current ? ' aria-current="page"' : '';

    $html .= qq|      <span class="spectrum-TreeView-itemLabel">
          <span focusable="false" aria-hidden="true" role="img" class="spectrum-Icon spectrum-Icon--sizeM spectrum-TreeView-itemIcon">@{[ $self->_icon_svg($itemIcon) ]}</span>
          <a href="$node->{path}"$aria_current title="@{[ $self->_navigation_escape_html($node->{title}) ]}" class="$ui->{tree_link}">$node->{title}</a>
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

# Render a level of the tree as the `site` markup: nested lists, disclosure-navigation style.
#
# WHY NOT role=tree. The other renderer marks the list up as an ARIA tree. That role is a
# promise: arrow keys move between nodes, Left/Right collapse and expand, one node is in the
# tab order, and so on. Nothing here implemented any of it - every link and toggle is an
# ordinary tab stop - so assistive technology was told to expect behaviour that does not
# exist. A site's navigation is a list of links, for which the pattern is "disclosure
# navigation": nested lists, with a button per branch whose aria-expanded says whether its
# list is showing. That is exactly what this emits, and the buttons already worked that way.
#
# The visual tree is unchanged; only the semantics are now truthful.
#
# SIZE. This emits roughly a third of the other renderer's markup per node: the three icons
# are drawn by CSS (see styles/swc/tree.css) instead of being inlined as SVG into every node,
# there is no per-node link class, and hidden state is the `hidden` attribute.
sub _render_navigation_site_level ($self, $nodes, $current_path, $parent_path,
  $depth, $ui)
{
  my $html = '';

  my @sorted_keys = sort {
         ($nodes->{$a}{order} // 999) <=> ($nodes->{$b}{order} // 999)
      || ($nodes->{$a}{title} cmp $nodes->{$b}{title})
  } keys %$nodes;

  for my $key (@sorted_keys) {
    my $node = $nodes->{$key};
    my $state =
      $self->_navigation_node_state($node, $current_path, $parent_path, $depth);
    my ($node_path, $is_current, $should_expand, $should_be_visible,
      $has_children, $item_id)
      = @{$state}{
      qw(node_path is_current should_expand should_be_visible has_children item_id)
      };

    my $title = $self->_navigation_escape_html($node->{title});
    my $href  = $self->_navigation_escape_html($node->{path});

    $html .= qq|<li id="$item_id"|;
    $html .= ' hidden' unless $should_be_visible;
    $html .= qq|>\n|;

    $html .= $is_current
      ? qq|<div class="site-tree-row is-current">|
      : qq|<div class="site-tree-row">|;

    my $label_class;
    if ($has_children) {
      my $expanded = $should_expand ? 'true' : 'false';

      # A real <button>, so expanding is keyboard- and screen-reader-operable. The label
      # names the node it opens; aria-controls points at the list it shows and hides.
      $html .=
          qq|<button type="button" class="site-tree-toggle"|
        . qq| aria-expanded="$expanded" aria-controls="$item_id-children"|
        . qq| aria-label="Toggle $title"></button>|;
      $label_class = 'site-tree-label site-tree-folder';
    }
    else {
      # Reserves the toggle's width so a leaf's label lines up with a folder's at the same
      # depth. Purely presentational.
      $html .= q|<span class="site-tree-toggle site-tree-leaf" aria-hidden="true"></span>|;
      $label_class = 'site-tree-label site-tree-doc';
    }

    # aria-current is the machine-readable signal of which page is open; the is-current class
    # only drives the highlight.
    my $aria_current = $is_current ? ' aria-current="page"' : '';
    my $link_class =
      defined $ui->{tree_link} ? qq| class="$ui->{tree_link}"| : '';

    $html .= qq|<span class="$label_class"><a href="$href"$aria_current|
      . qq| title="$title"$link_class>$title</a></span></div>\n|;

    if ($has_children) {
      # Always rendered, hidden when its parent is collapsed, so expanding needs no request.
      $html .= qq|<ul id="$item_id-children" class="site-tree-list"|;
      $html .= ' hidden' unless $should_expand;
      $html .= qq|>\n|;
      $html .= $self->_render_navigation_site_level($node->{children},
        $current_path, $node_path, $depth + 1, $ui);
      $html .= qq|</ul>\n|;
    }

    $html .= qq|</li>\n|;
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
  my $store = $self->_navigation_store;
  $self->build_navigation_tree()
    if scalar keys %{ $self->navigation_routes } != $store->{built_for_count};

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
