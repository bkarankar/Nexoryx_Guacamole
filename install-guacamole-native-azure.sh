#!/usr/bin/env bash
set -Eeuo pipefail

export DEBIAN_FRONTEND=noninteractive

GUAC_VERSION="${GUAC_VERSION:-1.6.0}"

# Azure App Registration values
AZURE_TENANT_ID="${AZURE_TENANT_ID:-REPLACE_ME}"
AZURE_CLIENT_ID="${AZURE_CLIENT_ID:-REPLACE_ME}"

# Preferred DNS name for Guacamole
GUAC_FQDN="${GUAC_FQDN:-guacamole.devops.karankar.com}"
GUAC_PUBLIC_URL="${GUAC_PUBLIC_URL:-https://${GUAC_FQDN}:8443/guacamole/}"

MYSQL_DATABASE="${MYSQL_DATABASE:-guacamole_db}"
MYSQL_USER="${MYSQL_USER:-guacamole_user}"
MYSQL_PASSWORD_FILE="/root/.guacamole-mysql-password"

INSTALL_LOG="/root/guacamole-native-install.log"
APACHE_BASE_URL="https://downloads.apache.org/guacamole/${GUAC_VERSION}"
MAVEN_BASE_URL="https://repo1.maven.org/maven2"
MYSQL_CONNECTOR_VERSION="${MYSQL_CONNECTOR_VERSION:-8.4.0}"

POLICY_RC_BACKUP=""
NGINX_BACKUP_DIR="/root/nginx-backup-before-guacamole-$(date +%Y%m%d-%H%M%S)"

log() {
  echo
  echo "[$(date '+%F %T')] $*"
}

die() {
  echo "ERROR: $*" >&2
  exit 1
}

require_root() {
  [ "$(id -u)" -eq 0 ] || die "Run as root: sudo bash $0"
}

cleanup_policy_rc() {
  if [ -n "${POLICY_RC_BACKUP}" ] && [ -f "${POLICY_RC_BACKUP}" ]; then
    mv "${POLICY_RC_BACKUP}" /usr/sbin/policy-rc.d
    chmod +x /usr/sbin/policy-rc.d
  elif [ -f /usr/sbin/policy-rc.d ] && grep -q "guacamole installer temporary policy" /usr/sbin/policy-rc.d; then
    rm -f /usr/sbin/policy-rc.d
  fi
}

trap 'cleanup_policy_rc; echo "Install failed. Check: '"${INSTALL_LOG}"'" >&2' ERR
trap 'cleanup_policy_rc' EXIT

exec > >(tee -a "${INSTALL_LOG}") 2>&1

disable_service_autostart_during_apt() {
  log "Temporarily disabling service auto-start during apt operations"

  if [ -f /usr/sbin/policy-rc.d ]; then
    POLICY_RC_BACKUP="/usr/sbin/policy-rc.d.guacamole-backup"
    cp -a /usr/sbin/policy-rc.d "${POLICY_RC_BACKUP}"
  fi

  cat >/usr/sbin/policy-rc.d <<'EOF'
#!/bin/sh
# guacamole installer temporary policy
exit 101
EOF

  chmod +x /usr/sbin/policy-rc.d
}

backup_existing_nginx_sites() {
  log "Backing up existing nginx enabled sites to ${NGINX_BACKUP_DIR}"

  mkdir -p "${NGINX_BACKUP_DIR}"

  if [ -d /etc/nginx/sites-enabled ]; then
    cp -a /etc/nginx/sites-enabled "${NGINX_BACKUP_DIR}/sites-enabled" || true
    find /etc/nginx/sites-enabled -mindepth 1 -maxdepth 1 -exec rm -f {} \; || true
  fi

  if [ -d /etc/nginx/conf.d ]; then
    cp -a /etc/nginx/conf.d "${NGINX_BACKUP_DIR}/conf.d" || true
  fi
}

