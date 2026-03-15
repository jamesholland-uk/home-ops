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
SLACK_WEBHOOK_URL="${SLACK_WEBHOOK_URL:-https://hooks.slack.com/services/CHANGE/ME/PLEASE}"
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

# soft mount prevents system-wide hangs if NAS becomes unreachable
NFS_OPTS="nfs rw,soft,timeo=50,retrans=3,async,_netdev 0 0"
NFS_LINE="$NAS_SERVER:$NAS_PATH $MOUNT_POINT $NFS_OPTS"

if grep -q "$NAS_SERVER" /etc/fstab; then
    echo "Updating existing NAS entry in /etc/fstab..."
    sed -i "\|$NAS_SERVER|c\\$NFS_LINE" /etc/fstab
else
    echo "Adding NAS entry to /etc/fstab..."
    echo "$NFS_LINE" >> /etc/fstab
fi

mount -a || true

# Create directories on NAS (Docker will handle permissions)
echo "--> Creating Observium directories on NAS..."
mkdir -p "$MOUNT_POINT/container_storage/observium/"{logs,rrd,backups} || true

# Note: We don't chmod here - Docker volumes handle permissions automatically

# ========================================================
# 2.5. CREATE SWAP FILE (safety net for memory pressure)
# ========================================================

SWAP_FILE="/swapfile"
SWAP_SIZE="1G"

if [ ! -f "$SWAP_FILE" ]; then
    echo "--> Creating ${SWAP_SIZE} swap file..."
    fallocate -l "$SWAP_SIZE" "$SWAP_FILE"
    chmod 600 "$SWAP_FILE"
    mkswap "$SWAP_FILE"
    swapon "$SWAP_FILE"
    if ! grep -q "$SWAP_FILE" /etc/fstab; then
        echo "$SWAP_FILE none swap sw 0 0" >> /etc/fstab
    fi
    echo "Swap enabled: ${SWAP_SIZE}"
else
    echo "--> Swap file already exists, ensuring it's active..."
    swapon "$SWAP_FILE" 2>/dev/null || true
fi

# ========================================================
# 2.6. CONFIGURE SNMP ON HOST
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
mkdir -p /var/log/observium

cat <<EOF > /etc/cron.d/observium-docker
SHELL=/bin/bash

# flock -n: skip if previous run still active (prevents pile-up)
# timeout: kill if hung (prevents infinite NFS stalls)
# Logs go to local disk, not NAS, so logging itself can't hang

# Discovery - all hosts (every 6h, 30min timeout)
33  */6   * * * root  flock -n /tmp/observium-discovery-all.lock timeout 1800 sudo docker exec observium-app /opt/observium/observium-wrapper discovery --host all >> /var/log/observium/discovery-all.log 2>&1

# Discovery - new hosts (every 5min, 4min timeout)
*/5 * * * * root  flock -n /tmp/observium-discovery-new.lock timeout 240 sudo docker exec observium-app /opt/observium/observium-wrapper discovery --host new >> /var/log/observium/discovery-new.log 2>&1

# Poller (every 5min, 4min timeout)
*/5 * * * * root  flock -n /tmp/observium-poller.lock timeout 240 sudo docker exec observium-app /opt/observium/observium-wrapper poller -w 16 >> /var/log/observium/poller.log 2>&1

# Housekeeping (daily, 1h timeout)
13  5     * * * root  timeout 3600 sudo docker exec observium-app /usr/bin/php /opt/observium/housekeeping.php -ysel >> /var/log/observium/housekeeping.log 2>&1
47  4     * * * root  timeout 3600 sudo docker exec observium-app /usr/bin/php /opt/observium/housekeeping.php -yrptb >> /var/log/observium/housekeeping.log 2>&1

# Daily DB backup: dump locally first, then copy to NAS (avoids NFS hang during redirect)
0   1     * * * root  timeout 300 sudo docker exec -e MYSQL_PWD='${MYSQL_ROOT_PASS}' observium-db mysqldump -u root observium > /tmp/observium_backup.sql && timeout 60 cp /tmp/observium_backup.sql ${DB_DUMP} >> /var/log/observium/backup.log 2>&1
EOF

systemctl restart cron || true

