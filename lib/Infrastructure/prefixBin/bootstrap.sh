#! /bin/bash -x
set -e

APP_HOME="/opt/prefix"
APP_PATH="${APP_HOME}/app"
PAGI_PATH="${APP_HOME}/PAGI-WebServer"
PREFIX='PREFIXREPLACE'
export PATH="/opt/prefix/.local/bin/:$HOME/bin:$PATH"


# Helper function to retry commands with exponential backoff
retry_with_backoff() {
  local max_attempts=5
  local timeout=1
  local attempt=1
  local exitCode=0

  while (( attempt <= max_attempts ))
  do
    if "$@"
    then
      return 0
    else
      exitCode=$?
    fi

    echo "Command failed (attempt $attempt/$max_attempts). Retrying in $timeout seconds..."
    sleep $timeout
    timeout=$(( timeout * 2 ))
    attempt=$(( attempt + 1 ))
  done

  echo "Command failed after $max_attempts attempts: $*"
  return $exitCode
}

# Install mise with retry
retry_with_backoff curl -fsSL https://mise.run | sh

# Add mise binary to PATH
export PATH="/opt/prefix/.local/bin:$HOME/bin:$PATH"

# Download application code from S3 asset
cd /opt/prefix
aws s3 cp s3://REPLACE_BUCKET/REPLACE_KEY app.zip

# Find the project directory name in the zip
PROJECT_DIR=$(unzip -l app.zip | grep -m1 "/" | awk '{print $4}' | cut -d'/' -f1)

mkdir -p /opt/prefix/app
unzip -q app.zip -d app
rm app.zip

# Rename to 'app' if needed
if [ -n "$PROJECT_DIR" ] && [ "$PROJECT_DIR" != "app" ] && [ -d "$PROJECT_DIR" ]; then
  mv "$PROJECT_DIR" app
fi

# Clone PAGI-WebServer framework.
#
# The branch is overridable so an unmerged framework branch can actually be tested on
# a dev stack. Hardcoded to main, there was no way to exercise a framework change
# before merging it - which defeats the point of branching the framework at all, since
# the deploy scripts need a commit to work from. Set PAGI_BRANCH in the instance
# environment (see userdata) to deploy a branch; it defaults to main.
#
# There is deliberately NO fallback for an unsubstituted token. The first version of
# this had one, and it silently deployed main instead of the requested branch: the sed
# in userdata.ts is global, so it rewrote the token in the guard's own pattern as well
# as in the default, leaving `case "$PAGI_BRANCH" in consolidate-css-build) PAGI_BRANCH=main`.
# The guard therefore fired exactly when substitution had SUCCEEDED, and the only
# evidence was a framework checkout whose package.json was one commit behind.
# An unsubstituted token now fails the clone loudly under `set -e`, which is the
# behaviour we want - quietly building the wrong branch costs a whole deploy cycle.
PAGI_BRANCH="${PAGI_BRANCH:-PAGIBRANCHREPLACE}"
retry_with_backoff git clone -b "${PAGI_BRANCH}" https://github.com/lschierer/PAGI-WebServer.git /opt/prefix/PAGI-WebServer

# Build PAGI-WebServer first
cd $PAGI_PATH
mise trust -a
mise install
mise reshim

# Add mise shims to PATH (more reliable than mise activate in scripts)
export PATH="/opt/prefix/.local/share/mise/shims:$PATH"

# Set up bash_profile for future interactive sessions
cat > ~/.bash_profile << 'EOF'
export PATH="/opt/prefix/.local/share/mise/shims:/opt/prefix/.local/bin:$HOME/bin:$PATH"
eval "$(/opt/prefix/.local/bin/mise activate bash)"
EOF

# Install cpanm (not included with mise's perl by default)
curl -L https://cpanmin.us | perl - App::cpanminus
mise reshim
#cpanm --self-upgrade -q

# Pre-install HTML::Tree family to avoid circular dependency issues
cpanm -nq HTML::Tagset HTML::Parser HTML::Tree

cpanm Module::Build utf8::all File::Find::Rule
perl Build.PL
./Build installdeps --cpan_client 'cpanm -nq --with-recommends'
./Build manifest
./Build

# The framework's NODE dependencies, not just its Perl ones.
#
# scripts/build-css.ts lives here now and the sites' builds import it, so the plugins
# it calls (postcss and friends) must resolve from THIS directory's node_modules.
# Without this the site build fails on the host at the first plugin import, while
# succeeding locally where a developer has run install here by hand.
export NODE_OPTIONS=--max_old_space_size=1536
pnpm install
unset NODE_OPTIONS

# Build application
cd $APP_PATH
mise trust
mise install
mise reshim

# Run project-specific build script if it exists
if [ -f "./scripts/build-for-deploy.sh" ]; then
  bash ./scripts/build-for-deploy.sh
else
  # Default build for simple Perl projects
  perl Build.PL
  ./Build installdeps --cpan_client 'cpanm -nq --with-recommends'
  ./Build manifest
  ./Build
fi

sudo systemctl start ${PREFIX}

echo 'bootstrap complete - SUCCESS' | tee -a ${HOME}/var/log/bootstrap.log
exit 0
