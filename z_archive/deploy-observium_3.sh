#!/bin/bash
# deploy_observium.sh

# Stop on any error
set -e

echo "========================================================"
echo "   Observium: System Prep + Custom Build"
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
echo "--> Installing Docker Engine and Compose Plugin..."
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
# Caused issues: chown "$PI_USER":"$PI_USER" "$MOUNT_POINT"

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
mkdir -p "$MOUNT_POINT/container_storage/observium/"{mysql,logs,rrd} || true

# Applying the broad permissions to bypass Root Squash issues
chmod -R 777 "$MOUNT_POINT/container_storage/observium/" || true


# ========================================================
# 3. BUILD FILES & DEPLOYMENT
# ========================================================

mkdir -p "$APP_DIR"
chown "$PI_USER":"$PI_USER" "$APP_DIR"
cd "$APP_DIR"

echo "--> Writing Dockerfile and entrypoint script..."

# --- Entrypoint Script ---
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

# --- Dockerfile (Ubuntu 24.04 ARM64 Native) ---
cat <<EOF > Dockerfile
FROM ubuntu:24.04
ENV DEBIAN_FRONTEND=noninteractive

# 1. Install dependencies (Corrected package names)
RUN apt-get update && apt-get install -y \\
    wget \\
    subversion \\
    apache2 \\
    php \\
    php-cli \\
    php-mysql \\
    php-gd \\
    php-snmp \\
    php-pear \\
    php-curl \\
    php-mbstring \\
    php-xml \\
    php-zip \\
    libapache2-mod-php \\
    snmp \\
    graphviz \\
    rrdtool \\
    fping \\
    mariadb-client \\
    whois \\
    python3-mysqldb \\
    ca-certificates

# 2. Download and Extract Observium
RUN wget http://www.observium.org/observium-community-latest.tar.gz && \\
    tar zxvf observium-community-latest.tar.gz && \\
    mv observium /opt/ && \\
    rm observium-community-latest.tar.gz

# 3. Final Setup
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh
WORKDIR /opt/observium
ENTRYPOINT ["/entrypoint.sh"]
EOF

echo "--> Generating docker-compose.yml..."
cat <<EOF > docker-compose.yml

services:
  db:
    image: mariadb:10.6
    container_name: observium-db
    restart: always
    # Fix for potential storage locking issues
    command: --innodb-use-native-aio=0
    environment:
      - MYSQL_ROOT_PASSWORD=${MYSQL_ROOT_PASS}
      - MYSQL_DATABASE=observium
      - MYSQL_USER=observium
      - MYSQL_PASSWORD=${MYSQL_USER_PASS}
    volumes:
      # Stored locally for stability
      - ./mysql_data:/var/lib/mysql

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
    volumes:
      # KEPT ON NAS: These are the large files
      - ${MOUNT_POINT}/container_storage/observium/logs:/opt/observium/logs
      - ${MOUNT_POINT}/container_storage/observium/rrd:/opt/observium/rrd
    depends_on:
      - db
    cpuset: "3"

EOF


# ========================================================
# 4. BUILD AND LAUNCH
# ========================================================

echo "--> Building local image and launching stack (this takes time)..."
docker compose up -d --build


# ========================================================
# 5. INITIAL USER CREATION
# ========================================================

echo "--> Checking Database status..."

RETRIES=15
# Check if the database is accepting connections
until docker exec observium-db mariadb-admin ping -u root -p${MYSQL_ROOT_PASS} >/dev/null 2>&1 || [ $RETRIES -eq 0 ]; do
  echo "    Database starting up... waiting ($RETRIES retries left)"
  sleep 10
  RETRIES=$((RETRIES-1))
done

if [ $RETRIES -eq 0 ]; then
    echo "❌ Error: Database failed to initialize. Here are the last 10 lines of logs:"
    docker logs observium-db --tail 10
    exit 1
fi

echo "--> Database is up! Creating Admin User..."
# Running the user creation
# This command runs the official Observium script inside the container
docker exec -it observium-app /opt/observium/adduser.php ${OBSERVIUM_ADMIN_USER} ${OBSERVIUM_ADMIN_PASS} 10


# ========================================================
# 6. COMPLETION
# ========================================================

echo "========================================================"
echo "   DEPLOYMENT COMPLETE"
echo "   URL: http://$(hostname -I | awk '{print $1}'):8080"
echo "   User: ${OBSERVIUM_ADMIN_USER}"
echo "   Pass: ${OBSERVIUM_ADMIN_PASS}"
echo "========================================================"
