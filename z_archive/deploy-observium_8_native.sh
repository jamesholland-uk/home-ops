#!/bin/bash
set -e

# --- VARIABLES ---
PI_USER="jamoi"
NAS_SERVER="nas2.jamoi.xyz"
NAS_PATH="/nfs/Data"
MOUNT_POINT="/home/${PI_USER}/NAS"
MYSQL_ROOT_PASS="ChangeMeRoot"
MYSQL_USER_PASS="ChangeMeUser"
DB_DUMP="${MOUNT_POINT}/container_storage/observium/backups/observium_devices.sql"
CURRENT_IP=$(hostname -I | awk '{print $1}')
LOG_PATH="/Users/jamoi/code/home-ops/.cursor/debug.log"
mkdir -p "$(dirname "$LOG_PATH")" 2>/dev/null || true

echo "--> Installing Native Dependencies..."
apt-get update && apt-get install -y wget apache2 mariadb-server php php-cli php-mysql \
php-gd php-snmp php-pear php-curl php-mbstring php-xml php-zip \
libapache2-mod-php snmp graphviz rrdtool fping whois nfs-common openssl python3-pymysql logrotate

# 1. Mount NAS
mkdir -p "$MOUNT_POINT"
if ! grep -q "$NAS_SERVER" /etc/fstab; then
    echo "$NAS_SERVER:$NAS_PATH $MOUNT_POINT nfs rw,auto,async,_netdev 0 0" >> /etc/fstab
fi
mount -a || true

# 2. Python Symlink Fix (Crucial for wrapper)
if [ ! -f /usr/bin/python ]; then
    ln -s /usr/bin/python3 /usr/bin/python
fi

# 3. Database Setup
systemctl start mariadb

# #region agent log
echo '{"sessionId":"debug-session","runId":"db-setup","hypothesisId":"H1","location":"deploy-observium_8_native.sh:32","message":"Checking root auth without password","data":{"attempt":"no-pass"},"timestamp":'$(date +%s%3N)'}' >> "$LOG_PATH" 2>/dev/null || true
# #endregion
if mysql -u root -e "SELECT 1" >/dev/null 2>&1; then
    ROOT_AUTH="nopass"
else
    # #region agent log
    echo '{"sessionId":"debug-session","runId":"db-setup","hypothesisId":"H1","location":"deploy-observium_8_native.sh:36","message":"No-pass auth failed, trying provided password","data":{"attempt":"with-pass"},"timestamp":'$(date +%s%3N)'}' >> "$LOG_PATH" 2>/dev/null || true
    # #endregion
    if mysql -u root -p"${MYSQL_ROOT_PASS}" -e "SELECT 1" >/dev/null 2>&1; then
        ROOT_AUTH="withpass"
    else
        # #region agent log
        echo '{"sessionId":"debug-session","runId":"db-setup","hypothesisId":"H2","location":"deploy-observium_8_native.sh:40","message":"Both auth attempts failed; aborting","data":{"attempts":["no-pass","with-pass"]},"timestamp":'$(date +%s%3N)'}' >> "$LOG_PATH" 2>/dev/null || true
        # #endregion
        echo "ERROR: Cannot authenticate to MariaDB as root with or without the provided password. Set MYSQL_ROOT_PASS to the current root password or reset manually, then re-run."
        exit 1
    fi
fi

# #region agent log
echo '{"sessionId":"debug-session","runId":"db-setup","hypothesisId":"H1","location":"deploy-observium_8_native.sh:48","message":"Detected root auth mode","data":{"root_auth":"'"${ROOT_AUTH}"'"},"timestamp":'$(date +%s%3N)'}' >> "$LOG_PATH" 2>/dev/null || true
# #endregion

if [ "${ROOT_AUTH}" = "nopass" ]; then
    # #region agent log
    echo '{"sessionId":"debug-session","runId":"db-setup","hypothesisId":"H1","location":"deploy-observium_8_native.sh:52","message":"Setting root password (was empty)","data":{"action":"alter-user"},"timestamp":'$(date +%s%3N)'}' >> "$LOG_PATH" 2>/dev/null || true
    # #endregion
    mysql -u root -e "ALTER USER 'root'@'localhost' IDENTIFIED BY '${MYSQL_ROOT_PASS}';"
fi

mysql -u root -p"${MYSQL_ROOT_PASS}" -e "CREATE DATABASE IF NOT EXISTS observium;"
mysql -u root -p"${MYSQL_ROOT_PASS}" -e "GRANT ALL PRIVILEGES ON observium.* TO 'observium'@'localhost' IDENTIFIED BY '${MYSQL_USER_PASS}';"

# Import if backup exists on NAS
if [ -f "$DB_DUMP" ]; then
    echo "--> Restoring database from NAS backup..."
    mysql -u root -p"${MYSQL_ROOT_PASS}" observium < "$DB_DUMP"
else
    echo "⚠️ Warning: $DB_DUMP not found. Starting with empty database."
fi

