# PAGI WebServer Framework

A minimal, reusable web server framework built on PAGI for serving multiple related projects with common functionality.

## Features

- **PAGI-based**: Asynchronous web server using the PAGI framework
- **Markdown rendering**: Pandoc integration with configurable modules
- **Asset compilation**: PostCSS for CSS and TypeScript compilation
- **Configurable logging**: Log4perl with per-module log levels and stage-specific defaults
- **Modular design**: Drop-in package for multiple projects

## Requirements

Install these tools using mise:
- Perl 5.42.0
- Node.js (LTS)
- pnpm (latest)
- pandoc (latest)
- mise (latest) — tasks defined in mise.toml [tasks]

## Quick Start

```bash
# Install tools and dependencies
mise run install

# Build the project
mise run build

# Run development server
mise run dev

# Run production server  
mise run prod
```

## Configuration

Copy `config.yml.example` to `config.yml` and customize:

```yaml
stage: localDev
css_dir: share/styles
typescript_dir: src/ts
markdown_dir: content
worker_threads: 4
log_config:
  MyApp::Controller: DEBUG
```

## Usage in Projects

Add as a dependency in your project's `Build.PL`:

```perl
requires => {
    'PAGI::WebServer' => '0.01',
    # ... other deps
}
```

Then use in your application:

```perl
use PAGI::WebServer;
use PAGI::WebServer::Markdown;
use PAGI::WebServer::Assets;

my $server = PAGI::WebServer->new(config_file => 'myapp.yml');
$server->setup_logging;
```

## Testing

```bash
mise run test
```
