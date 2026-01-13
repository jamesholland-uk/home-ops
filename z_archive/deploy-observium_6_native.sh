#!/bin/bash
# deploy_observium_migrate.sh

set -e

# --- VARIABLES ---
PI_USER="jamoi"
NAS_SERVER="nas2.jamoi.xyz"
NAS_PATH="/nfs/Data"
MOUNT_POINT="/home/${PI_USER}/NAS"
MYSQL_ROOT_PASS="ChangeMeRoot"
MYSQL_USER_PASS="ChangeMeUser"
DB_DUMP="/home/${PI_USER}/observium_devices.sql"

echo "--> Installing Native Dependencies..."
apt-get update && apt-get install -y wget apache2 mariadb-server php php-cli php-mysql \
php-gd php-snmp php-pear php-curl php-mbstring php-xml php-zip \
libapache2-mod-php snmp graphviz rrdtool fping whois nfs-common openssl python3-pymysql

# 1. Mount NAS
mkdir -p "$MOUNT_POINT"
if ! grep -q "$NAS_SERVER" /etc/fstab; then
    echo "$NAS_SERVER:$NAS_PATH $MOUNT_POINT nfs rw,auto,async,_netdev 0 0" >> /etc/fstab
fi
mount -a || true

# 2. Database Setup & Import
systemctl start mariadb
mysql -u root -e "ALTER USER 'root'@'localhost' IDENTIFIED BY '${MYSQL_ROOT_PASS}';"
mysql -u root -p"${MYSQL_ROOT_PASS}" -e "CREATE DATABASE IF NOT EXISTS observium;"
mysql -u root -p"${MYSQL_ROOT_PASS}" -e "GRANT ALL PRIVILEGES ON observium.* TO 'observium'@'localhost' IDENTIFIED BY '${MYSQL_USER_PASS}';"

if [ -f "$DB_DUMP" ]; then
    echo "--> Importing old device list..."
    mysql -u root -p"${MYSQL_ROOT_PASS}" observium < "$DB_DUMP"
else
    echo "⚠️ Warning: $DB_DUMP not found. Starting with empty database."
fi

# 3. Observium Install & NAS Storage Setup
cd /opt
if [ ! -d "/opt/observium" ]; then
    wget http://www.observium.org/observium-community-latest.tar.gz
    tar zxvf observium-community-latest.tar.gz && rm observium-community-latest.tar.gz
fi

# Create target directories on NAS
mkdir -p "$MOUNT_POINT/container_storage/observium/"{logs,rrd}

# Fix Traversal Permissions (The "Nuclear" Fix)
echo "--> Applying Path Traversal and Ownership fixes..."
chmod o+x "/home/${PI_USER}"
chmod o+x "${MOUNT_POINT}"
chmod -R 777 "${MOUNT_POINT}/container_storage/observium/"

# Link NAS storage to Observium folders
rm -rf /opt/observium/rrd /opt/observium/logs
ln -snf "$MOUNT_POINT/container_storage/observium/rrd" /opt/observium/rrd
ln -snf "$MOUNT_POINT/container_storage/observium/logs" /opt/observium/logs

# Set ownership (including the links themselves)
chown -R www-data:www-data /opt/observium
chown -h www-data:www-data /opt/observium/rrd
chown -h www-data:www-data /opt/observium/logs

# 4. HTTPS Setup
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

a2enmod ssl rewrite && a2dissite 000-default.conf && a2ensite observium-ssl.conf
systemctl restart apache2

# 5. Config File
CURRENT_IP=$(hostname -I | awk '{print $1}')
cat <<EOF > /opt/observium/config.php
<?php
\$config['db_extension'] = 'mysqli';
\$config['db_host']      = 'localhost';
\$config['db_user']      = 'observium';
\$config['db_pass']      = '${MYSQL_USER_PASS}';
\$config['db_name']      = 'observium';
\$config['base_url']     = "https://${CURRENT_IP}";
EOF

# 6. Cron Jobs (Running as www-data to match web server permissions)
echo "--> Setting up Cron Polling..."
cat <<EOF > /etc/cron.d/observium
33  */6 * * * www-data /opt/observium/discovery.php -h all >> /dev/null 2>&1
*/5 * * * * www-data /opt/observium/discovery.php -h new >> /dev/null 2>&1
*/5 * * * * www-data /opt/observium/poller-wrapper.py 16 >> /dev/null 2>&1
EOF

# 7. Finalize Schema
cd /opt/observium
# Run as www-data to ensure any files created now have correct ownership
sudo -u www-data ./discovery.php -u

echo "========================================================"
echo "   MIGRATION COMPLETE"
echo "   URL: https://${CURRENT_IP}"
echo "   Note: Your old login credentials were imported."
echo "========================================================"