# 4. Observium Install & NAS Storage Setup
cd /opt
if [ ! -d "/opt/observium" ]; then
    wget http://www.observium.org/observium-community-latest.tar.gz
    tar zxvf observium-community-latest.tar.gz && rm observium-community-latest.tar.gz
fi

# Create target directories on NAS
mkdir -p "$MOUNT_POINT/container_storage/observium/"{logs,rrd,backups}

# Permissions Fix
echo "--> Applying Path Traversal and Ownership fixes..."
chmod o+x "/home/${PI_USER}"

# #region agent log
echo '{"sessionId":"debug-session","runId":"perm-fix","hypothesisId":"P1","location":"deploy-observium_8_native.sh:88","message":"Before chmod on NAS contents","data":{"mount_point":"'"$MOUNT_POINT"'","is_mount":'$(mountpoint -q "$MOUNT_POINT" && echo 'true' || echo 'false')',"uid_pi":'$(id -u "$PI_USER")',"gid_pi":'$(id -g "$PI_USER")'}}' >> "$LOG_PATH" 2>/dev/null || true
# #endregion

if sudo -u "$PI_USER" chmod -R 775 "${MOUNT_POINT}/container_storage/observium/" 2>/dev/null; then
    # #region agent log
    echo '{"sessionId":"debug-session","runId":"perm-fix","hypothesisId":"P1","location":"deploy-observium_8_native.sh:93","message":"chmod as PI_USER succeeded","data":{"path":"'"$MOUNT_POINT/container_storage/observium/"'","mode":"775"}}' >> "$LOG_PATH" 2>/dev/null || true
    # #endregion
else
    # #region agent log
    echo '{"sessionId":"debug-session","runId":"perm-fix","hypothesisId":"P2","location":"deploy-observium_8_native.sh:97","message":"chmod as PI_USER failed (likely root-squash)","data":{"path":"'"$MOUNT_POINT/container_storage/observium/"'","mode":"775","error":"Operation not permitted"}}' >> "$LOG_PATH" 2>/dev/null || true
    # #endregion
    echo "⚠️  Warning: Cannot change permissions on NAS export (likely root-squash). Ensure NAS export grants write to user ${PI_USER} (uid $(id -u "$PI_USER")) and precreate directories with correct perms."
fi

# Link NAS storage
rm -rf /opt/observium/rrd /opt/observium/logs
ln -snf "$MOUNT_POINT/container_storage/observium/rrd" /opt/observium/rrd
ln -snf "$MOUNT_POINT/container_storage/observium/logs" /opt/observium/logs

# Clear "Root-Owned" performance files to prevent "Permission Denied"
rm -f /opt/observium/rrd/poller-wrapper.rrd
rm -f /opt/observium/rrd/poller-wrapper_count.rrd

chown -R www-data:www-data /opt/observium
chown -h www-data:www-data /opt/observium/rrd
chown -h www-data:www-data /opt/observium/logs

# 5. HTTPS Setup
mkdir -p /etc/apache2/ssl
openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
  -keyout /etc/apache2/ssl/observium.key \
  -out /etc/apache2/ssl/observium.crt \
  -subj "/C=US/ST=State/L=City/O=IT/CN=${CURRENT_IP}"

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

# 6. Config File
cat <<EOF > /opt/observium/config.php
<?php
\$config['db_extension'] = 'mysqli';
\$config['db_host']      = 'localhost';
\$config['db_user']      = 'observium';
\$config['db_pass']      = '${MYSQL_USER_PASS}';
\$config['db_name']      = 'observium';
\$config['base_url']     = "https://${CURRENT_IP}";
\$config['fping']        = "/usr/bin/fping";
EOF

# 7. Cron Jobs & Daily Database Backup to NAS
cat <<EOF > /etc/cron.d/observium
# Discovery and Polling
33  */6   * * * www-data  /opt/observium/observium-wrapper discovery -h all >> /opt/observium/logs/cron-discovery-all.log 2>&1
*/5 * * * * www-data  /opt/observium/observium-wrapper discovery -h new >> /opt/observium/logs/cron-discovery-new.log 2>&1
*/5 * * * * www-data  /opt/observium/observium-wrapper poller -w 16 >> /opt/observium/logs/cron-poller-wrapper.log 2>&1

# Housekeeping
13  5     * * * www-data  /usr/bin/php /opt/observium/housekeeping.php -ysel >> /opt/observium/logs/cron-housekeeping-ysel.log 2>&1
47  4     * * * www-data  /usr/bin/php /opt/observium/housekeeping.php -yrptb >> /opt/observium/logs/cron-housekeeping-yrptb.log 2>&1
# Daily Database Backup to NAS (Recovery protection)
0   1     * * * root      mysqldump -u root -p'${MYSQL_ROOT_PASS}' observium > ${DB_DUMP}
EOF

# 8. Finalize
sudo -u www-data /opt/observium/discovery.php -u
systemctl restart cron

echo "========================================================"
echo "   SCRIPT FINISHED"
echo "   URL: https://${CURRENT_IP}"
echo "========================================================"
