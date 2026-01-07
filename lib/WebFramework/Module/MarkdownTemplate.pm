package WebFramework::Module::MarkdownTemplate;
use v5.42.0;
use utf8::all;
use Mooish::Base -standard;
with 'WebFramework::Role::Logger';
use Mooish::Base -standard;

use Gears::X::Thunderhorse;
use Gears::Template::TT;

extends 'Thunderhorse::Module';

use Path::Tiny;
use Encode qw(encode_utf8);
use Carp;
require WebFramework::Service::Markdown;

has field 'markdown' => (
    lazy => 1,
);

has field 'pages_dir' => (
    lazy => 1,
);

sub _build_markdown ($self) {
    return WebFramework::Service::Markdown->new;
}

sub _build_pages_dir ($self) {
    # Default to share/pages relative to project root
    use FindBin;
    return path($FindBin::Bin)->parent->child('share/pages');
}

has field 'template' => (
	isa => InstanceOf ['Gears::Template'],
	lazy => 1,
);

sub _build_template ($self) {
    # Get the template configuration from the nested config structure
    my $config = {};
    if (my $app_config = $self->config) {
        if (my $template_config = $app_config->{config}->{template}) {
            $config = $template_config;
        }
    }

    # Set default include path if not configured
    $config->{INCLUDE_PATH} //= ['templates', 'templates/partials'];

    # Debug: log the template configuration
    use Data::Printer;
    $self->logger->debug("Template config in _build_template: " . Data::Printer::np($config));

    require Gears::Template::TT;
    return Gears::Template::TT->new($config->%*);
}

sub build ($self) {
    # Get template configuration from app config and pass it to parent
    my $template_config = {};
    if (my $config = $self->config) {
        if (my $tpl_conf = $config->{template}) {
            $template_config = $tpl_conf;
        }
    }

    # Set default include path if not configured
    $template_config->{INCLUDE_PATH} //= ['templates', 'templates/partials'];

    # Store the config for the parent template builder
    $self->{_template_config} = $template_config;

    weaken $self;
    my $tpl = $self->template;
    my $markdown = $self->markdown;
    my $pages_dir = $self->pages_dir;

    # Register render_markdown_page for full page rendering
    $self->register(
        controller => render_markdown_page => sub ($controller, $md_file_path, $url_path, $extra_vars = {}) {
            my $md_file = ref($md_file_path) ? $md_file_path : path($md_file_path);

            return unless $md_file->exists;

            my ($frontmatter, $content_html) =
                $markdown->render_with_frontmatter($md_file->stringify);

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

            # Build template vars
            my $vars = {
                content      => $content_html,
                title        => $title,
                current_year => $current_year,
                css_files    => ['/css/navigation.css'],
                sidebar      => 1,
                %$extra_vars,  # Allow caller to override/extend
            };

            return $tpl->process('page/markdown.tt', $vars, { layout => 'layouts/default.tt' });
        }
    );

    # Register render_markdown_snippet for content-only rendering
    $self->register(
        controller => render_markdown_snippet => sub ($controller, $md_file_path) {
            my $md_file = ref($md_file_path) ? $md_file_path : path($md_file_path);

            return unless $md_file->exists;

            my ($frontmatter, $content_html) =
                $markdown->render_with_frontmatter($md_file->stringify);

            return $content_html;
        }
    );

    # Register find_markdown_file helper
    $self->register(
        controller => find_markdown_file => sub ($controller, $url_path) {
            my $path = $url_path;
            $path =~ s|^/||;  # Remove leading slash

            # Try exact path first
            my $md_file = $pages_dir->child("$path.md");

            # If not found, try as directory with index.md
            if (!$md_file->exists) {
                $md_file = $pages_dir->child($path, 'index.md');
            }

            return $md_file->exists ? $md_file : undef;
        }
    );
}

1;

__END__

=head1 NAME

WebFramework::Module::MarkdownTemplate - Thunderhorse module for markdown rendering

=head1 SYNOPSIS

    # In your Thunderhorse app
    $self->load_module('MarkdownTemplate');

    # In a controller
    my $html = $self->render_markdown_page('/path/to/file.md', '/url/path', {
        navigation => $nav_html,
        extra_var  => $value,
    });

    # Just the content without layout
    my $content = $self->render_markdown_snippet('/path/to/file.md');

    # Find a markdown file by URL path
    my $md_file = $self->find_markdown_file('/some/page');

=head1 DESCRIPTION

Extends Thunderhorse::Module::Template to add markdown rendering capabilities.
Provides methods for full page rendering with templates and snippet rendering
for content-only output.

=head1 REGISTERED METHODS

=head2 render_markdown_page($md_file_path, $url_path, $extra_vars)

Renders a markdown file as a complete HTML page with layout and navigation.

=head2 render_markdown_snippet($md_file_path)

Renders just the markdown content to HTML without any layout.

=head2 find_markdown_file($url_path)

Finds a markdown file based on URL path, trying both exact match and index.md.

=cut
