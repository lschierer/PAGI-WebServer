package PAGI::WebServer::Template;
use v5.42.0;
use utf8::all;
use Moo;
use Template;
use Path::Tiny;
use Log::Log4perl qw(get_logger);
use Encode        qw(encode_utf8);

has tt => (is => 'lazy',);

has template_dir => (
  is      => 'ro',
  default => sub {'templates'}
);

has include_path => (
  is      => 'ro',
  default => sub { ['templates'] }
);

sub _build_tt {
  my $self = shift;

  return Template->new({
    INCLUDE_PATH => $self->include_path,
    ENCODING     => 'utf8',
    INTERPOLATE  => 0,
    POST_CHOMP   => 1,
    EVAL_PERL    => 0,
  });
}

sub render {
  my ($self, $template_file, $vars, $options) = @_;
  $options //= {};

  my $logger = get_logger(__PACKAGE__);
  $logger->debug("Rendering template file: $template_file");

  my $output = '';

  # If a layout/wrapper is specified, use it
  if ($options->{layout}) {
    $logger->debug("Using layout: $options->{layout}");

    # First render the content template
    my $content = '';
    unless ($self->tt->process($template_file, $vars, \$content)) {
      my $error = $self->tt->error();
      $logger->error("Template error: $error");
      die "Template processing failed: $error";
    }

    # Then render the layout with the content
    my $layout_vars = { %$vars, content => $content };
    unless ($self->tt->process($options->{layout}, $layout_vars, \$output)) {
      my $error = $self->tt->error();
      $logger->error("Layout error: $error");
      die "Layout processing failed: $error";
    }
  }
  else {
    # No wrapper, just render the template
    unless ($self->tt->process($template_file, $vars, \$output)) {
      my $error = $self->tt->error();
      $logger->error("Template error: $error");
      die "Template processing failed: $error";
    }
  }

  return $output;
}

1;

__END__

=head1 NAME

PAGI::WebServer::Template - Template::Toolkit wrapper for PAGI::WebServer

=head1 SYNOPSIS

    use PAGI::WebServer::Template;

    my $tt = PAGI::WebServer::Template->new(
        template_dir => 'templates',
        include_path => ['templates', 'templates/partials']
    );

    my $html = $tt->render('person/details.tt', {
        person => $person_obj,
        events => \@events,
    });

=head1 DESCRIPTION

A wrapper around Template::Toolkit for rendering templates in PAGI::WebServer.

=cut