repair_dpkg_state() {
  log "Repairing any half-configured dpkg/apt state"

  apt-get update -y || true
  dpkg --configure -a || true
  apt-get install -f -y || true
}

install_packages() {
  log "Installing OS packages"

  apt-get update -y

  apt-get install -y \
    build-essential \
    libcairo2-dev \
    libjpeg-turbo8-dev \
    libpng-dev \
    libtool-bin \
    uuid-dev \
    libossp-uuid-dev \
    libvncserver-dev \
    freerdp2-dev \
    libssh2-1-dev \
    libssl-dev \
    libtelnet-dev \
    libpango1.0-dev \
    libwebsockets-dev \
    libavcodec-dev \
    libavformat-dev \
    libavutil-dev \
    libswscale-dev \
    libvorbis-dev \
    libwebp-dev \
    libpulse-dev \
    tomcat10 \
    tomcat-jakartaee-migration \
    mariadb-server \
    mariadb-client \
    nginx \
    openjdk-21-jre-headless \
    wget \
    curl \
    tar \
    gzip \
    openssl \
    ca-certificates \
    python3 \
    acl \
    iproute2

  cleanup_policy_rc

  systemctl enable --now mariadb
}

create_users_and_dirs() {
  log "Creating users and directories"

  id guacd >/dev/null 2>&1 || useradd --system --home-dir /var/lib/guacamole --shell /usr/sbin/nologin guacd

  mkdir -p \
    /etc/guacamole/extensions \
    /etc/guacamole/lib \
    /var/lib/guacamole/recordings \
    /opt/guacamole-src \
    /etc/nginx/ssl \
    /etc/systemd/system/tomcat10.service.d

  chown -R guacd:tomcat /var/lib/guacamole
  chmod 2750 /var/lib/guacamole/recordings

  setfacl -R -m u:guacd:rwx,g:tomcat:rx /var/lib/guacamole/recordings
  setfacl -R -d -m u:guacd:rwx,g:tomcat:rx /var/lib/guacamole/recordings

  cat >/etc/systemd/system/tomcat10.service.d/guacamole.conf <<'EOF'
[Service]
Environment="GUACAMOLE_HOME=/etc/guacamole"
EOF

  systemctl daemon-reload
}

build_guacd() {
  log "Downloading and building guacamole-server ${GUAC_VERSION}"

  cd /opt/guacamole-src
  rm -rf "guacamole-server-${GUAC_VERSION}" "guacamole-server-${GUAC_VERSION}.tar.gz"

  wget -q "${APACHE_BASE_URL}/source/guacamole-server-${GUAC_VERSION}.tar.gz"
  tar -xzf "guacamole-server-${GUAC_VERSION}.tar.gz"

  cd "guacamole-server-${GUAC_VERSION}"
  ./configure --with-systemd-dir=/etc/systemd/system
  make -j"$(nproc)"
  make install
  ldconfig

  cat >/etc/systemd/system/guacd.service <<'EOF'
[Unit]
Description=Apache Guacamole proxy daemon
After=network.target
Wants=network.target

[Service]
Type=simple
User=guacd
Group=guacd
ExecStart=/usr/local/sbin/guacd -f -L info -b 127.0.0.1 -l 4822
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable guacd
}

