package PAGI::WebServer;
use v5.42.0;
use utf8::all;
use Future::AsyncAwait;
use experimental 'signatures';
use Encode qw(encode decode FB_DEFAULT FB_CROAK);
use Moo;
use Types::Standard qw(Str HashRef ArrayRef Bool);
use YAML::XS        qw(LoadFile);
use Path::Tiny;
use Log::Log4perl;
use File::HomeDir::Tiny ();
require PAGI::Server;
use Carp;

our $VERSION = '0.01';

has config_file => (
  is      => 'ro',
  isa     => Str,
  default => 'config.yml'
);

has config => (
  is  => 'lazy',
  isa => HashRef,
);

has css_dir => (
  is  => 'lazy',
  isa => Str,
);

has typescript_dir => (
  is  => 'lazy',
  isa => Str,
);

has markdown_dir => (
  is  => 'lazy',
  isa => Str,
);

has log_config => (
  is  => 'lazy',
  isa => HashRef,
);

has pandoc_modules => (
  is  => 'lazy',
  isa => ArrayRef,
);

has worker_threads => (
  is  => 'lazy',
  isa => Str,
);

has stage => (
  is  => 'lazy',
  isa => Str,
);

has mode => (
  is  => 'lazy',
  isa => Str,
);

sub _build_mode {
    my $self = shift;
    return $self->config->{mode} // 'development';
}

sub _build_config {
  my $self = shift;
  return LoadFile($self->config_file) if -f $self->config_file;
  return {};
}

sub _build_css_dir {
  my $self = shift;
  return $self->config->{css_dir} // 'share/styles';
}

sub _build_typescript_dir {
  my $self = shift;
  return $self->config->{typescript_dir} // 'src/ts';
}

sub _build_markdown_dir {
  my $self = shift;
  return $self->config->{markdown_dir} // 'content';
}

sub _build_log_config {
  my $self = shift;
  return $self->config->{log_config} // {};
}

sub _build_pandoc_modules {
  my $self = shift;
  return $self->config->{pandoc_modules} // [];
}

sub _build_worker_threads {
  my $self = shift;
  return $self->config->{worker_threads} // '4';
}

sub _build_stage {
  my $self = shift;
  return $self->config->{stage} // 'localDev';
}

async sub app ($scope, $receive, $send) {
    die "Unsupported: $scope->{type}" if $scope->{type} ne 'http';

    my $text = '';
    if ($scope->{query_string} =~ /text=([^&]+)/) {
        my $bytes = $1; $bytes =~ s/%([0-9A-Fa-f]{2})/chr hex $1/eg;
        $text = decode('UTF-8', $bytes, FB_DEFAULT);  # replacement for invalid
    }

    my $body    = "You sent: $text";
    my $encoded = encode('UTF-8', $body, FB_CROAK);

    await $send->({
        type    => 'http.response.start',
        status  => 200,
        headers => [
            ['content-type',   'text/plain; charset=utf-8'],
            ['content-length', length($encoded)],
        ],
    });
    await $send->({
        type => 'http.response.body',
        body => $encoded,
        more => 0,
    });
}

sub start {
  my $self = shift;
  $self->setup_logging;

  my $loop = IO::Async::Loop->new;

  # Start the server
  my $server = PAGI::Server->new(
    app   => \&app,
    host  => '127.0.0.1',
    port  => 3000,
  );

  $loop->add($server);
  $server->listen->get;
}

BEGIN {
  our $DEBUG_LOGGING = $ENV{LOG_DEBUG} // 0;
}

sub logFileLocation {
  my $self = shift;
  my $mode = $self->mode // 'production';
  warn "mode is $mode\n" if $PAGI::WebServer::DEBUG_LOGGING;
  my $userHome = File::HomeDir::Tiny::home;
  my @parts    = split '::', __PACKAGE__;
  my $base     = join '-', @parts[0 .. 1];
  my $logDir =
    Path::Tiny::path(sprintf('%s/var/log/Perl/dist/%s', $userHome, $base));
  # Create directory if needed
  $logDir->mkdir({ mode => 0711 })
    unless -d $logDir->absolute->stringify;
  return $logDir;
}

sub setup_logging {
  my $self = shift;

  my $stage_defaults = {
    localDev   => 'DEBUG',
    staging    => 'INFO',
    production => 'WARN'
  };

  my $default_level = $stage_defaults->{ $self->stage } // 'INFO';
  my $log_config    = $self->log_config;
  my $logDir        = $self->logFileLocation();

  my $conf = qq{
        log4perl.rootLogger = $default_level, LOGFILE
        log4perl.appender.LOGFILE = Log::Log4perl::Appender::File
        log4perl.appender.LOGFILE.filename = $logDir/system.log
        log4perl.appender.LOGFILE.mode = append
        log4perl.appender.LOGFILE.utf8 = 1
        log4perl.appender.LOGFILE.layout = Log::Log4perl::Layout::PatternLayout
        log4perl.appender.LOGFILE.layout.ConversionPattern = %d %p %c - %m%n
    };

  # Add module-specific log levels
  for my $module (keys %$log_config) {
    my $level = $log_config->{$module};
    $conf .= "\nlog4perl.logger.$module = $level";
  }

  Log::Log4perl->init(\$conf);
}

1;

__END__

=head1 NAME

PAGI::WebServer - Common web server framework for multiple projects

=head1 SYNOPSIS

    use PAGI::WebServer;

    my $server = PAGI::WebServer->new(
        config_file => 'myapp.yml'
    );

    $server->start;

=head1 DESCRIPTION

A common framework for serving Markdown content with Pandoc, handling CSS/TypeScript compilation,
and providing configurable logging across multiple related projects.

=cut
