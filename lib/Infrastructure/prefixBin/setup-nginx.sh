#!/bin/bash

set -e

if [ -f /opt/prefix/app/deploy/.htpasswd ]; then 
    mv /opt/prefix/app/deploy/.htpasswd /opt/prefix/etc/
    chgrp www-data /opt/prefix/etc/.htpasswd
    chmod 640 /opt/prefix/etc/.htpasswd
fi

# Check if app provides its own nginx config
if [ -f /opt/prefix/app/deploy/nginx-site.conf ]; then
  # Use app-provided config
  export H=$( grep 127.0.1.1 /etc/hosts | cut -d ' ' -f 3 | cut -d '.' -f 1);
  
  # Copy and process template
  sudo cp /opt/prefix/app/deploy/nginx-site.conf /etc/nginx/sites-available/app
  
  # Replace placeholders (apps can use these variables)
  sudo sed -i "s/REPLACE_HOSTNAME/${H}/g" /etc/nginx/sites-available/app
  
  # Enable site
  sudo ln -sf /etc/nginx/sites-available/app /etc/nginx/sites-enabled/app
  
  # Remove default site
  sudo rm -f /etc/nginx/sites-enabled/default
  
  echo "Installed app-provided nginx config"
  exit 0
fi

# Fallback: generic config (for backward compatibility)
export H=$( grep 127.0.1.1 /etc/hosts | cut -d ' ' -f 3 | cut -d '.' -f 1);
export APPROXY=$( mktemp );
cat > ${APPROXY} << EOF
upstream application {
  server 127.0.1.1:REPLACE_PORT  ;
  # Maintain pool of idle keepalive connections to reduce connection overhead
  keepalive 32;
  keepalive_requests 10000;
  keepalive_timeout 1h;
}
server {
  listen                80;
  server_name           ${H}.REPLACE_DOMAIN REPLACE2.REPLACE_DOMAIN www.REPLACE2.REPLACE_DOMAIN;
  return                301 https://$host$request_uri;
}
# Rate limit zones - apply based on whether request is from trusted source
map \$http_user_agent \$limit_key {
  default                           \$binary_remote_addr;
  ~*LinkChecker                     "";                      # Your link checker bypasses limits
  ~*Googlebot                       "";                      # Google gets a pass
  ~*bingbot                         "";                      # Bing gets a pass
}

limit_req_zone \$limit_key zone=anti_hammer:10m rate=100r/s;        # Increased for link checker
limit_req_zone \$limit_key zone=generals_heavy:10m rate=50r/s;      # Increased for link checker
limit_req_zone \$binary_remote_addr zone=security_scan:10m rate=1r/m;  # New: block scanners

# Bypass rate limits for trusted bots
geo \$bypass_rate_limit {
  default 0;
}
map \$http_user_agent \$bypass_rate_limit {
  default 0;
  ~*LinkChecker 1;
  ~*Googlebot 1;
  ~*bingbot 1;
}

server {
  listen 443 ssl;
  server_name           ${H}.REPLACE_DOMAIN REPLACE2.REPLACE_DOMAIN www.REPLACE2.REPLACE_DOMAIN;
  ssl_certificate       /etc/nginx/ssl/REPLACE_DOMAIN.crt;
  ssl_certificate_key   /etc/nginx/ssl/REPLACE_DOMAIN.key;
  ssl_protocols         TLSv1 TLSv1.1 TLSv1.2 TLSv1.3;
  ssl_ciphers           HIGH:!aNULL:!MD5;
  ssl_session_timeout   15m;
  # Block OpenAI crawlers
  if (\$http_referer ~* (openai\.com)) {
    return 444;
  }

  # Block common security scanning patterns
  location ~* /(\.env|\.git|wp-admin|phpMyAdmin|admin|\.php\$|\.asp\$) {
    limit_req zone=security_scan burst=1 nodelay;
    limit_req_status 444;  # Close connection without response
    return 404;
  }

  # Block requests with suspicious query strings (SQL injection, XSS attempts)
  if (\$args ~* (union.*select|concat.*\(|base64_|javascript:|<script)) {
    return 444;
  }

  # Serve static files directly from nginx (much faster than proxying to Mojolicious)
  # These are compiled assets in the shared data directory
  location ~* ^/(css|js|images|assets|types)/ {
    root /opt/prefix/app/share/public;
    expires 1y;
    add_header Cache-Control "public, immutable";

    # Enable gzip compression for text-based files
    gzip on;
    gzip_types text/css application/javascript application/json image/svg+xml;
    gzip_vary on;
  }

  # Serve ads.txt directly
  location = /ads.txt {
    root /opt/prefix/app/share/public;
    expires 1d;
  }

  location /Generals {
    limit_req zone=generals_heavy burst=5 nodelay;  # Raised from 2
    limit_req_status 429;
    proxy_pass http://application;
    proxy_http_version 1.1;
    proxy_read_timeout 3600;
    proxy_set_header Upgrade \$http_upgrade;
    proxy_set_header Connection "upgrade";
    proxy_set_header Host \$host;
    proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto \$scheme;
    proxy_connect_timeout 300s;
    proxy_send_timeout 300s;
  }

  location / {
    limit_req zone=anti_hammer burst=10 nodelay;  # Raised from 5
    limit_req_status 429;
    proxy_pass http://application;
    proxy_http_version 1.1;
    proxy_read_timeout 3600;
    proxy_set_header Upgrade \$http_upgrade;
    proxy_set_header Connection "upgrade";
    proxy_set_header Host \$host;
    proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto \$scheme;
    proxy_connect_timeout 300s;
    proxy_send_timeout 300s;
  }
}
EOF

sudo cp ${APPROXY} /etc/nginx/sites-available/appproxy
sudo ln -s /etc/nginx/sites-available/appproxy /etc/nginx/sites-enabled/

exit 0
