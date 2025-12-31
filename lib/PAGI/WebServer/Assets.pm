package PAGI::WebServer::Assets;
use v5.42.0;
use utf8::all;
use Moo;
use Path::Tiny;
use Log::Log4perl qw(get_logger);

has css_dir => (
  is       => 'ro',
  required => 1
);

has typescript_dir => (
  is       => 'ro',
  required => 1
);

sub compile_css {
  my ($self, $output_dir) = @_;

  my $logger = get_logger(__PACKAGE__);
  $logger->info("Compiling CSS from " . $self->css_dir);

  my $css_path = path($self->css_dir);
  return unless $css_path->exists;

  # Use PostCSS to compile CSS files
  system("pnpm", "postcss", $css_path->stringify . "/**/*.css",
    "--dir", $output_dir, "--ext", ".css");
}

sub compile_typescript {
  my ($self, $output_dir) = @_;

  my $logger = get_logger(__PACKAGE__);
  $logger->info("Compiling TypeScript from " . $self->typescript_dir);

  my $ts_path = path($self->typescript_dir);
  return unless $ts_path->exists;

  # Use TypeScript compiler
  system("pnpm", "tsc", "--outDir", $output_dir);
}

1;