# ========================================================
# 12.5. HEALTH CHECK SCRIPT WITH SLACK ALERTS
# ========================================================

echo "--> Installing health check script..."

cat <<'HEALTHEOF' > /usr/local/bin/observium-healthcheck.sh
#!/bin/bash
STATE_DIR="/var/run/observium-health"
mkdir -p "$STATE_DIR"

WEBHOOK_URL="__SLACK_WEBHOOK__"
HOSTNAME=$(hostname)
PROBLEMS=()

# --- Check NFS mount ---
if ! timeout 10 stat /home/jamoi/NAS > /dev/null 2>&1; then
    PROBLEMS+=("NFS mount /home/jamoi/NAS is unresponsive")
fi

# --- Check Docker containers ---
for ctr in observium-app observium-db; do
    if ! docker ps --format '{{.Names}}' | grep -q "^${ctr}$"; then
        PROBLEMS+=("Container ${ctr} is not running")
    fi
done

# --- Check swap usage (>50% = memory pressure warning) ---
SWAP_TOTAL=$(free -m | awk '/Swap:/ {print $2}')
SWAP_USED=$(free -m | awk '/Swap:/ {print $3}')
if [ "$SWAP_TOTAL" -gt 0 ] 2>/dev/null; then
    SWAP_PCT=$(( SWAP_USED * 100 / SWAP_TOTAL ))
    if [ "$SWAP_PCT" -gt 50 ]; then
        PROBLEMS+=("Swap usage is ${SWAP_PCT}% (${SWAP_USED}MB/${SWAP_TOTAL}MB) — possible memory pressure")
    fi
fi

# --- Check SD card usage (>85%) ---
DISK_PCT=$(df / --output=pcent | tail -1 | tr -d ' %')
if [ "$DISK_PCT" -gt 85 ] 2>/dev/null; then
    PROBLEMS+=("SD card usage is ${DISK_PCT}%")
fi

# --- Alert logic: only notify on state changes ---
CURRENT_STATE="healthy"
if [ ${#PROBLEMS[@]} -gt 0 ]; then
    CURRENT_STATE="unhealthy"
fi

PREV_STATE="healthy"
[ -f "$STATE_DIR/state" ] && PREV_STATE=$(cat "$STATE_DIR/state")

if [ "$CURRENT_STATE" = "unhealthy" ] && [ "$PREV_STATE" = "healthy" ]; then
    DETAIL=$(printf '• %s\\n' "${PROBLEMS[@]}")
    PAYLOAD=$(cat <<JSON
{"text":":rotating_light: *Observium Health Alert — ${HOSTNAME}*\n${DETAIL}\nTimestamp: $(date '+%Y-%m-%d %H:%M:%S %Z')"}
JSON
)
    curl -s -X POST -H 'Content-type: application/json' --data "$PAYLOAD" "$WEBHOOK_URL" > /dev/null 2>&1
    echo "$(date) ALERT: ${PROBLEMS[*]}" >> /var/log/observium/healthcheck.log

elif [ "$CURRENT_STATE" = "healthy" ] && [ "$PREV_STATE" = "unhealthy" ]; then
    PAYLOAD=$(cat <<JSON
{"text":":white_check_mark: *Observium Recovered — ${HOSTNAME}*\nAll checks passing.\nTimestamp: $(date '+%Y-%m-%d %H:%M:%S %Z')"}
JSON
)
    curl -s -X POST -H 'Content-type: application/json' --data "$PAYLOAD" "$WEBHOOK_URL" > /dev/null 2>&1
    echo "$(date) RECOVERED" >> /var/log/observium/healthcheck.log
fi

echo "$CURRENT_STATE" > "$STATE_DIR/state"
HEALTHEOF

# Inject the actual webhook URL
sed -i "s|__SLACK_WEBHOOK__|${SLACK_WEBHOOK_URL}|" /usr/local/bin/observium-healthcheck.sh
chmod +x /usr/local/bin/observium-healthcheck.sh

# Add health check to cron (every 5 minutes)
cat <<'HCEOF' >> /etc/cron.d/observium-docker

# Health check with Slack alerts (every 5min)
*/5 * * * * root  /usr/local/bin/observium-healthcheck.sh
HCEOF

systemctl restart cron || true
echo "Health check installed with Slack notifications"

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
