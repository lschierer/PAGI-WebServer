package WebFramework::Service::Markdown;
use v5.42.0;
use utf8::all;
use Mooish::Base -standard;
with 'WebFramework::Role::Logger';
use Pandoc;
use Path::Tiny;
use YAML::XS qw(Load);
use Encode   qw(encode_utf8);
require Mojo::DOM58;

has pd => (
  is => 'lazy',
  default => sub {
    my $self = shift;
    my $pd   = Pandoc->new;

    return $pd;
  }
);

has md_profile => (
  is      => 'ro',
  default => sub {
    return join('+',
      qw(commonmark alerts attributes autolink_bare_uris footnotes implicit_header_references pipe_tables raw_html rebase_relative_paths smart gfm_auto_identifiers)
    );
  },
);

sub build ($self) {
  $self->pd($self->_build_pd);

}

sub _build_pd {

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
  my $html = $self->pd->convert(
    $self->md_profile => 'html',
    $md_content
  );

  return $self->spectrum_formatting($html);
}

sub render {
  my ($self, $markdown_file, $template) = @_;

  $self->logger->debug("Rendering markdown file: $markdown_file");

  my $content = path($markdown_file)->slurp_utf8;

  my $html = $self->pd->convert(
    $self->md_profile => 'html',
    $content
  );

  return $self->spectrum_formatting($html);
}

sub render_with_frontmatter {
  my ($self, $markdown_file) = @_;

  $self->logger->debug(
    "Rendering markdown file with frontmatter: $markdown_file");

  my $content = path($markdown_file)->slurp_utf8;
  my ($frontmatter, $markdown) = $self->parse_frontmatter($content);

  my $html = $self->pd->convert(
    $self->md_profile => 'html',
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
