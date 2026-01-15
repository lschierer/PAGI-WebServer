package WebFramework::Module::SiteLogo;

use v5.42.0;
use strict;
use warnings;
use Moo;
extends 'Thunderhorse::Module';

use Path::Tiny;

has logo_file => (
  is      => 'ro',
  lazy    => 1,
  default => sub {
    my $self = shift;
    return Path::Tiny::path($self->app->config->{config}->{modules}
        ->{'^WebFramework::Module::SiteLogo'}->{site_logo});
  },
);

has site_logo => (
  is      => 'ro',
  lazy    => 1,
  default => sub {
    my $self = shift;
    unless ($self->logo_file->is_file) {
      warn sprintf('cannot find logo file "%s"', $self->logo_file);
      return ' ';
    }

    my $svg_content = $self->logo_file->slurp_utf8;
    $svg_content =~ s/^<\?xml[^?]*\?>\s*//;
    $svg_content =~ s/^<!DOCTYPE[^>]*>\s*//;
    # Add class="site-logo" to svg element
    $svg_content =~ s/<svg/<svg class="site-logo"/;

    return $svg_content;
  },
);

sub build ($self) {
  $self->register(
    controller => site_logo => sub ($controller) {
      return $self->site_logo;
    }
  );
}

1;
