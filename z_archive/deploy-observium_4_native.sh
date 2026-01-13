#!/bin/bash
# deploy_native_https.sh

set -e

echo "========================================================"
echo "   Observium: Native HTTPS Deployment"
echo "========================================================"

# --- VARIABLES ---
PI_USER="jamoi"
NAS_SERVER="nas2.jamoi.xyz"
NAS_PATH="/nfs/Data"
MOUNT_POINT="/home/${PI_USER}/NAS"

# --- CREDENTIALS ---
MYSQL_ROOT_PASS="ChangeMeRoot"
MYSQL_USER_PASS="ChangeMeUser"
OBSERVIUM_ADMIN_USER="admin"
OBSERVIUM_ADMIN_PASS="ChangeMeAdmin"

# ========================================================
# 1. CLEAN DOCKER REMNANTS
# ========================================================
echo "--> Removing Docker remnants..."
docker compose -f /home/${PI_USER}/observium-stack/docker-compose.yml down --volumes || true
apt-get purge -y docker-ce docker-ce-cli containerd.io docker-compose-plugin || true
rm -rf /var/lib/docker /etc/apt/sources.list.d/docker.list /home/${PI_USER}/observium-stack

# ========================================================
# 2. SYSTEM INSTALLATION
# ========================================================
echo "--> Installing Native Dependencies..."
apt-get update
apt-get install -y wget apache2 mariadb-server php php-cli php-mysql \
php-gd php-snmp php-pear php-curl php-mbstring php-xml php-zip \
libapache2-mod-php snmp graphviz rrdtool fping whois nfs-common openssl

# ========================================================
# 3. STORAGE & DATABASE
# ========================================================
echo "--> Mounting NAS and Setting up Database..."
mkdir -p "$MOUNT_POINT"
if ! grep -q "$NAS_SERVER" /etc/fstab; then
    echo "$NAS_SERVER:$NAS_PATH $MOUNT_POINT nfs rw,auto,async,_netdev 0 0" >> /etc/fstab
fi
mount -a || true

# Local DB Setup
systemctl start mariadb
mysql -u root -e "ALTER USER 'root'@'localhost' IDENTIFIED BY '${MYSQL_ROOT_PASS}';"
mysql -u root -p"${MYSQL_ROOT_PASS}" -e "CREATE DATABASE IF NOT EXISTS observium;"
mysql -u root -p"${MYSQL_ROOT_PASS}" -e "GRANT ALL PRIVILEGES ON observium.* TO 'observium'@'localhost' IDENTIFIED BY '${MYSQL_USER_PASS}';"

# ========================================================
# 4. OBSERVIUM & NAS LINKING
# ========================================================
cd /opt
if [ ! -d "/opt/observium" ]; then
    wget http://www.observium.org/observium-community-latest.tar.gz
    tar zxvf observium-community-latest.tar.gz && rm observium-community-latest.tar.gz
fi

mkdir -p "$MOUNT_POINT/container_storage/observium/"{logs,rrd}
rm -rf /opt/observium/rrd /opt/observium/logs
ln -s "$MOUNT_POINT/container_storage/observium/rrd" /opt/observium/rrd
ln -s "$MOUNT_POINT/container_storage/observium/logs" /opt/observium/logs
chown -R www-data:www-data /opt/observium

# ========================================================
# 5. HTTPS/SSL CONFIGURATION
# ========================================================
echo "--> Configuring HTTPS (Port 443)..."
mkdir -p /etc/apache2/ssl
openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
  -keyout /etc/apache2/ssl/observium.key \
  -out /etc/apache2/ssl/observium.crt \
  -subj "/C=US/ST=State/L=City/O=IT/CN=$(hostname -I | awk '{print $1}')"

cat <<EOF > /etc/apache2/sites-available/observium-ssl.conf
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
EOF

a2enmod ssl rewrite
a2dissite 000-default.conf
a2ensite observium-ssl.conf
systemctl restart apache2

# ========================================================
# 6. CONFIG & CRON JOBS
# ========================================================
cat <<EOF > /opt/observium/config.php
<?php
\$config['db_extension'] = 'mysqli';
\$config['db_host']      = 'localhost';
\$config['db_user']      = 'observium';
\$config['db_pass']      = '${MYSQL_USER_PASS}';
\$config['db_name']      = 'observium';
\$config['base_url']     = "https://$(hostname -I | awk '{print \$1}')";
EOF

echo "--> Setting up Cron Polling Schedule..."
cat <<EOF > /etc/cron.d/observium
# Run discovery for all devices every 6 hours
33  */6 * * * root /opt/observium/discovery.php -h all >> /dev/null 2>&1
# Run discovery for newly added devices every 5 minutes
*/5 * * * * root /opt/observium/discovery.php -h new >> /dev/null 2>&1
# Run poller for all devices every 5 minutes
*/5 * * * * root /opt/observium/poller-wrapper.py 16 >> /dev/null 2>&1
EOF

# ========================================================
# 7. INITIALIZE
# ========================================================
cd /opt/observium
./discovery.php -u
./adduser.php ${OBSERVIUM_ADMIN_USER} ${OBSERVIUM_ADMIN_PASS} 10

echo "========================================================"
echo "   DEPLOYMENT COMPLETE (NATIVE HTTPS)"
echo "   URL: https://$(hostname -I | awk '{print $1}')"
echo "========================================================"
