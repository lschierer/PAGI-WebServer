package WebFramework::Role::Markdown;
# cspell: disable
use v5.42.0;
use utf8::all;
use Mooish::Base -role;
require Path::Tiny;
require YAML::XS;

use Gears::X::Thunderhorse;
use Gears::Template::TT;
use Carp;
require WebFramework::Service::Markdown;

has markdown => (
  hidden  => 1,
  is      => 'ro',
  default => sub {
    my $self = shift;
    my $md   = WebFramework::Service::Markdown->new(log_dir => $self->log_dir);
    return $md;
  },
);

has _template_instance => (
  is      => 'lazy',
  builder => '_build_template',
);

has pages_dir => (
  is      => 'ro',
  default => sub {
    my $self         = shift;
    my $markdown_dir = 'share/pages';

    if (my $markdown_dir = $self->app_config->{config}->{markdown_dir}) {
      $markdown_dir = $markdown_dir;
    }

    use FindBin;
    return Path::Tiny::path($FindBin::Bin)->parent->child($markdown_dir);
  },
);

sub _build_template ($self) {
  # Get the template configuration from the nested config structure
  my $config = {};
  if ($self->can('config')) {
    if (my $app_config = $self->config) {
      if (my $template_config = $app_config->{config}->{modules}->{Template}) {
        $config = $template_config;
      }
    }
  }
  elsif ($self->can('app') && defined($self->app) && blessed($self->app)) {
    if (my $app_config = $self->app->config) {
      if (my $template_config = $app_config->{config}->{modules}->{Template}) {
        $config = $template_config;
      }
    }
  }

  # Set default include path if not configured
  $config->{paths} //= ['templates',];
  $self->logger->debug('markdown template include path: ',
    join(', ', @{ $config->{paths} }));

  # Debug: log the template configuration
  use Data::Printer;
  $self->logger->debug(
    "Template config in _build_template: " . Data::Printer::np($config));

  require Gears::Template::TT;
  return Gears::Template::TT->new($config->%*);
}

sub parse_frontmatter_from_string ($self, $string) {
  my ($yaml_text) = $string =~ /^---\s*\n(.*?)\n---/s;

  return {} unless $yaml_text;

  # Parse just the YAML frontmatter
  # YAML::XS expects UTF-8 byte strings and will decode them internally
  my $frontmatter = eval { YAML::XS::Load($yaml_text) };
  return $frontmatter || {};
}

sub parse_markdown_frontmatter ($self, $md_file_path) {
  my $md_file = Path::Tiny::path($md_file_path);

  return unless $md_file->exists;

  # Fast frontmatter extraction - only read the YAML header
  # Use slurp_raw since YAML::XS expects byte strings
  my $content = $md_file->slurp_raw;
  return $self->parse_frontmatter_from_string($content);
}

sub render_markdown_page ($self, $md_file_path, $url_path, $extra_vars = {}) {
  my $md_file = Path::Tiny::path($md_file_path);

  unless ($md_file->exists) {
    $self->logger->warn(
      "render_markdown_page called for non-existant file '$md_file_path'");
    return;
  }

  my ($frontmatter, $content_html) =
    $self->markdown->render_with_frontmatter($md_file->stringify);

  #$self->logger->debug(sprintf('content html is %s', $content_html));

  # Use title from frontmatter or generate from path
  my $title = $frontmatter->{title};
  if (!$title) {
    my $path_for_title = $url_path;
    $path_for_title =~ s|^/||;
    $title = $path_for_title;
    $title =~ s|/| - |g;
    $title =~ s/[-_]/ /g;
    $title =~ s/\b(\w)/\U$1/g;
  }

  my $current_year = (localtime)[5] + 1900;
  my $sidebar      = $frontmatter->{layout} // 1;
  $sidebar = 0 if ($sidebar =~ /splash/);

  # Build template vars
  my $vars = {
    content      => $content_html,
    title        => $title,
    current_year => $current_year,
    css_files    => ['/css/navigation.css'],
    %$extra_vars,    # Allow caller to override/extend
  };

  if (exists $frontmatter->{autoindex} && !!$frontmatter->{autoindex}) {
    my $autoindex = $self->generate_directory_index($md_file);

    push @{ $vars->{css_files} }, '/css/directory-list.css';
    $vars->{entries} = $autoindex;
  }

  # Template selection priority:
  # 1. Frontmatter template field
  # 2. Controller override via $extra_vars->{template_override}
  # 3. Default 'markdown'
  my $template = 'markdown';

  if (exists $frontmatter->{collection} && !!$frontmatter->{collection}) {
    if (exists $frontmatter->{template} && !!$frontmatter->{template}) {
      $template =
        sprintf('%s/%s', $frontmatter->{collection}, $frontmatter->{template});
    }
  }
  elsif (exists $extra_vars->{template_override}
    && $extra_vars->{template_override}) {
    $template = $extra_vars->{template_override};
  }
  elsif (exists $frontmatter->{template} && !!$frontmatter->{template}) {
    $template = $frontmatter->{template};
  }

  my $tpl = $self->_template_instance;
  my $rh  = $tpl->process($template, $vars,);
  #$self->logger->debug('returnable html: ' . $rh);
  return $rh;
}

sub markdown_string_to_html ($self, $md_content) {

  return unless length($md_content);

  my $content_html = $self->markdown->markdown_string_to_html($md_content);

  return $content_html;
}

sub retrieve_rendered_markdown ($self, $md_file_path) {
  my $md_file = Path::Tiny::path($md_file_path);

  return unless $md_file->exists;

  my ($frontmatter, $content_html) =
    $self->markdown->render_with_frontmatter($md_file->stringify);

  return $content_html;
}

sub find_markdown_file ($self, $url_path) {
  my $path = $url_path;
  $path =~ s|^/||;    # Remove leading slash

  # Try exact path first
  my $md_file = $self->pages_dir->child("$path.md");

  # If not found, try as directory with index.md
  if (!$md_file->exists) {
    $md_file = $self->pages_dir->child($path, 'index.md');
  }

  return $md_file->exists ? $md_file : undef;
}

1;
__END__
