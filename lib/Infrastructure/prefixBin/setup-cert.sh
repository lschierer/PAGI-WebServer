#!/bin/bash
set -e

H=$(hostname -s)
MAX_ATTEMPTS=20
ATTEMPT=1

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


# Check if real cert already exists (not the snake-oil cert)
if [ -L /etc/nginx/ssl/${DOMAIN1}.crt ] && [ -e /etc/nginx/ssl/${DOMAIN1}.crt ]; then
  SUBJECT=$(openssl x509 -in /etc/nginx/ssl/${DOMAIN1}.crt -noout -subject 2>/dev/null || echo "")
  if [[ "$SUBJECT" != *"CN=localhost"* ]]; then
    echo "Certificate already installed and valid"
    exit 0
  fi
  echo "Found snake-oil cert, will replace with real cert"
fi

# Wait for DNS with retries
while [ $ATTEMPT -le $MAX_ATTEMPTS ]; do
  echo "Attempt $ATTEMPT/$MAX_ATTEMPTS: Checking DNS for ${H}.${DOMAIN1}"
  
  DNS_RESULT=$(dig +short @8.8.8.8 ${H}.${DOMAIN1} A)
  echo "DNS result: '$DNS_RESULT'"
  
  if [ -n "$DNS_RESULT" ]; then
    echo "DNS is ready!"
    break
  fi
  
  if [ $ATTEMPT -eq $MAX_ATTEMPTS ]; then
    echo "DNS not ready after $MAX_ATTEMPTS attempts, giving up"
    exit 1
  fi
  
  SLEEP_TIME=$((30 + ATTEMPT * 10))
  echo "DNS not ready yet, sleeping ${SLEEP_TIME}s..."
  sleep $SLEEP_TIME
  ATTEMPT=$((ATTEMPT + 1))
done

# Run certbot with retries
ATTEMPT=1
while [ $ATTEMPT -le 5 ]; do
  echo "Attempt $ATTEMPT/5: Running certbot"
  
  CERTBOTRESULT=
  if [ ${MODE_VALUE} == 'prod' ]; then
    certbot certonly --nginx -m 'staff@schierer.org' --agree-tos -d "${H}.${DOMAIN1}" -d "www.${DOMAIN1}" --non-interactive;
    CERTBOTRESULT=$?;
  else
    DOMAIN2="${MODE_VALUE}.${DOMAIN1}"
    certbot certonly --nginx -m 'staff@schierer.org' --agree-tos -d "${H}.${DOMAIN1}" -d "${DOMAIN2}" -d "www.${DOMAIN2}" --non-interactive;
    CERTBOTRESULT=$?;
  
  fi

  if [ $CERTBOTRESULT -eq 0 ]; then
    # Only replace certs if certbot succeeded
    rm -f /etc/nginx/ssl/${DOMAIN1}.key /etc/nginx/ssl/${DOMAIN1}.crt
    ln -s /etc/letsencrypt/live/${H}.${DOMAIN1}/privkey.pem /etc/nginx/ssl/${DOMAIN1}.key
    ln -s /etc/letsencrypt/live/${H}.${DOMAIN1}/fullchain.pem /etc/nginx/ssl/${DOMAIN1}.crt
    systemctl reload nginx
    echo "Certificate installed successfully"
    exit 0
  fi
  
  if [ $ATTEMPT -eq 5 ]; then
    echo "Certbot failed after 5 attempts, giving up"
    exit 1
  fi
  
  echo "Certbot failed, retrying in 30s..."
  sleep 30
  ATTEMPT=$((ATTEMPT + 1))
done
