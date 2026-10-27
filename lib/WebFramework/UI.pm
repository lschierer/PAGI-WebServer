package WebFramework::UI;
# cspell: disable
use v5.42.0;
use utf8::all;
use Carp qw(croak);

# The class vocabulary the framework's HTML generators emit, selected per site.
#
# WHY THIS EXISTS. WebFramework::Service::Markdown and WebFramework::Role::Navigation stamp
# design-system classes onto the HTML they produce. Every site that extends the framework
# shares that code, and the sites are not all on the same design system: Game-EvonyTKR and
# originalFiction still use @spectrum-css (".spectrum-Body", "--primary", "-strong"),
# while App-Schierer-HPFan is moving to Spectrum Web Components gen2 (".swc-Body"). Gen2 is
# not a rename. Its links have no --primary and only go quiet together with --standalone, its
# strong/emphasized sub-classes are gone in favour of <strong>/<em>, and its divider is a
# custom element rather than a class on <hr>. So a prefix switch cannot express the
# difference, and unconditionally emitting gen2 would break the other two sites.
#
# HOW A SITE SELECTS. `ui_profile: swc` in its config. Anything else, or nothing, is
# 'spectrum-css', which reproduces the strings the framework has always emitted
# byte-for-byte. The default is the old behaviour on purpose: a site opts IN.
#
# WHAT THE SITE MUST PROVIDE. Under `swc` the framework emits `site-table` on tables,
# <site-callout> for GitHub-style alerts, and the `site-tree-*` list markup for the
# navigation tree. Those are the SITE's, not gen2's (gen2 has neither
# a table nor an inline callout), so a site that selects `swc` has to ship the stylesheet for
# the table and register the <site-callout> element. App-Schierer-HPFan does
# (styles/swc/table.css, lib/components/site-callout.ts). When a second site adopts the
# profile, move both here so they are written once.
#
# STILL NOT HERE. Icon classes outside the tree are emitted as @spectrum-css classes by
# their generators in either profile until they are migrated.

