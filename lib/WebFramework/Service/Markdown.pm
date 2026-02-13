package WebFramework::Service::Markdown;
# cspell: disable
use v5.42.0;
use utf8::all;
use Mooish::Base -standard;
with 'WebFramework::Role::Logger';
use Text::Markdown::Discount;
use Path::Tiny;
use YAML::XS qw(Load);
use Encode   qw(encode_utf8);
require Mojo::DOM58;

sub md ($self, $markdown_text) {
    return "" unless defined $markdown_text;

    # Preprocess: Convert angle bracket links (reference and inline)
    # [label]: </path with spaces> -> [label]: /path%20with%20spaces
    # [text](</path with spaces>) -> [text](/path%20with%20spaces)
    $markdown_text =~ s{<(/[^>]+)>}{
        my $path = $1;
        $path =~ s/ /%20/g;
        $path
    }ge;

    # Preprocess: Add zero-width space on line before each alert to break blockquote continuation
    $markdown_text =~ s/^(> \[!(?:NOTE|TIP|IMPORTANT|WARNING|CAUTION)\])/\x{200B}\n$1/gm;

    # Combine flags for GFM-like behavior + Footnotes
    my $flags = Text::Markdown::Discount::MKD_EXTRA_FOOTNOTE 
              | Text::Markdown::Discount::MKD_TOC
              | Text::Markdown::Discount::MKD_DLEXTRA
              | Text::Markdown::Discount::MKD_AUTOLINK 
              | Text::Markdown::Discount::MKD_IDANCHOR 
              | Text::Markdown::Discount::MKD_GITHUBTAGS 
              | Text::Markdown::Discount::MKD_URLENCODEDANCHOR;

    my $html = Text::Markdown::Discount::markdown($markdown_text, $flags);

    # strip out the extra paragraphs we inserted to break up the sections. 
    $html =~ s{<p>\s*\x{200B}\s*</p>}{}g;

    # Fix for GFM Alerts - convert blockquotes with alert syntax to divs
    $html =~ s{<blockquote>\s*<p>\[!(NOTE|TIP|IMPORTANT|WARNING|CAUTION)\](.*?)</p>(.*?)</blockquote>}
              {<div class="spectrum-AlertBanner is-open  spectrum-AlertBanner--\L$1\E"><p class="spectrum-Alert-Banner-body">$2</p>$3</div>}gis;

    return $html;
}

sub build ($self) {
    Text::Markdown::Discount::with_html5_tags();
}


sub parse_frontmatter {
  my ($self, $content) = @_;

  # Check for YAML frontmatter (--- at start, --- after frontmatter)
  if ($content =~ /^---\n(.*?)\n---\n(.*)$/s) {
    my ($yaml_str, $markdown) = ($1, $2);

    my $frontmatter;
    eval {
      $frontmatter = Load(encode_utf8($yaml_str));
      $self->logger->debug(
        "Parsed frontmatter: " . (ref $frontmatter ? "hash" : "scalar"));
    };

    if ($@) {
      $self->logger->warn("Failed to parse YAML frontmatter: $@");
      return ({}, $content);
    }

    return ($frontmatter, $markdown);
  }

  # No frontmatter found
  return ({}, $content);
}

sub markdown_string_to_html ($self, $md_content) {
  my $html = $self->md($md_content);

  return $self->spectrum_formatting($html);
}

sub render {
  my ($self, $markdown_file, $template) = @_;

  $self->logger->debug("Rendering markdown file: $markdown_file");

  my $content = path($markdown_file)->slurp_utf8;

  my $html = $self->md($content);

  return $self->spectrum_formatting($html);
}

sub render_with_frontmatter {
  my ($self, $markdown_file) = @_;

  $self->logger->debug(
    "Rendering markdown file with frontmatter: $markdown_file");

  my $content = path($markdown_file)->slurp_utf8;
  my ($frontmatter, $markdown) = $self->parse_frontmatter($content);

  my $html = $self->md(
    $markdown
  );

  return ($frontmatter, $self->spectrum_formatting($html));
}

sub spectrum_formatting ($c, $html_content) {
  my $dom = Mojo::DOM58->new($html_content);

  my %spectrum_h = (
    h1 => "spectrum-Heading spectrum-Heading--sizeXXL",
    h2 => "spectrum-Heading spectrum-Heading--sizeXL",
    h3 => "spectrum-Heading spectrum-Heading--sizeL",
    h4 => "spectrum-Heading spectrum-Heading--sizeM",
    h5 => "spectrum-Heading spectrum-Heading--sizeS",
    h6 => "spectrum-Heading spectrum-Heading--sizeXS",
  );

  # Add header classes
  for my $tag (keys %spectrum_h) {
    $dom->find($tag)->each(sub { $_->attr(class => $spectrum_h{$tag}) });
  }

  # Add paragraph classes
  $dom->find('p')->each(sub {
    # Skip if already has spectrum classes (e.g., from alert formatting)
    my $existing_class = $_->attr('class') // '';
    return if $existing_class =~ /^spectrum/;
    
    $_->attr(
      class => "spectrum-Body spectrum-Body--serif spectrum-Body--sizeM");
  });

  # Add list item classes
  $dom->find('li')->each(sub {
    $_->attr(
      class => "spectrum-Body spectrum-Body--serif spectrum-Body--sizeM");
  });

  # Add link classes
  $dom->find('a')->each(sub {
    $_->attr(
      class => "spectrum-Link spectrum-Link--primary spectrum-Link--quiet");
  });

  # Add emphasis class
  $dom->find('em')->each(sub {
    $_->attr(class => "spectrum-Body-emphasized");
  });

  # Add strong class
  $dom->find('strong')->each(sub {
    $_->attr(class => "spectrum-Body-strong");
  });

  $dom->find('hr')->each(sub {
    $_->attr(class => 'spectrum-Divider spectrum-Divider--sizeM');
  });

  # Add table classes
  $dom->find('table')->each(sub {
    $_->attr(class => 'spectrum-Table spectrum-Table--sizeM');
  });

  $dom->find('thead')->each(sub {
    $_->attr(class => 'spectrum-Table-head');
  });

  $dom->find('tbody')->each(sub {
    $_->attr(class => 'spectrum-Table-body');
  });

  $dom->find('th')->each(sub {
    $_->attr(class => 'spectrum-Table-headCell');
  });

  $dom->find('td')->each(sub {
    $_->attr(class => 'spectrum-Table-cell');
  });

  $dom->find('tr')->each(sub {
    $_->attr(class => 'spectrum-Table-row');
  });

  return $dom->to_string;
}
1;
