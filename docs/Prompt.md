* This will be used as the base module for four projects. It will house the common code setting up 
   * serving Markdown content with [Pandoc](https://metacpan.org/pod/Pandoc)
   * Hooks for project specific dynamic content 
   * extending log4perl to allow for scaling up and down log levels on a per-module basis with stage (localDev, staging, production) specific defaults.
   * Hooks so that I can drop in CSS files that will then be compiled with PostCSS
   * Hooks so that I can drop in typescript that will be transpiled into javascript that can be included as needed by templates (not a single bundle for the whole site, but in a targeted way to keep pages light weight)
* It will achieve this by including support for a config file. The config file will allow the person (me) using this module to specify where the top level css directory (ie css might reside in share/styles/**/*.css so I would specify share/styles), top level typescript directory, and any other required project configuration (ie a hash of custom log levels for specific modules for use by the central logging mechanism, what Pandoc modules to configure the perl Pandoc module with, or how many threads to spawn as workers). 
* It should usse Module::Build for the base of the Perl build system.
* the overall build should be orchestrated using [just] and [mise]. Install [just] itself using [mise].  where [mise] cannot install a required dependency, note the requirement in the README.  
* [pandoc], [pnpm], [node], [perl] should all be managed by [mise]. 
* require Perl 5.42
* Require the latest typescript 24.x lts. 
* use [PAGI](https://metacpan.org/pod/PAGI) since at least two of the four projects will feature significant asynchronous aspects, and one of the other two requires basic authentication across 90% of the site. 
* Assume that both routes and data contain UTF-8


[just]: https://just.systems/man/en/
[mise]: https://mise.jdx.dev/
