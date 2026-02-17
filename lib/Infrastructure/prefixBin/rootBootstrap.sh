#!/bin/bash
# cspell: disable

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

# Wait for DNS records to be created (signaled by SSM parameter)
if [ -f /etc/stack.json ]; then
  DNS_READY_PARAM=$(jq -r '.dnsReadyParam // empty' /etc/stack.json)
  AWS_REGION=$(jq -r '.region // "us-east-2"' /etc/stack.json)
  
  if [ -n "$DNS_READY_PARAM" ]; then
    echo "Waiting for DNS records to be created..."
    while ! aws ssm get-parameter --name "$DNS_READY_PARAM" --region "$AWS_REGION" >/dev/null 2>&1; do
      echo "DNS not ready yet, waiting 10 seconds..."
      sleep 10
    done
    echo "DNS records confirmed ready"
  fi
fi

/opt/prefix/bin/setup-cert.sh --mode ${MODE_VALUE} --domain1 ${DOMAIN1} >> /var/log/setup-cert.log 2>&1 
/opt/prefix/bin/setup-nginx.sh --mode ${MODE_VALUE} --domain1 ${DOMAIN1} >> /var/log/setup-nginx.log 2>&1

if [ -f /opt/prefix/app/scripts/root_prereq_steps.sh ]; then
  chmod 755 /opt/prefix/app/scripts/root_prereq_steps.sh
  /opt/prefix/app/scripts/root_prereq_steps.sh --mode ${MODE_VALUE} --domain1 ${DOMAIN1} >> /var/log/root_preqreq_steps.log
fi

echo "root bootstrap complete";
