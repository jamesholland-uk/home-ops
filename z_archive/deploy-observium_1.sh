#!/bin/bash

# Stop on any error
set -e

echo "========================================================"
echo "   Observium Deployment Script for Raspberry Pi 4 (ARM64)"
echo "========================================================"

# --- VARIABLES (Update these if needed) ---
PI_USER="jamoi"
NAS_SERVER="nas2.jamoi.xyz"
NAS_PATH="/nfs/Data"
MOUNT_POINT="/home/${PI_USER}/NAS"
APP_DIR="/home/${PI_USER}/observium-stack"

# --- PASSWORDS (CHANGE THESE BEFORE RUNNING!) ---
# Use 'openssl rand -base64 12' to generate secure passwords if unsure
MYSQL_ROOT_PASS="ChangeMeRoot"
MYSQL_USER_PASS="ChangeMeUser"
OBSERVIUM_ADMIN_PASS="ChangeMeAdmin"

# ========================================================
# 1. SYSTEM PREP & DOCKER INSTALLATION
# ========================================================
echo "--> Updating system and installing dependencies..."
apt-get update -y
apt-get install -y ca-certificates curl gnupg lsb-release nfs-common

echo "--> Installing Docker..."
# Create keyrings directory
mkdir -p /etc/apt/keyrings
# Remove old key if exists
rm -f /etc/apt/keyrings/docker.gpg

# Download official Docker GPG key
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg

# Set up the repository
echo \
  "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu \
  $(lsb_release -cs) stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null

# Install Docker Engine and the Compose Plugin
apt-get update -y
apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin

echo "--> Adding user $PI_USER to docker group..."
usermod -aG docker "$PI_USER"

# ========================================================
# 2. NAS MOUNT SETUP
# ========================================================
echo "--> Configuring NAS Mount..."

# Create mount point
mkdir -p "$MOUNT_POINT"
chown "$PI_USER":"$PI_USER" "$MOUNT_POINT"

# Add to /etc/fstab if not already present
if ! grep -q "$NAS_SERVER" /etc/fstab; then
    echo "Adding entry to /etc/fstab..."
    echo "$NAS_SERVER:$NAS_PATH $MOUNT_POINT nfs rw,auto,async,_netdev 0 0" >> /etc/fstab
else
    echo "Entry already exists in /etc/fstab, skipping..."
fi

# Mount all filesystems
mount -a

# Create persistent directories on the NAS
echo "--> Creating Observium directories on NAS..."
mkdir -p "$MOUNT_POINT/container_storage/observium/mysql"
mkdir -p "$MOUNT_POINT/container_storage/observium/logs"
mkdir -p "$MOUNT_POINT/container_storage/observium/rrd"

# Fix permissions (MariaDB needs to write)
# We set broad permissions for the data folders to avoid container permission issues
chmod 777 "$MOUNT_POINT/container_storage/observium/mysql"
chmod 777 "$MOUNT_POINT/container_storage/observium/logs"
chmod 777 "$MOUNT_POINT/container_storage/observium/rrd"

# ========================================================
# 3. DEPLOY DOCKER COMPOSE STACK (Updated for Local Build)
# ========================================================
echo "--> creating App Directory: $APP_DIR"
mkdir -p "$APP_DIR"
chown "$PI_USER":"$PI_USER" "$APP_DIR"
cd "$APP_DIR"

# --- Create the Entrypoint Script ---
cat <<'EOF' > entrypoint.sh
#!/bin/bash
cat <<CONF > /opt/observium/config.php
<?php
\$config['db_extension'] = 'mysqli';
\$config['db_host']      = getenv('OBSERVIUM_DB_HOST');
\$config['db_user']      = getenv('OBSERVIUM_DB_USER');
\$config['db_pass']      = getenv('OBSERVIUM_DB_PASS');
\$config['db_name']      = getenv('OBSERVIUM_DB_NAME');
\$config['base_url']     = getenv('OBSERVIUM_BASE_URL');
CONF
source /etc/apache2/envvars
exec apache2 -D FOREGROUND
EOF
chmod +x entrypoint.sh

# --- Create the Dockerfile ---
cat <<EOF > Dockerfile
FROM ubuntu:24.04
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y \\
    wget subversion apache2 php php-cli php-mysql php-gd php-snmp \\
    php-pear snmp graphviz rrdtool fping MariaDB-client \\
    whois python3-mysqldb php-json php-curl php-mbstring libapache2-mod-php
RUN wget http://www.observium.org/observium-community-latest.tar.gz && \\
    tar zxvf observium-community-latest.tar.gz && mv observium /opt/
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh
WORKDIR /opt/observium
ENTRYPOINT ["/entrypoint.sh"]
EOF

echo "--> Generating docker-compose.yml..."
cat <<EOF > docker-compose.yml
version: '3.8'
services:
  db:
    image: mariadb:10.6.4
    container_name: observium-db
    restart: always
    environment:
      - MYSQL_ROOT_PASSWORD=${MYSQL_ROOT_PASS}
      - MYSQL_DATABASE=observium
      - MYSQL_USER=observium
      - MYSQL_PASSWORD=${MYSQL_USER_PASS}
      - TZ=Europe/London
    volumes:
      - ${MOUNT_POINT}/container_storage/observium/mysql:/var/lib/mysql

  observium:
    build: .  # <--- CHANGE: Tells Docker to use the Dockerfile in this folder
    container_name: observium-app
    restart: always
    ports:
      - "8080:80"
    environment:
      - OBSERVIUM_ADMIN_USER=admin
      - OBSERVIUM_ADMIN_PASS=${OBSERVIUM_ADMIN_PASS}
      - OBSERVIUM_DB_HOST=db
      - OBSERVIUM_DB_NAME=observium
      - OBSERVIUM_DB_USER=observium
      - OBSERVIUM_DB_PASS=${MYSQL_USER_PASS}
      - OBSERVIUM_BASE_URL=http://$(hostname -I | awk '{print \$1}'):8080
      - TZ=Europe/London
    volumes:
      - ${MOUNT_POINT}/container_storage/observium/logs:/opt/observium/logs
      - ${MOUNT_POINT}/container_storage/observium/rrd:/opt/observium/rrd
    depends_on:
      - db
    cpuset: "3"
EOF

echo "--> Building and Starting Observium Stack (This may take 5-10 mins on a Pi)..."
docker compose up -d --build


# ========================================================
# 4. OUTPUT TO THE USER
# ========================================================

echo "========================================================"
echo "   DEPLOYMENT COMPLETE!"
echo "========================================================"
echo "1. Observium is running at: http://$(hostname -I | awk '{print $1}'):8080"
echo "2. Default Login: admin / ${OBSERVIUM_ADMIN_PASS}"
echo "3. NOTE: You must log out and log back in for 'docker' group permissions to take effect for your user."
echo "========================================================"
