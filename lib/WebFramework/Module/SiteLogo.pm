package WebFramework::Module::SiteLogo;

use v5.42.0;
use strict;
use warnings;
use Moo;
extends 'Thunderhorse::Module';

use Path::Tiny;

has logo_file => (
    is      => 'ro',
    default => 'public/images/LukeHPSite.svg',
);

has site_logo => (
    is => 'lazy',
);

sub _build_site_logo ($self) {
    my $logo_path = path($self->logo_file);
    
    return '' unless $logo_path->exists;
    
    my $svg_content = $logo_path->slurp_utf8;
    # Strip XML declaration and DOCTYPE
    $svg_content =~ s/^<\?xml[^?]*\?>\s*//;
    $svg_content =~ s/^<!DOCTYPE[^>]*>\s*//;
    # Add class="site-logo" to svg element
    $svg_content =~ s/<svg/<svg class="site-logo"/;
    
    return $svg_content;
}

sub build ($self) {
    $self->register(
        controller => site_logo => sub ($controller) {
            return $self->site_logo;
        }
    );
}

1;
