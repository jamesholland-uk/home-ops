#!/bin/bash
set -e

# ========================================================
# Observium Docker Deployment for Raspberry Pi
# Avoids NAS permission issues by using Docker volumes
# ========================================================

# --- VARIABLES ---
PI_USER="jamoi"
NAS_SERVER="nas2.jamoi.xyz"
NAS_PATH="/nfs/Data"
MOUNT_POINT="/home/${PI_USER}/NAS"
APP_DIR="/home/${PI_USER}/observium-stack"
MYSQL_ROOT_PASS="ChangeMeRoot"
MYSQL_USER_PASS="ChangeMeUser"
OBSERVIUM_ADMIN_USER="admin"
OBSERVIUM_ADMIN_PASS="ChangeMeAdmin"
DB_DUMP="${MOUNT_POINT}/container_storage/observium/backups/observium_devices.sql"
CURRENT_IP=$(hostname -I | awk '{print $1}')

echo "========================================================"
echo "   Observium Docker Deployment"
echo "   DB: Local SD Card | RRD/Logs: NAS"
echo "========================================================"

# ========================================================
# 1. SYSTEM PREP & DOCKER INSTALLATION
# ========================================================

echo "--> Updating system and installing dependencies..."
apt-get update -y
apt-get install -y ca-certificates curl gnupg lsb-release nfs-common snmpd

# Check if Docker is already installed
if ! command -v docker &> /dev/null; then
    echo "--> Installing Docker..."
    mkdir -p /etc/apt/keyrings
    rm -f /etc/apt/keyrings/docker.gpg
    
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    
    echo \
      "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu \
      $(lsb_release -cs) stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null
    
    apt-get update -y
    apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
    
    echo "--> Adding user $PI_USER to docker group..."
    usermod -aG docker "$PI_USER"
    # Apply group change for current session
    newgrp docker << EOF || true
EOF
else
    echo "--> Docker already installed, skipping..."
fi

# ========================================================
# 2. NAS MOUNT SETUP (Read-only for backup, RW for logs/rrd)
# ========================================================

echo "--> Configuring NAS Mount..."
mkdir -p "$MOUNT_POINT"

if ! grep -q "$NAS_SERVER" /etc/fstab; then
    echo "Adding entry to /etc/fstab..."
    echo "$NAS_SERVER:$NAS_PATH $MOUNT_POINT nfs rw,auto,async,_netdev 0 0" >> /etc/fstab
else
    echo "Entry already exists in /etc/fstab, skipping..."
fi

mount -a || true

# Create directories on NAS (Docker will handle permissions)
echo "--> Creating Observium directories on NAS..."
mkdir -p "$MOUNT_POINT/container_storage/observium/"{logs,rrd,backups} || true

# Note: We don't chmod here - Docker volumes handle permissions automatically

# ========================================================
# 2.5. CONFIGURE SNMP ON HOST
# ========================================================

echo "--> Configuring SNMP on host..."

# Ensure snmpd config directory exists
mkdir -p /etc/snmp

# Backup existing config if it exists
if [ -f /etc/snmp/snmpd.conf ]; then
    cp /etc/snmp/snmpd.conf /etc/snmp/snmpd.conf.bak || true
fi

# Configure SNMP
cat > /etc/snmp/snmpd.conf <<'SNMPEOF'
# SNMP Configuration for Observium monitoring
agentAddress  udp:161
rocommunity cumbria
SNMPEOF

# Restart SNMP service
systemctl restart snmpd || true
systemctl enable snmpd || true

echo "✅ SNMP configured on host (community: cumbria, port: 161)"

# ========================================================
# 3. CREATE APPLICATION DIRECTORY
# ========================================================

mkdir -p "$APP_DIR"
chown "$PI_USER":"$PI_USER" "$APP_DIR"
cd "$APP_DIR"

# ========================================================
# 4. CREATE DOCKERFILE
# ========================================================

echo "--> Creating Dockerfile..."
cat <<'EOF' > Dockerfile
FROM ubuntu:24.04
ENV DEBIAN_FRONTEND=noninteractive

