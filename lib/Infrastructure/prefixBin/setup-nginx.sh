#!/bin/bash

set -e

LONG_OPTS=mode:,domain1:,help
# Define short options string. A colon (:) after an option means it requires an argument.
SHORT_OPTS=m:d:h

PARSED_OPTIONS=$(getopt -o $SHORT_OPTS -l $LONG_OPTS -n "$0" -- "$@")

# Check if getopt encountered an error
if [ $? != 0 ] ; then echo "Terminating..." >&2 ; exit 1 ; fi

# Use eval to properly parse the output of getopt into positional parameters
eval set -- "$PARSED_OPTIONS"

MODE_VALUE=
DOMAIN1=
HELP_FLAG=0

# Loop through the arguments
while true; do
  case "$1" in
  -m | --mode)
    MODE_VALUE="$2"
    shift 2 # Shift past the option and the argument
    ;;
  -d | --domain1)
    DOMAIN1="$2"
    shift 2
    ;;
  -h | --help)
    HELP_FLAG=1
    shift # Shift past the option
    ;;
  --) # End of options marker
    shift
    break
    ;;
  *)
    echo "Internal error: unrecognized option $1" >&2
    exit 1
    ;;
  esac
done

# Function to display help information
display_help() {
  echo "Usage: $0 [-m <mode> | --mode=<mode>]"
  echo "Options:"
  echo "  -m, --mode  Specify the operation mode (e.g., 'read', 'write')"
  echo "  -d, --domain1 Specify the domain name for the primary domain"
  echo "  -h, --help  Display this help message"
}

# Post-processing to ensure the 'mode' parameter was provided
if [ $HELP_FLAG -eq 1 ]; then
  display_help
  exit 0
fi

if [ -z "$MODE_VALUE" ]; then
  echo "Error: The 'mode' parameter is required." >&2
  display_help >&2
  exit 1
fi

if [ -z "$DOMAIN1" ]; then
  echo "Error: The 'domain1 parameter is required." >&2
  display_help >&2
  exit 1
fi


export SITECONFIG='/opt/prefix/app/deploy/nginx-site.conf'

MAX_ATTEMPTS=20
ATTEMPT=1

while [ $ATTEMPT -le $MAX_ATTEMPTS  ]; do

  if [ -f ${SITECONFIG} ]; then
    echo "Site Config is Available"
    break;
  fi

  SLEEP_TIME=$((5 + ATTEMPT * 10))
  echo "SITECONFIG not ready yet, sleeping ${SLEEP_TIME}s..."
  sleep $SLEEP_TIME
  ATTEMPT=$((ATTEMPT + 1))
  
done

if [ $ATTEMPT -eq $MAX_ATTEMPTS ]; then
  echo "application specific nginx site configuration is required!"
  exit 1
fi

if [ -f /opt/prefix/app/deploy/.htpasswd ]; then 
  mv /opt/prefix/app/deploy/.htpasswd /opt/prefix/etc/
  chgrp www-data /opt/prefix/etc/.htpasswd
  chmod 640 /opt/prefix/etc/.htpasswd
fi

# Remove default site
rm -f /etc/nginx/sites-enabled/default


export H=$( grep 127.0.1.1 /etc/hosts | cut -d ' ' -f 3 | cut -d '.' -f 1);

sed -i -E "s/REPLACE_HOSTNAME/${H}/g" ${SITECONFIG}
sed -i -E "s/REPLACE_DOMAIN/${DOMAIN1}/g" ${SITECONFIG}

SERVER_NAMES=''
if [[ "$MODE_VALUE" == "prod" ]]; then
  SERVER_NAMES="${HOSTNAME}.${DOMAIN1} ${DOMAIN1} www.${DOMAIN1}"
else
  SERVER_NAMES="${HOSTNAME}.${DOMAIN1} ${MODE_VALUE}.${DOMAIN1} www.${MODE_VALUE}.${DOMAIN1}"
fi
sed -i -E "s/REPLACE_SERVER_NAMES/${SERVER_NAMES}/" ${SITECONFIG}

cp ${SITECONFIG} /etc/nginx/sites-available/appproxy

ln -s /etc/nginx/sites-available/appproxy /etc/nginx/sites-enabled/

echo "Installed app-provided nginx config"

/usr/bin/systemctl reload nginx || /usr/sbin/nginx -T 

exit 0
