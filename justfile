# Install dependencies
install:
    mise install
    pnpm install
    perl Build.PL
    ./Build installdeps

# Build the project
build:
    ./Build
    pnpm run build

tidy:
    find lib -name '*.pm' -exec perltidy -b -pro=.perltidyrc {} \;
    find t -name '*.t' -exec perltidy -b -pro=.perltidyrc {} \;
    perltidy -b -pro=.perltidyrc Build.PL
    perltidy -b -pro=.perltidyrc bin/server.pl
    find . -name '*.bak' -delete

# Run tests
test:
    ./Build test
    pnpm test

# Clean build artifacts
clean:
    ./Build clean
    pnpm run clean

# Development server
dev:
    ./Build && perl bin/server.pl

# Production server
prod:
    ./Build && perl bin/server.pl --mode production