# Install dependencies
RUN apt-get update && apt-get install -y \
    wget \
    apache2 \
    php \
    php-cli \
    php-mysql \
    php-gd \
    php-snmp \
    php-pear \
    php-curl \
    php-mbstring \
    php-xml \
    php-zip \
    libapache2-mod-php \
    snmp \
    graphviz \
    rrdtool \
    fping \
    mariadb-client \
    whois \
    python3-pymysql \
    python3 \
    ca-certificates \
    dnsutils \
    iputils-ping \
    && rm -rf /var/lib/apt/lists/*

# Download and Extract Observium
RUN wget http://www.observium.org/observium-community-latest.tar.gz && \
    tar zxvf observium-community-latest.tar.gz && \
    mv observium /opt/ && \
    rm observium-community-latest.tar.gz

# Create Python symlink for wrapper
RUN ln -sf /usr/bin/python3 /usr/bin/python

# Copy entrypoint
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

WORKDIR /opt/observium
ENTRYPOINT ["/entrypoint.sh"]
EOF

# ========================================================
# 5. CREATE ENTRYPOINT SCRIPT
# ========================================================

echo "--> Creating entrypoint script..."
cat <<'EOF' > entrypoint.sh
#!/bin/bash
# Don't use set -e, we want to handle errors gracefully

# Generate config.php
cat <<CONF > /opt/observium/config.php
<?php
\$config['db_extension'] = 'mysqli';
\$config['db_host']      = getenv('OBSERVIUM_DB_HOST');
\$config['db_user']      = getenv('OBSERVIUM_DB_USER');
\$config['db_pass']      = getenv('OBSERVIUM_DB_PASS');
\$config['db_name']      = getenv('OBSERVIUM_DB_NAME');
\$config['base_url']     = getenv('OBSERVIUM_BASE_URL');
\$config['fping']        = "/usr/bin/fping";
CONF

# Ensure directories exist (rrd and logs are NAS-mounted, don't chown them)
mkdir -p /opt/observium/rrd /opt/observium/logs

# Only chown specific local directories, never touch rrd/logs (they're NAS-mounted)
# This avoids hanging on NFS operations
for dir in html includes libs mibs scripts tests update; do
    [ -d "/opt/observium/$dir" ] && chown -R www-data:www-data "/opt/observium/$dir" 2>/dev/null || true
done
# Chown config.php and other files in root
chown www-data:www-data /opt/observium/config.php 2>/dev/null || true
chown www-data:www-data /opt/observium/*.php 2>/dev/null || true
chown www-data:www-data /opt/observium/*.py 2>/dev/null || true

# Generate SSL certificate if it doesn't exist
if [ ! -f /etc/apache2/ssl/observium.crt ]; then
    mkdir -p /etc/apache2/ssl
    openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
      -keyout /etc/apache2/ssl/observium.key \
      -out /etc/apache2/ssl/observium.crt \
      -subj '/C=US/ST=State/L=City/O=IT/CN=localhost' 2>/dev/null || true
    chmod 644 /etc/apache2/ssl/observium.crt 2>/dev/null || true
    chmod 600 /etc/apache2/ssl/observium.key 2>/dev/null || true
fi

# Configure Apache SSL site
cat > /etc/apache2/sites-available/observium-ssl.conf <<'APACHEEOF'
<VirtualHost *:443>
    DocumentRoot /opt/observium/html/
    SSLEngine on
    SSLCertificateFile /etc/apache2/ssl/observium.crt
    SSLCertificateKeyFile /etc/apache2/ssl/observium.key
    <Directory "/opt/observium/html/">
        AllowOverride All
        Options FollowSymLinks MultiViews
        Require all granted
    </Directory>
</VirtualHost>
APACHEEOF

# Also create HTTP virtual host (serves on port 80)
cat > /etc/apache2/sites-available/observium-http.conf <<'APACHEEOF'
<VirtualHost *:80>
    DocumentRoot /opt/observium/html/
    <Directory "/opt/observium/html/">
        AllowOverride All
        Options FollowSymLinks MultiViews
        Require all granted
    </Directory>
</VirtualHost>
APACHEEOF

# Enable modules and sites (ignore errors if already enabled)
a2enmod ssl rewrite 2>/dev/null || true
a2enmod headers 2>/dev/null || true
a2dissite 000-default.conf 2>/dev/null || true
a2ensite observium-ssl.conf 2>/dev/null || true
a2ensite observium-http.conf 2>/dev/null || true

# Test Apache configuration
apache2ctl configtest > /dev/null 2>&1 || {
    echo "Warning: Apache configuration test failed, but continuing..."
}

# Start Apache in foreground
source /etc/apache2/envvars
exec apache2 -D FOREGROUND
EOF

chmod +x entrypoint.sh

# ========================================================
# 6. CREATE DOCKER COMPOSE FILE
# ========================================================

echo "--> Creating docker-compose.yml..."
cat <<EOF > docker-compose.yml

services:
  db:
    image: mariadb:10.11
    container_name: observium-db
    restart: always
    # Pi-optimized: Disable native AIO for SD card compatibility
    command: --innodb-use-native-aio=0 --innodb-flush-log-at-trx-commit=2
    environment:
      - MYSQL_ROOT_PASSWORD=${MYSQL_ROOT_PASS}
      - MYSQL_DATABASE=observium
      - MYSQL_USER=observium
      - MYSQL_PASSWORD=${MYSQL_USER_PASS}
      - TZ=UTC
    volumes:
      # DB data on local SD card (fast, no NAS permission issues)
      - ./mysql_data:/var/lib/mysql
    healthcheck:
      test: ["CMD", "mysqladmin", "ping", "-h", "localhost", "-u", "root", "-p${MYSQL_ROOT_PASS}"]
      interval: 10s
      timeout: 5s
      retries: 30
      start_period: 30s

  observium:
    build: .
    container_name: observium-app
    restart: always
    ports:
      - "443:443"
      - "80:80"
    environment:
      - OBSERVIUM_DB_HOST=db
      - OBSERVIUM_DB_NAME=observium
      - OBSERVIUM_DB_USER=observium
      - OBSERVIUM_DB_PASS=${MYSQL_USER_PASS}
      - OBSERVIUM_BASE_URL=https://${CURRENT_IP}
    volumes:
      # RRD and logs on NAS (large files, Docker handles permissions)
      - ${MOUNT_POINT}/container_storage/observium/rrd:/opt/observium/rrd
      - ${MOUNT_POINT}/container_storage/observium/logs:/opt/observium/logs
    depends_on:
      db:
        condition: service_healthy
EOF

# ========================================================
# 7. BUILD AND START CONTAINERS
# ========================================================

echo "--> Building Docker image (this may take several minutes on Pi)..."
sudo docker compose build

echo "--> Starting containers..."
sudo docker compose up -d

# ========================================================
# 8. WAIT FOR DATABASE TO BE READY
# ========================================================

echo "--> Waiting for database to be ready..."
RETRIES=60
DB_READY=0

while [ $RETRIES -gt 0 ]; do
    if sudo docker exec -e MYSQL_PWD="${MYSQL_ROOT_PASS}" observium-db mysqladmin ping -h localhost -u root --silent 2>/dev/null; then
        DB_READY=1
        break
    fi
    echo "    Database starting... ($RETRIES retries left)"
    sleep 5
    RETRIES=$((RETRIES-1))
done

if [ $DB_READY -eq 0 ]; then
    echo "❌ Error: Database failed to start. Checking logs..."
    sudo docker logs observium-db --tail 20
    exit 1
fi

echo "--> Database is ready!"

# ========================================================
# 9. RESTORE DATABASE FROM BACKUP (if exists)
# ========================================================

if [ -f "$DB_DUMP" ]; then
    echo "--> Restoring database from NAS backup..."
    # Use MYSQL_PWD environment variable for non-interactive password
    sudo docker exec -i -e MYSQL_PWD="${MYSQL_ROOT_PASS}" observium-db mysql -u root observium < "$DB_DUMP"
    echo "✅ Database restored from backup"
else
    echo "⚠️  No database backup found at $DB_DUMP"
    echo "   Starting with fresh database..."
fi

# ========================================================
# 10. VERIFY CONTAINERS ARE RUNNING
# ========================================================

echo "--> Verifying containers are running..."
sleep 5
if ! sudo docker ps | grep -q observium-app; then
    echo "❌ Error: Observium container is not running. Checking logs..."
    sudo docker logs observium-app --tail 50 2>&1 || true
    echo ""
    echo "Container may have exited. Attempting to restart..."
    cd "$APP_DIR"
    sudo docker compose restart observium || true
    cd - > /dev/null
    sleep 5
    if ! sudo docker ps | grep -q observium-app; then
        echo "❌ Container failed to start. Please check logs: sudo docker logs observium-app"
        exit 1
    fi
fi

echo "--> Checking Apache status in container..."
sleep 3
if ! sudo docker exec observium-app pgrep apache2 > /dev/null 2>&1; then
    echo "⚠️  Warning: Apache is not running in container. Checking logs..."
    sudo docker logs observium-app --tail 50 2>&1
    echo ""
    echo "Checking Apache configuration..."
    sudo docker exec observium-app apache2ctl configtest 2>&1 || true
    echo ""
    echo "⚠️  Apache may have failed to start. Please check logs above."
else
    echo "✅ Apache is running in container"
fi

# ========================================================
# 11. CREATE ADMIN USER
# ========================================================

echo "--> Creating Observium admin user..."
sleep 5  # Give Observium app a moment to fully start

sudo docker exec observium-app /opt/observium/adduser.php "${OBSERVIUM_ADMIN_USER}" "${OBSERVIUM_ADMIN_PASS}" 10 || {
    echo "⚠️  Warning: Admin user creation may have failed. You can create it manually:"
    echo "   sudo docker exec observium-app /opt/observium/adduser.php admin password 10"
}

# ========================================================
# 12. SETUP CRON JOBS (on host, not container)
# ========================================================

echo "--> Setting up cron jobs..."
cat <<EOF > /etc/cron.d/observium-docker
# Discovery and Polling (run via docker exec)
33  */6   * * * root  sudo docker exec observium-app /opt/observium/observium-wrapper discovery -h all >> ${MOUNT_POINT}/container_storage/observium/logs/cron-discovery-all.log 2>&1
*/5 * * * * root  sudo docker exec observium-app /opt/observium/observium-wrapper discovery -h new >> ${MOUNT_POINT}/container_storage/observium/logs/cron-discovery-new.log 2>&1
*/5 * * * * root  sudo docker exec observium-app /opt/observium/observium-wrapper poller -w 16 >> ${MOUNT_POINT}/container_storage/observium/logs/cron-poller-wrapper.log 2>&1

