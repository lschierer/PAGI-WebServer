use strict;
use warnings;
use Module::Build;

my $builder = Module::Build->new(
  module_name       => 'PAGI::WebServer',
  license           => 'ISC',
  dist_author       => 'Luke Schierer <luke.schierer@gmail.com',
  dist_version_from => 'lib/PAGI/WebServer.pm',
  requires          => {
    'perl'                => '5.42.0',
    'Cpanel::JSON::XS' => '0',
    'File::HomeDir::Tiny' => '0',
    'Future::AsyncAwait'  => '0',
    #'Future::IO'          => '0',
    'IO::Async::Loop'     => '0',
    'PAGI'             => '0',
    'Log::Log4perl'    => '0',
    'Pandoc'           => '0',
    'YAML::XS'         => '0',
    'Path::Tiny'       => '0',
    'Moo'              => '0',
    'Sys::Sendfile'    => '0',
    'Type::Tiny'       => '0',

  },
  configure_requires => {
    'Module::Build' => '0.42'
  },
  build_requires => {
    'utf8::all'                                     => '0',
    'App::podweaver'                                => '0',
    'File::Spec'                                    => '0',
    'FindBin'                                       => '0',
    'File::Find::Rule'                              => '0',
    'File::Find::Rule::Perl'                        => '0',
    'File::Find::Rule::VCS'                         => '0',
    'File::Slurp'                                   => '0',
    'GraphViz'                                      => '0',
    'Software::License::Perl_5'                     => '0',
    'Test::Command'                                 => '0',
    'Test::MockObject'                              => '0',
    'Moose'                                         => '0',
    'Moose::Autobox'                                => '0',
    'Perl::Version'                                 => '0',
    'Pod::Elemental'                                => '0',
    'Pod::Weaver'                                   => '0',
    'Pod::Weaver::Role::SectionReplacer'            => '0',
    'Pod::Weaver::PluginBundle::ReplaceBoilerplate' => '0',
    'Pod::Weaver::Section::Leftovers'               => '0',
    'Log::Any::Adapter'                             => '0',
  },
  test_requires => {
    'Test2::V0' => '0',
  },
  add_to_cleanup     => ['PAGI-WebServer-*'],
  create_makefile_pl => 'traditional',
  create_readme      => 0,
);

$builder->create_build_script();
