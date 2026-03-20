#!/bin/bash
set -e

# ========================================================
# Dockge Docker Deployment for Raspberry Pi
# Uses NAS storage for persistent data
# ========================================================

if [ "$EUID" -ne 0 ]; then
    echo "This script must be run as root. Try: sudo $0"
    exit 1
fi

# --- VARIABLES ---
PI_USER="jamoi"
NAS_SERVER="nas2.jamoi.xyz"
NAS_PATH="/nfs/Data"
MOUNT_POINT="/home/${PI_USER}/NAS"
APP_DIR="/home/${PI_USER}/dockge"
STACKS_DIR="/home/${PI_USER}/stacks"
DOCKGE_PORT=5001
CURRENT_IP=$(hostname -I | awk '{print $1}')

echo "========================================================"
echo "   Dockge Docker Deployment"
echo "   Data: NAS | Stacks: Local"
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

# Create directories on NAS for Dockge persistent data
echo "--> Creating Dockge directories on NAS..."
mkdir -p "$MOUNT_POINT/container_storage/dockge/data" || true

# ========================================================
# 3. CREATE APPLICATION DIRECTORY
# ========================================================

mkdir -p "$APP_DIR"
mkdir -p "$STACKS_DIR"
chown "$PI_USER":"$PI_USER" "$APP_DIR"
chown "$PI_USER":"$PI_USER" "$STACKS_DIR"
cd "$APP_DIR"

# ========================================================
# 4. GENERATE SSL CERTIFICATE
# ========================================================

echo "--> Generating SSL certificate for HTTPS..."
mkdir -p "$APP_DIR/ssl" || true
chown "$PI_USER":"$PI_USER" "$APP_DIR/ssl" || true

if [ ! -f "$APP_DIR/ssl/dockge.crt" ]; then
    openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
      -keyout "$APP_DIR/ssl/dockge.key" \
      -out "$APP_DIR/ssl/dockge.crt" \
      -subj "/C=US/ST=State/L=City/O=IT/CN=${CURRENT_IP}" 2>/dev/null || true
    chmod 644 "$APP_DIR/ssl/dockge.crt" 2>/dev/null || true
    chmod 600 "$APP_DIR/ssl/dockge.key" 2>/dev/null || true
    chown "$PI_USER":"$PI_USER" "$APP_DIR/ssl/dockge.crt" "$APP_DIR/ssl/dockge.key" 2>/dev/null || true
    echo "✅ SSL certificate generated"
else
    echo "✅ SSL certificate already exists"
fi

# ========================================================
# 5. VALIDATE PORT AVAILABILITY
# ========================================================

echo "--> Validating port ${DOCKGE_PORT} is available..."
if netstat -tuln 2>/dev/null | grep -q ":${DOCKGE_PORT} " || ss -tuln 2>/dev/null | grep -q ":${DOCKGE_PORT} "; then
    echo "⚠️  Warning: Port ${DOCKGE_PORT} is already in use. Please check and free the port."
    echo "   You can check what's using it with: sudo lsof -i :${DOCKGE_PORT}"
    read -p "Continue anyway? (y/N): " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        echo "Deployment cancelled."
        exit 1
    fi
else
    echo "✅ Port ${DOCKGE_PORT} is available"
fi

# ========================================================
# 6. CREATE NGINX CONFIGURATION FOR SSL
# ========================================================

echo "--> Creating nginx configuration for HTTPS..."
mkdir -p "$APP_DIR/nginx/conf.d" || true
chown "$PI_USER":"$PI_USER" "$APP_DIR/nginx" "$APP_DIR/nginx/conf.d" 2>/dev/null || true

cat <<EOF > "$APP_DIR/nginx/conf.d/dockge.conf"
server {
    listen ${DOCKGE_PORT} ssl http2;
    server_name _;

    ssl_certificate /etc/nginx/ssl/dockge.crt;
    ssl_certificate_key /etc/nginx/ssl/dockge.key;
    
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers HIGH:!aNULL:!MD5;
    ssl_prefer_server_ciphers on;

    location / {
        proxy_pass http://dockge:5001;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header X-Forwarded-Host \$host;
        proxy_set_header X-Forwarded-Port \$server_port;
        
        # WebSocket support (required for Dockge's real-time terminal)
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
    }
}
EOF

chown "$PI_USER":"$PI_USER" "$APP_DIR/nginx/conf.d/dockge.conf" 2>/dev/null || true

# ========================================================
# 7. CREATE DOCKER COMPOSE FILE
# ========================================================

echo "--> Creating docker-compose.yml..."
cat <<EOF > docker-compose.yml
services:
  dockge:
    image: louislam/dockge:1
    container_name: dockge
    restart: unless-stopped
    expose:
      - "5001"
    environment:
      - DOCKGE_STACKS_DIR=/opt/stacks
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
      - ${MOUNT_POINT}/container_storage/dockge/data:/app/data
      - ${STACKS_DIR}:/opt/stacks
    networks:
      - dockge-network

  nginx:
    image: nginx:alpine
    container_name: dockge-nginx
    restart: unless-stopped
    ports:
      - "${DOCKGE_PORT}:${DOCKGE_PORT}"
    volumes:
      - ./nginx/conf.d:/etc/nginx/conf.d:ro
      - ./ssl:/etc/nginx/ssl:ro
    depends_on:
      - dockge
    networks:
      - dockge-network

networks:
  dockge-network:
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
if [ ! -d "${MOUNT_POINT}/container_storage/dockge/data" ]; then
    echo "❌ Error: NAS data directory does not exist: ${MOUNT_POINT}/container_storage/dockge/data"
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
if ! sudo docker ps | grep -q dockge; then
    echo "❌ Error: Dockge container is not running. Checking logs..."
    sudo docker logs dockge --tail 50 2>&1 || true
    echo ""
    echo "Container may have exited. Attempting to restart..."
    cd "$APP_DIR"
    sudo docker compose restart dockge || true
    cd - > /dev/null
    sleep 5
    if ! sudo docker ps | grep -q dockge; then
        echo "❌ Container failed to start. Please check logs: sudo docker logs dockge"
        exit 1
    fi
fi

if ! sudo docker ps | grep -q dockge-nginx; then
    echo "❌ Error: Nginx container is not running. Checking logs..."
    sudo docker logs dockge-nginx --tail 50 2>&1 || true
    echo ""
    echo "Container may have exited. Attempting to restart..."
    cd "$APP_DIR"
    sudo docker compose restart nginx || true
    cd - > /dev/null
    sleep 5
    if ! sudo docker ps | grep -q dockge-nginx; then
        echo "❌ Container failed to start. Please check logs: sudo docker logs dockge-nginx"
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
echo "   HTTPS URL: https://${CURRENT_IP}:${DOCKGE_PORT}"
echo ""
echo "   Data: NAS (${MOUNT_POINT}/container_storage/dockge/data)"
echo "   Stacks: Local (${STACKS_DIR})"
echo "   SSL Certs: ${APP_DIR}/ssl"
echo ""
echo "   NOTE: On first access, Dockge will ask you to create"
echo "         an admin account via the web interface."
echo ""
echo "   To view logs:"
echo "     - Dockge: sudo docker logs dockge"
echo "     - Nginx: sudo docker logs dockge-nginx"
echo "   To stop: cd ${APP_DIR} && sudo docker compose down"
echo "   To start: cd ${APP_DIR} && sudo docker compose up -d"
echo "   To restart: cd ${APP_DIR} && sudo docker compose restart"
echo "========================================================"
