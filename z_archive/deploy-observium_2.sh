#!/bin/bash
# deploy_observium_custom.sh

set -e

echo "========================================================"
echo "   Observium Custom Build: Ubuntu 24.04 + Latest Source"
echo "========================================================"

# --- VARIABLES ---
PI_USER="jamoi"
NAS_SERVER="nas2.jamoi.xyz"
NAS_PATH="/nfs/Data"
MOUNT_POINT="/home/${PI_USER}/NAS"
APP_DIR="/home/${PI_USER}/observium-stack"

# --- LOGIN CREDENTIALS ---
MYSQL_ROOT_PASS="ChangeMeRoot"
MYSQL_USER_PASS="ChangeMeUser"
OBSERVIUM_ADMIN_USER="admin"
OBSERVIUM_ADMIN_PASS="ChangeMeAdmin"

# 1. SYSTEM & NAS SETUP (Standard tasks)
apt-get update -y && apt-get install -y nfs-common docker-ce docker-compose-plugin
mkdir -p "$MOUNT_POINT"
if ! grep -q "$NAS_SERVER" /etc/fstab; then
    echo "$NAS_SERVER:$NAS_PATH $MOUNT_POINT nfs rw,auto,async,_netdev 0 0" >> /etc/fstab
fi
mount -a

# Create NAS storage paths
mkdir -p "$MOUNT_POINT/container_storage/observium/"{mysql,logs,rrd}
chmod -R 777 "$MOUNT_POINT/container_storage/observium/"

# 2. CREATE BUILD FILES
mkdir -p "$APP_DIR"
cd "$APP_DIR"

echo "--> Writing Build Files..."

# --- Create Entrypoint ---
cat <<'EOF' > entrypoint.sh
#!/bin/bash
# Generate config.php
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

# --- Create Dockerfile ---
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

# --- Create Docker Compose ---
cat <<EOF > docker-compose.yml
services:
  db:
    image: mariadb:10.6
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
    build: .
    container_name: observium-app
    restart: always
    ports:
      - "8080:80"
    environment:
      - OBSERVIUM_DB_HOST=db
      - OBSERVIUM_DB_NAME=observium
      - OBSERVIUM_DB_USER=observium
      - OBSERVIUM_DB_PASS=${MYSQL_USER_PASS}
      - OBSERVIUM_BASE_URL=http://$(hostname -I | awk '{print $1}'):8080
      - TZ=Europe/London
    volumes:
      - ${MOUNT_POINT}/container_storage/observium/logs:/opt/observium/logs
      - ${MOUNT_POINT}/container_storage/observium/rrd:/opt/observium/rrd
    depends_on:
      - db
    cpuset: "3"
EOF

# 3. BUILD AND LAUNCH
echo "--> Building local ARM64 image (This takes time)..."
docker compose up -d --build

# 4. INITIAL USER CREATION
echo "--> Waiting for Database to initialize..."
sleep 20 # Give MariaDB time to start on the NAS

echo "--> Creating Admin User..."
# This command runs the official Observium script inside the container
docker exec -it observium-app /opt/observium/adduser.php ${OBSERVIUM_ADMIN_USER} ${OBSERVIUM_ADMIN_PASS} 10

echo "========================================================"
echo "   DEPLOYMENT COMPLETE"
echo "   URL: http://$(hostname -I | awk '{print $1}'):8080"
echo "   User: ${OBSERVIUM_ADMIN_USER}"
echo "   Pass: ${OBSERVIUM_ADMIN_PASS}"
echo "========================================================"