my %PROFILES = (
  'spectrum-css' => {
    # Prefix of the CSS custom properties used in inline style="" (blockquote).
    token_prefix => 'spectrum',

    heading => {
      h1 => 'spectrum-Heading spectrum-Heading--sizeXXL',
      h2 => 'spectrum-Heading spectrum-Heading--sizeXL',
      h3 => 'spectrum-Heading spectrum-Heading--sizeL',
      h4 => 'spectrum-Heading spectrum-Heading--sizeM',
      h5 => 'spectrum-Heading spectrum-Heading--sizeS',
      h6 => 'spectrum-Heading spectrum-Heading--sizeXS',
    },
    paragraph  => 'spectrum-Body spectrum-Body--serif spectrum-Body--sizeM',
    list_item  => 'spectrum-Body spectrum-Body--serif spectrum-Body--sizeM',
    blockquote => 'spectrum-Body spectrum-Body--sizeM',
    link       => 'spectrum-Link spectrum-Link--primary spectrum-Link--quiet',

    # An undefined entry means "emit nothing", which is what gen2 wants for these.
    emphasis        => 'spectrum-Body-emphasized',
    strong          => 'spectrum-Body-strong',
    strong_emphasis => 'spectrum-Body-strong spectrum-Body-emphasized',

    # A divider is either a class on the <hr> or a replacement element.
    divider => { class => 'spectrum-Divider spectrum-Divider--sizeM' },

    # Which tree renderer Role::Navigation uses: the @spectrum-css TreeView markup (role=tree,
    # inline SVG icons), or `site` (below).
    tree_markup => 'spectrum-css',

    # The navigation tree's row wrapper and its label link.
    tree_row_link => 'spectrum-Link spectrum-Link--quiet',
    tree_link => 'spectrum-Link spectrum-Link--secondary spectrum-Link--quiet',

    # Table: a class per element. An undefined entry means "no class".
    table           => 'spectrum-Table spectrum-Table--sizeM',
    table_head      => 'spectrum-Table-head',
    table_body      => 'spectrum-Table-body',
    table_head_cell => 'spectrum-Table-headCell',
    table_cell      => 'spectrum-Table-cell',
    table_row       => 'spectrum-Table-row',

    # GitHub-style alert (`> [!NOTE]`). `open` is a sprintf format taking the lower-case
    # kind; note the doubled space after is-open, kept so the output is byte-identical.
    callout => {
      open       => '<div class="spectrum-AlertBanner is-open  spectrum-AlertBanner--%s">',
      close      => '</div>',
      body_class => 'spectrum-Alert-Banner-body',
    },
  },

  swc => {
    token_prefix => 'swc',

    heading => {
      h1 => 'swc-Heading swc-Heading--sizeXXL',
      h2 => 'swc-Heading swc-Heading--sizeXL',
      h3 => 'swc-Heading swc-Heading--sizeL',
      h4 => 'swc-Heading swc-Heading--sizeM',
      h5 => 'swc-Heading swc-Heading--sizeS',
      h6 => 'swc-Heading swc-Heading--sizeXS',
    },
    paragraph  => 'swc-Body swc-Body--serif swc-Body--sizeM',
    list_item  => 'swc-Body swc-Body--serif swc-Body--sizeM',
    blockquote => 'swc-Body swc-Body--sizeM',

    # An ordinary underlined link. Links in running text must not rely on colour alone
    # (WCAG 1.4.1), and no colour can be both readable on this background and 3:1 away from
    # the text beside it, so they carry an underline. Gen2's quiet variant (no underline
    # until hover) is for stand-alone links only: navigation, headings, footers. There is no
    # --primary; the default IS primary. Anchors in generated SVG are skipped by the caller.
    link => 'swc-Link',

    # Gen2 has no Body-strong / Body-emphasized: native <strong>/<em> carry the meaning.
    emphasis        => undef,
    strong          => undef,
    strong_emphasis => undef,

    divider => { element => 'swc-divider', attributes => { size => 'm' } },

    # `site`: a disclosure-navigation tree built from plain nested lists. No role=tree
    # (that promises arrow-key navigation this does not implement), no per-node SVG (the icons
    # are drawn once, in CSS), `hidden` instead of hidden-state classes. The classes are
    # styled by the site's styles/swc/tree.css and driven by its <site-tree> element.
    tree_markup => 'site',

    # No classes at all on the tree's links or their row wrapper: the tree stylesheet colours
    # them. That is a link class repeated on every one of 1,300 nodes, on every page.
    tree_row_link => undef,
    tree_link     => undef,

    # One class on the <table>; the site's stylesheet styles th/td/tr beneath it.
    table           => 'site-table',
    table_head      => undef,
    table_body      => undef,
    table_head_cell => undef,
    table_cell      => undef,
    table_row       => undef,

    callout => {
      open       => '<site-callout variant="%s" role="note">',
      close      => '</site-callout>',
      body_class => 'site-callout-body',
    },
  },
);

# The profile for a configured name; undef means the default.
sub profile ($class, $name = undef) {
  $name = 'spectrum-css' unless defined $name && length $name;
  croak(sprintf(
    'unknown ui_profile "%s" (expected one of: %s)',
    $name, join(', ', sort keys %PROFILES)
  )) unless exists $PROFILES{$name};
  return $PROFILES{$name};
}

1;
__END__

=head1 NAME

WebFramework::UI - per-site class vocabulary for framework-generated HTML

=head1 SYNOPSIS

    my $ui = WebFramework::UI->profile($config->{ui_profile});
    $dom->find('p')->each(sub { $_->attr(class => $ui->{paragraph}) });

=head1 DESCRIPTION

Selects between the C<spectrum-css> class vocabulary (the default) and the Spectrum Web
Components gen2 one (C<swc>). See the comments at the top of the module for why this is
a profile and not a prefix.

=cut