download_guacamole_components() {
  log "Downloading Guacamole web app and extensions"

  cd /opt/guacamole-src
  rm -rf \
    "guacamole-${GUAC_VERSION}.war" \
    "guacamole-auth-jdbc-${GUAC_VERSION}" \
    "guacamole-auth-sso-${GUAC_VERSION}" \
    "guacamole-history-recording-storage-${GUAC_VERSION}" \
    "guacamole-auth-jdbc-${GUAC_VERSION}.tar.gz" \
    "guacamole-auth-sso-${GUAC_VERSION}.tar.gz" \
    "guacamole-history-recording-storage-${GUAC_VERSION}.tar.gz"

  wget -q "${APACHE_BASE_URL}/binary/guacamole-${GUAC_VERSION}.war"
  wget -q "${APACHE_BASE_URL}/binary/guacamole-auth-jdbc-${GUAC_VERSION}.tar.gz"
  wget -q "${APACHE_BASE_URL}/binary/guacamole-auth-sso-${GUAC_VERSION}.tar.gz"
  wget -q "${APACHE_BASE_URL}/binary/guacamole-history-recording-storage-${GUAC_VERSION}.tar.gz"

  tar -xzf "guacamole-auth-jdbc-${GUAC_VERSION}.tar.gz"
  tar -xzf "guacamole-auth-sso-${GUAC_VERSION}.tar.gz"
  tar -xzf "guacamole-history-recording-storage-${GUAC_VERSION}.tar.gz"

  wget -q -O "/etc/guacamole/lib/mysql-connector-j-${MYSQL_CONNECTOR_VERSION}.jar" \
    "${MAVEN_BASE_URL}/com/mysql/mysql-connector-j/${MYSQL_CONNECTOR_VERSION}/mysql-connector-j-${MYSQL_CONNECTOR_VERSION}.jar"
}

migrate_to_jakarta() {
  src="$1"
  dst="$2"

  if command -v javax2jakarta >/dev/null 2>&1; then
    javax2jakarta "${src}" "${dst}"
    return
  fi

  migration_jar="$(ls /usr/share/java/tomcat-jakartaee-migration*.jar 2>/dev/null | head -n 1 || true)"

  if [ -n "${migration_jar}" ]; then
    java -jar "${migration_jar}" "${src}" "${dst}"
    return
  fi

  die "Could not find Jakarta migration tool. Package tomcat-jakartaee-migration may not be installed correctly."
}

setup_database() {
  log "Configuring MariaDB database"

  if [ -f "${MYSQL_PASSWORD_FILE}" ]; then
    MYSQL_PASSWORD="$(cat "${MYSQL_PASSWORD_FILE}")"
  else
    MYSQL_PASSWORD="$(openssl rand -base64 36 | tr -d '\n')"
    echo "${MYSQL_PASSWORD}" > "${MYSQL_PASSWORD_FILE}"
    chmod 600 "${MYSQL_PASSWORD_FILE}"
  fi

  mysql <<SQL
CREATE DATABASE IF NOT EXISTS ${MYSQL_DATABASE} CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS '${MYSQL_USER}'@'localhost' IDENTIFIED BY '${MYSQL_PASSWORD}';
GRANT SELECT,INSERT,UPDATE,DELETE ON ${MYSQL_DATABASE}.* TO '${MYSQL_USER}'@'localhost';
FLUSH PRIVILEGES;
SQL

  if ! mysql "${MYSQL_DATABASE}" -e "SHOW TABLES LIKE 'guacamole_user';" | grep -q guacamole_user; then
    log "Importing Guacamole JDBC schema"

    cat \
      "/opt/guacamole-src/guacamole-auth-jdbc-${GUAC_VERSION}/mysql/schema/001-create-schema.sql" \
      "/opt/guacamole-src/guacamole-auth-jdbc-${GUAC_VERSION}/mysql/schema/002-create-admin-user.sql" \
      | mysql "${MYSQL_DATABASE}"
  else
    log "Guacamole schema already exists, skipping schema import"
  fi
}

