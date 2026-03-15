#!/bin/bash
set -e

# ========================================================
# Smokeping Docker Deployment for Raspberry Pi
# Uses NAS storage for config and data persistence
# ========================================================

# --- VARIABLES ---
PI_USER="jamoi"
NAS_SERVER="nas2.jamoi.xyz"
NAS_PATH="/nfs/Data"
MOUNT_POINT="/home/${PI_USER}/NAS"
APP_DIR="/home/${PI_USER}/smokeping"
CURRENT_IP=$(hostname -I | awk '{print $1}')

# Dynamically get PUID and PGID for the user
PUID=$(id -u "$PI_USER")
PGID=$(id -g "$PI_USER")
TZ="Europe/London"

echo "========================================================"
echo "   Smokeping Docker Deployment"
echo "   Config/Data: NAS"
echo "========================================================"

# ========================================================
# 1. SYSTEM PREP & DOCKER INSTALLATION
# ========================================================

echo "--> Updating system and installing dependencies..."
apt-get update -y
apt-get install -y ca-certificates curl gnupg lsb-release nfs-common openssl

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
# 2. NAS MOUNT SETUP
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
echo "--> Creating Smokeping directories on NAS..."
mkdir -p "$MOUNT_POINT/container_storage/smokeping/config" || true
mkdir -p "$MOUNT_POINT/container_storage/smokeping/data" || true

# Create SSL directory for certificates
mkdir -p "$APP_DIR/ssl" || true
chown "$PI_USER":"$PI_USER" "$APP_DIR/ssl" || true

# Note: We don't chmod here - Docker volumes handle permissions automatically

# ========================================================
# 3. CREATE APPLICATION DIRECTORY
# ========================================================

mkdir -p "$APP_DIR"
chown "$PI_USER":"$PI_USER" "$APP_DIR"
cd "$APP_DIR"

# ========================================================
# 4. GENERATE SSL CERTIFICATE
# ========================================================

echo "--> Generating SSL certificate for HTTPS..."
if [ ! -f "$APP_DIR/ssl/smokeping.crt" ]; then
    openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
      -keyout "$APP_DIR/ssl/smokeping.key" \
      -out "$APP_DIR/ssl/smokeping.crt" \
      -subj "/C=US/ST=State/L=City/O=IT/CN=${CURRENT_IP}" 2>/dev/null || true
    chmod 644 "$APP_DIR/ssl/smokeping.crt" 2>/dev/null || true
    chmod 600 "$APP_DIR/ssl/smokeping.key" 2>/dev/null || true
    chown "$PI_USER":"$PI_USER" "$APP_DIR/ssl/smokeping.crt" "$APP_DIR/ssl/smokeping.key" 2>/dev/null || true
    echo "✅ SSL certificate generated"
else
    echo "✅ SSL certificate already exists"
fi

# ========================================================
# 5. VALIDATE PORT AVAILABILITY
# ========================================================

echo "--> Validating port 8223 is available..."
if netstat -tuln 2>/dev/null | grep -q ":8223 " || ss -tuln 2>/dev/null | grep -q ":8223 "; then
    echo "⚠️  Warning: Port 8223 is already in use. Please check and free the port."
    echo "   You can check what's using it with: sudo lsof -i :8223"
    read -p "Continue anyway? (y/N): " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        echo "Deployment cancelled."
        exit 1
    fi
else
    echo "✅ Port 8223 is available"
fi

# ========================================================
# 6. CREATE NGINX CONFIGURATION FOR SSL
# ========================================================

echo "--> Creating nginx configuration for HTTPS..."
mkdir -p "$APP_DIR/nginx/conf.d" || true
chown "$PI_USER":"$PI_USER" "$APP_DIR/nginx" "$APP_DIR/nginx/conf.d" 2>/dev/null || true

cat <<EOF > "$APP_DIR/nginx/conf.d/smokeping.conf"
server {
    listen 8223 ssl http2;
    server_name _;

    ssl_certificate /etc/nginx/ssl/smokeping.crt;
    ssl_certificate_key /etc/nginx/ssl/smokeping.key;
    
    # SSL configuration
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers HIGH:!aNULL:!MD5;
    ssl_prefer_server_ciphers on;

    # Proxy to smokeping container
    location / {
        proxy_pass http://smokeping:80;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header X-Forwarded-Host \$host;
        proxy_set_header X-Forwarded-Port \$server_port;
        
        # WebSocket support (if needed)
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
    }
}
EOF

chown "$PI_USER":"$PI_USER" "$APP_DIR/nginx/conf.d/smokeping.conf" 2>/dev/null || true

# ========================================================
# 7. CREATE DOCKER COMPOSE FILE
# ========================================================

