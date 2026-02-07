#! /bin/bash -x
set -e

APP_HOME="/opt/prefix"
APP_PATH="${APP_HOME}/app"
PAGI_PATH="${APP_HOME}/PAGI-WebServer"
DOMAIN='PREFIXDOMAIN'
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

# Clone PAGI-WebServer framework
retry_with_backoff git clone -b main https://github.com/lschierer/PAGI-WebServer.git /opt/prefix/PAGI-WebServer

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
cpanm --self-upgrade -q

# Pre-install HTML::Tree family to avoid circular dependency issues
cpanm -nq HTML::Tagset HTML::Parser HTML::Tree

cpanm Module::Build utf8::all
perl Build.PL
./Build installdeps --cpan_client 'cpanm -nq --with-recommends'
./Build manifest
./Build

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

H=$(hostname -s); 

sed -i -E "s/REPLACE_HOSTNAME/${H}/g" /opt/prefix/app/deploy/nginx-site.conf
sed -i -E "s/REPLACE_DOMAIN/${DOMAIN}/g" /opt/prefix/app/deploy/nginx-site.conf
sed -i -E "s/REPLACE2/MODEREPLACE/g" /opt/prefix/app/deploy/nginx-site.conf
# Setup nginx with app-specific config
sudo /opt/prefix/bin/setup-nginx.sh

# wait for cert
sleep 120

# Reload nginx with real certificate
sudo systemctl reload nginx

# Start the application service now that build is complete
sudo systemctl start PREFIXREPLACE

echo 'bootstrap complete - SUCCESS' | tee -a ${HOME}/var/log/bootstrap.log
exit 0