install_webapp_and_extensions() {
  log "Installing Guacamole webapp and extensions"

  rm -f /etc/guacamole/extensions/*.jar

  cp "/opt/guacamole-src/guacamole-auth-jdbc-${GUAC_VERSION}/mysql/guacamole-auth-jdbc-mysql-${GUAC_VERSION}.jar" \
    "/etc/guacamole/extensions/guacamole-auth-jdbc-mysql-${GUAC_VERSION}.jar"

  cp "/opt/guacamole-src/guacamole-auth-sso-${GUAC_VERSION}/openid/guacamole-auth-sso-openid-${GUAC_VERSION}.jar" \
    "/etc/guacamole/extensions/guacamole-auth-sso-openid-${GUAC_VERSION}.jar"

  cp "/opt/guacamole-src/guacamole-history-recording-storage-${GUAC_VERSION}/guacamole-history-recording-storage-${GUAC_VERSION}.jar" \
    "/etc/guacamole/extensions/guacamole-history-recording-storage-${GUAC_VERSION}.jar"

  rm -f /tmp/guacamole.war /tmp/*.jakarta.jar

  migrate_to_jakarta \
    "/opt/guacamole-src/guacamole-${GUAC_VERSION}.war" \
    "/tmp/guacamole.war"

  install -m 0644 /tmp/guacamole.war /var/lib/tomcat10/webapps/guacamole.war

  for jar in /etc/guacamole/extensions/*.jar; do
    base="$(basename "$jar")"
    migrate_to_jakarta "$jar" "/tmp/${base}.jakarta.jar"
    install -m 0644 "/tmp/${base}.jakarta.jar" "$jar"
  done

  chown -R root:tomcat /etc/guacamole
  chmod -R 750 /etc/guacamole
  chmod 640 /etc/guacamole/extensions/*.jar /etc/guacamole/lib/*.jar
}

write_guacamole_properties() {
  log "Writing /etc/guacamole/guacamole.properties"

  MYSQL_PASSWORD="$(cat "${MYSQL_PASSWORD_FILE}")"

  cat >/etc/guacamole/guacamole.properties <<EOF
guacd-hostname: 127.0.0.1
guacd-port: 4822

mysql-hostname: localhost
mysql-port: 3306
mysql-database: ${MYSQL_DATABASE}
mysql-username: ${MYSQL_USER}
mysql-password: ${MYSQL_PASSWORD}

openid-authorization-endpoint: https://login.microsoftonline.com/${AZURE_TENANT_ID}/oauth2/v2.0/authorize
openid-jwks-endpoint: https://login.microsoftonline.com/${AZURE_TENANT_ID}/discovery/v2.0/keys
openid-issuer: https://login.microsoftonline.com/${AZURE_TENANT_ID}/v2.0
openid-client-id: ${AZURE_CLIENT_ID}
openid-redirect-uri: ${GUAC_PUBLIC_URL}
openid-scope: openid email profile
openid-username-claim-type: preferred_username
openid-groups-claim-type: groups

extension-priority: openid, mysql

recording-search-path: /var/lib/guacamole/recordings
EOF

  chown root:tomcat /etc/guacamole/guacamole.properties
  chmod 640 /etc/guacamole/guacamole.properties
}

fix_guacd_config_permissions() {
  log "Fixing guacd config permissions"

  mkdir -p /etc/guacamole
  touch /etc/guacamole/guacd.conf

  chown root:tomcat /etc/guacamole
  chmod 750 /etc/guacamole

  chown root:guacd /etc/guacamole/guacd.conf
  chmod 640 /etc/guacamole/guacd.conf

  setfacl -m u:guacd:rx /etc/guacamole
  setfacl -m u:guacd:r /etc/guacamole/guacd.conf
}

configure_recording_defaults() {
  log "Installing database trigger for default recording parameters"

  mysql "${MYSQL_DATABASE}" <<'SQL'
DROP TRIGGER IF EXISTS guac_default_recording_params;

DELIMITER //

CREATE TRIGGER guac_default_recording_params
AFTER INSERT ON guacamole_connection
FOR EACH ROW
BEGIN
  INSERT IGNORE INTO guacamole_connection_parameter
    (connection_id, parameter_name, parameter_value)
  VALUES
    (NEW.connection_id, 'recording-path', '/var/lib/guacamole/recordings/${HISTORY_UUID}'),
    (NEW.connection_id, 'recording-name', 'recording'),
    (NEW.connection_id, 'create-recording-path', 'true'),
    (NEW.connection_id, 'recording-include-keys', 'true'),
    (NEW.connection_id, 'typescript-path', '/var/lib/guacamole/recordings/${HISTORY_UUID}'),
    (NEW.connection_id, 'typescript-name', 'typescript'),
    (NEW.connection_id, 'create-typescript-path', 'true');
END//

DELIMITER ;
SQL

  mysql "${MYSQL_DATABASE}" <<'SQL'
INSERT IGNORE INTO guacamole_connection_parameter (connection_id, parameter_name, parameter_value)
SELECT connection_id, 'recording-path', '/var/lib/guacamole/recordings/${HISTORY_UUID}'
FROM guacamole_connection;

INSERT IGNORE INTO guacamole_connection_parameter (connection_id, parameter_name, parameter_value)
SELECT connection_id, 'recording-name', 'recording'
FROM guacamole_connection;

INSERT IGNORE INTO guacamole_connection_parameter (connection_id, parameter_name, parameter_value)
SELECT connection_id, 'create-recording-path', 'true'
FROM guacamole_connection;

INSERT IGNORE INTO guacamole_connection_parameter (connection_id, parameter_name, parameter_value)
SELECT connection_id, 'recording-include-keys', 'true'
FROM guacamole_connection;

INSERT IGNORE INTO guacamole_connection_parameter (connection_id, parameter_name, parameter_value)
SELECT connection_id, 'typescript-path', '/var/lib/guacamole/recordings/${HISTORY_UUID}'
FROM guacamole_connection;

INSERT IGNORE INTO guacamole_connection_parameter (connection_id, parameter_name, parameter_value)
SELECT connection_id, 'typescript-name', 'typescript'
FROM guacamole_connection;

INSERT IGNORE INTO guacamole_connection_parameter (connection_id, parameter_name, parameter_value)
SELECT connection_id, 'create-typescript-path', 'true'
FROM guacamole_connection;
SQL
}

configure_nginx_ssl() {
  log "Configuring Nginx HTTPS reverse proxy"

  HOSTNAME_OR_IP="$(python3 - <<PY
from urllib.parse import urlparse
print(urlparse("${GUAC_PUBLIC_URL}").hostname or "localhost")
PY
)"

  mkdir -p /etc/nginx/ssl /etc/nginx/sites-available /etc/nginx/sites-enabled

  if [ ! -f /etc/nginx/ssl/guacamole.key ] || [ ! -f /etc/nginx/ssl/guacamole.crt ]; then
    if python3 - <<PY
import ipaddress
ipaddress.ip_address("${HOSTNAME_OR_IP}")
PY
    then
      SAN_LINE="IP.1 = ${HOSTNAME_OR_IP}"
    else
      SAN_LINE="DNS.1 = ${HOSTNAME_OR_IP}"
    fi

    cat >/etc/nginx/ssl/guacamole-openssl.cnf <<EOF
[req]
default_bits = 4096
prompt = no
default_md = sha256
x509_extensions = v3_req
distinguished_name = dn

[dn]
CN = ${HOSTNAME_OR_IP}

[v3_req]
subjectAltName = @alt_names

[alt_names]
${SAN_LINE}
EOF

    openssl req -x509 -nodes -days 825 -newkey rsa:4096 \
      -keyout /etc/nginx/ssl/guacamole.key \
      -out /etc/nginx/ssl/guacamole.crt \
      -config /etc/nginx/ssl/guacamole-openssl.cnf

    chmod 600 /etc/nginx/ssl/guacamole.key
  fi

  find /etc/nginx/sites-enabled -mindepth 1 -maxdepth 1 -exec rm -f {} \; || true

  cat >/etc/nginx/sites-available/guacamole <<'EOF'
server {
    listen 8443 ssl;
    server_name guacamole.devops.karankar.com;

    ssl_certificate     /etc/nginx/ssl/guacamole.crt;
    ssl_certificate_key /etc/nginx/ssl/guacamole.key;

    client_max_body_size 64m;

    location /guacamole/ {
        proxy_pass http://127.0.0.1:8080/guacamole/;
        proxy_http_version 1.1;

        proxy_buffering off;
        proxy_request_buffering off;

        proxy_set_header Host $host:8443;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Host $host:8443;
        proxy_set_header X-Forwarded-Proto https;
        proxy_set_header X-Forwarded-Port 8443;

        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
    }
}
EOF

  # Replace server_name dynamically if GUAC_FQDN was overridden
  sed -i "s/server_name guacamole.devops.karankar.com;/server_name ${GUAC_FQDN};/" /etc/nginx/sites-available/guacamole

  ln -sf /etc/nginx/sites-available/guacamole /etc/nginx/sites-enabled/guacamole
  rm -f /etc/nginx/sites-enabled/default

  nginx -t
  systemctl enable nginx
}

restart_services() {
  log "Restarting services"

  systemctl restart mariadb
  systemctl reset-failed guacd || true
  systemctl restart guacd
  systemctl restart tomcat10
  systemctl restart nginx

  sleep 12

  systemctl is-active --quiet mariadb || die "MariaDB is not running"
  systemctl is-active --quiet guacd || die "guacd is not running"
  systemctl is-active --quiet tomcat10 || die "Tomcat is not running"
  systemctl is-active --quiet nginx || die "Nginx is not running"
}

verify_installation() {
  log "Verifying installation"

  echo "Guacamole FQDN:"
  echo "${GUAC_FQDN}"

  echo
  echo "Guacamole URL:"
  echo "${GUAC_PUBLIC_URL}"

  echo
  echo "Listening ports:"
  ss -lntp | grep -E '4822|8080|8443' || true

  echo
  echo "Installed Guacamole extensions:"
  ls -l /etc/guacamole/extensions || true

  echo
  echo "OpenID config:"
  grep -E 'openid-|extension-priority' /etc/guacamole/guacamole.properties || true
}

print_summary() {
  cat <<EOF

Apache Guacamole native installation complete.

URL:
  ${GUAC_PUBLIC_URL}

Azure SSO is configured as primary auth:
  extension-priority: openid, mysql

Azure SSO values:
  Tenant ID: ${AZURE_TENANT_ID}
  Client ID: ${AZURE_CLIENT_ID}
  Redirect URI: ${GUAC_PUBLIC_URL}

Local fallback admin account:
  Username: guacadmin
  Password: guacadmin

Change this password immediately after first login.

Recording directory:
  /var/lib/guacamole/recordings

Config file:
  /etc/guacamole/guacamole.properties

Logs:
  Install log: ${INSTALL_LOG}
  Tomcat:      journalctl -u tomcat10 -f
  guacd:       journalctl -u guacd -f
  Nginx:       journalctl -u nginx -f

Nginx backup from before install:
  ${NGINX_BACKUP_DIR}

Route53:
  Create/confirm DNS record:
    ${GUAC_FQDN} -> EC2 private IP

Azure portal checklist:
  App Registration -> Authentication -> Web redirect URI:
    ${GUAC_PUBLIC_URL}

  App Registration -> Authentication -> Settings:
    ID tokens must be enabled

EOF
}

main() {
  require_root
  log "Guacamole FQDN: ${GUAC_FQDN}"
  log "Guacamole public URL: ${GUAC_PUBLIC_URL}"

  disable_service_autostart_during_apt
  backup_existing_nginx_sites
  repair_dpkg_state
  install_packages
  create_users_and_dirs
  build_guacd
  download_guacamole_components
  setup_database
  install_webapp_and_extensions
  write_guacamole_properties
  fix_guacd_config_permissions
  configure_recording_defaults
  configure_nginx_ssl
  restart_services
  verify_installation
  print_summary
}

main "$@"