echo "--> Creating docker-compose.yml..."
cat <<EOF > docker-compose.yml
services:
  smokeping:
    image: lscr.io/linuxserver/smokeping:latest
    container_name: smokeping
    restart: unless-stopped
    # Don't expose ports directly - nginx will proxy
    expose:
      - "80"
    environment:
      - PUID=${PUID}
      - PGID=${PGID}
      - TZ=${TZ}
    volumes:
      # Config and data on NAS (Docker handles permissions)
      - ${MOUNT_POINT}/container_storage/smokeping/config:/config
      - ${MOUNT_POINT}/container_storage/smokeping/data:/data
    networks:
      - smokeping-network

  nginx:
    image: nginx:alpine
    container_name: smokeping-nginx
    restart: unless-stopped
    ports:
      - "8223:8223"
    volumes:
      - ./nginx/conf.d:/etc/nginx/conf.d:ro
      - ./ssl:/etc/nginx/ssl:ro
    depends_on:
      - smokeping
    networks:
      - smokeping-network

networks:
  smokeping-network:
    driver: bridge
EOF

# ========================================================
# 8. VALIDATE DOCKER COMPOSE FILE
# ========================================================

echo "--> Validating docker-compose.yml syntax..."
if sudo docker compose config > /dev/null 2>&1; then
    echo "✅ Docker Compose file is valid"
else
    echo "❌ Error: Docker Compose file validation failed"
    echo "Checking syntax..."
    sudo docker compose config
    exit 1
fi

# ========================================================
# 9. VERIFY NAS PATHS EXIST
# ========================================================

echo "--> Verifying NAS paths exist..."
if [ ! -d "${MOUNT_POINT}/container_storage/smokeping/config" ]; then
    echo "❌ Error: NAS config directory does not exist: ${MOUNT_POINT}/container_storage/smokeping/config"
    exit 1
fi

if [ ! -d "${MOUNT_POINT}/container_storage/smokeping/data" ]; then
    echo "❌ Error: NAS data directory does not exist: ${MOUNT_POINT}/container_storage/smokeping/data"
    exit 1
fi

echo "✅ NAS paths verified"

# ========================================================
# 10. PULL IMAGES AND START CONTAINERS
# ========================================================

echo "--> Pulling Docker images (this may take a few minutes on Pi)..."
sudo docker compose pull

echo "--> Starting containers..."
sudo docker compose up -d

# ========================================================
# 11. VERIFY CONTAINERS ARE RUNNING
# ========================================================

echo "--> Verifying containers are running..."
sleep 5
if ! sudo docker ps | grep -q smokeping; then
    echo "❌ Error: Smokeping container is not running. Checking logs..."
    sudo docker logs smokeping --tail 50 2>&1 || true
    echo ""
    echo "Container may have exited. Attempting to restart..."
    cd "$APP_DIR"
    sudo docker compose restart smokeping || true
    cd - > /dev/null
    sleep 5
    if ! sudo docker ps | grep -q smokeping; then
        echo "❌ Container failed to start. Please check logs: sudo docker logs smokeping"
        exit 1
    fi
fi

if ! sudo docker ps | grep -q smokeping-nginx; then
    echo "❌ Error: Nginx container is not running. Checking logs..."
    sudo docker logs smokeping-nginx --tail 50 2>&1 || true
    echo ""
    echo "Container may have exited. Attempting to restart..."
    cd "$APP_DIR"
    sudo docker compose restart nginx || true
    cd - > /dev/null
    sleep 5
    if ! sudo docker ps | grep -q smokeping-nginx; then
        echo "❌ Container failed to start. Please check logs: sudo docker logs smokeping-nginx"
        exit 1
    fi
fi

echo "✅ Containers are running"

# ========================================================
# COMPLETION
# ========================================================

echo ""
echo "========================================================"
echo "   DEPLOYMENT COMPLETE"
echo "========================================================"
echo "   HTTPS URL: https://${CURRENT_IP}:8223"
echo ""
echo "   Config: NAS (${MOUNT_POINT}/container_storage/smokeping/config)"
echo "   Data: NAS (${MOUNT_POINT}/container_storage/smokeping/data)"
echo "   SSL Certs: ${APP_DIR}/ssl"
echo ""
echo "   PUID: ${PUID} (User: ${PI_USER})"
echo "   PGID: ${PGID}"
echo "   TZ: ${TZ}"
echo ""
echo "   To view logs:"
echo "     - Smokeping: sudo docker logs smokeping"
echo "     - Nginx: sudo docker logs smokeping-nginx"
echo "   To stop: cd ${APP_DIR} && sudo docker compose down"
echo "   To start: cd ${APP_DIR} && sudo docker compose up -d"
echo "   To restart: cd ${APP_DIR} && sudo docker compose restart"
echo "========================================================"
