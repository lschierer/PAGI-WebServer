package WebFramework::Controller::Base;

use v5.42.0;
use utf8::all;
use Mooish::Base -standard;
extends 'Thunderhorse::Controller';
with 'WebFramework::Role::Markdown';
with 'WebFramework::Role::LogConfig';

require JSON::MaybeXS;
use Future::AsyncAwait;
use Path::Tiny;
use Encode      qw(encode_utf8);
use URI::Escape qw(uri_escape_utf8);

has app_config => (
  is      => 'ro',
  default => sub {
    my $self = shift;
    return $self->app->config;
  },
);

sub build ($self) {
  $self->SUPER::build();
  my $router = $self->router;

  # Robots.txt route
  $router->add(
    '/robots.txt',
    {
      to => sub ($self, $ctx) {
        my $host   = $ctx->req->headers->{'host'} // '';
        my $is_dev = $host =~ /dev|localhost|127\.0\.[0-9]{1}\.1/i;

        my $base = $ctx->req->scheme . '://' . $ctx->req->host . '/';
        my $robots =
          $is_dev
          ? "User-agent: *\nDisallow: /\n"
          : "User-agent: *\nDisallow:\nSitemap: " . $base . "sitemap.xml\n";

        $ctx->res->headers(content_type => 'text/plain');
        return $robots;
      },
      action => 'http.*',
    }
  );

  # Health check route
  $router->add(
    '/health',
    {
      to => sub ($self, $ctx) {
        my $APP_START_TIME = $self->app->config->{config}->{APP_START_TIME}
          // time();
        my $deployment_env =
          $self->app->config->{config}->{'EvonyTKR-Environment'} // {};

        # Determine if we're in EC2 or container environment
        my $is_ec2 = !$deployment_env->{'IMAGE_TAG'};

        my $env_info = {};
        if ($is_ec2) {
          # EC2 deployment info
          $env_info = {
            deployment_type => 'ec2',
            hostname        => $deployment_env->{'HOSTNAME'} // `hostname`,
            git_commit      =>
              $self->app->config->{config}->{version}->{'git-commit'}
              // 'unknown',
            git_branch =>
              $self->app->config->{config}->{version}->{'git-branch'}
              // 'unknown',
            build_time =>
              $self->app->config->{config}->{version}->{'build-time'}
              // 'unknown',
            cdk_deployment_time => $deployment_env->{'DEPLOYMENT_TIME'}
              // 'unknown',
          };
          chomp $env_info->{hostname} if $env_info->{hostname};
        }
        else {
          # Container deployment info
          $env_info = {
            deployment_type     => 'container',
            cdk_deployment_time => $deployment_env->{'DEPLOYMENT_TIME'}
              // 'unknown',
          };
        }

        my $json = JSON::MaybeXS->new(utf8 => 1, pretty => 1);

        my $response = $json->encode({
          status  => 'ok',
          mode    => $self->app->env                         // 'unknown',
          version => $self->app->config->{config}->{version} // 'unknown',
          time               => scalar localtime,
          app_started_at     => scalar(localtime($APP_START_TIME)),
          app_uptime_seconds => time() - $APP_START_TIME,
          %$env_info,
        });

        $ctx->res->content_type( 'application/json; charset=utf-8');
        return $response;
      },
      action => 'http.*',
    }
  );

}