# Housekeeping
13  5     * * * root  sudo docker exec observium-app /usr/bin/php /opt/observium/housekeeping.php -ysel >> ${MOUNT_POINT}/container_storage/observium/logs/cron-housekeeping-ysel.log 2>&1
47  4     * * * root  sudo docker exec observium-app /usr/bin/php /opt/observium/housekeeping.php -yrptb >> ${MOUNT_POINT}/container_storage/observium/logs/cron-housekeeping-yrptb.log 2>&1

# Daily Database Backup to NAS
0   1     * * * root  sudo docker exec -e MYSQL_PWD='${MYSQL_ROOT_PASS}' observium-db mysqldump -u root observium > ${DB_DUMP}
EOF

systemctl restart cron || true

# ========================================================
# 13. INITIALIZE OBSERVIUM DATABASE
# ========================================================

echo "--> Initializing Observium database schema..."
sudo docker exec observium-app /opt/observium/discovery.php -u

# ========================================================
# COMPLETION
# ========================================================

echo ""
echo "========================================================"
echo "   DEPLOYMENT COMPLETE"
echo "========================================================"
echo "   URL: https://${CURRENT_IP}"
echo "   User: ${OBSERVIUM_ADMIN_USER}"
echo "   Pass: ${OBSERVIUM_ADMIN_PASS}"
echo ""
echo "   Database: Local SD card (${APP_DIR}/mysql_data)"
echo "   RRD/Logs: NAS (${MOUNT_POINT}/container_storage/observium/)"
echo ""
echo "   To view logs: sudo docker logs observium-app"
echo "   To view DB logs: sudo docker logs observium-db"
echo "   To stop: cd ${APP_DIR} && sudo docker compose down"
echo "   To start: cd ${APP_DIR} && sudo docker compose up -d"
echo "========================================================"
