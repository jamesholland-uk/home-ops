#!/bin/bash
# Startup script for GCP Ubuntu instance
# Configures Duck DNS, security hardening, and automatic updates

set -e  # Exit on error

# Log all output to startup script log
exec > >(tee -a /var/log/startup-script.log)
exec 2>&1

echo "=== Startup Script Started at $(date) ==="

# Variables from Terraform template are used directly below

# ========================================================
# 1. UPDATE SYSTEM PACKAGES
# ========================================================
echo "--> Updating system packages..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get upgrade -y -qq

# ========================================================
# 2. INSTALL REQUIRED PACKAGES
# ========================================================
echo "--> Installing required packages..."
apt-get install -y -qq curl wget ufw unattended-upgrades

# ========================================================
# 3. SET UP DUCK DNS CLIENT
# ========================================================
echo "--> Setting up Duck DNS client..."

# Create Duck DNS directory
mkdir -p /home/${ssh_user}/duckdns
cd /home/${ssh_user}/duckdns

# Create Duck DNS update script
cat > duck.sh << DUCKSCRIPT
#!/bin/bash
# Duck DNS update script
DOMAIN="${duckdns_domain}"
TOKEN="${duckdns_token}"
echo url="https://www.duckdns.org/update?domains=\$DOMAIN&token=\$TOKEN&ip=" | curl -k -o ~/duckdns/duck.log -K -
DUCKSCRIPT

# Make script executable
chmod +x duck.sh
chown ${ssh_user}:${ssh_user} duck.sh

# Run initial update
echo "--> Running initial Duck DNS update..."
sudo -u ${ssh_user} /home/${ssh_user}/duckdns/duck.sh

# Set up cron job to update every 5 minutes
echo "--> Setting up Duck DNS cron job..."
(crontab -u ${ssh_user} -l 2>/dev/null || true; echo "*/5 * * * * /home/${ssh_user}/duckdns/duck.sh >/dev/null 2>&1") | crontab -u ${ssh_user} -

# Create status check script
cat > /home/${ssh_user}/check-duckdns.sh << 'STATUSSCRIPT'
#!/bin/bash
echo "Duck DNS Status:"
cat ~/duckdns/duck.log
echo ""
echo "Last update: $(stat -c %y ~/duckdns/duck.log 2>/dev/null || echo 'N/A')"
STATUSSCRIPT
chmod +x /home/${ssh_user}/check-duckdns.sh
chown ${ssh_user}:${ssh_user} /home/${ssh_user}/check-duckdns.sh

# ========================================================
# 4. SECURITY HARDENING
# ========================================================
echo "--> Configuring security settings..."

# Disable root login
sed -i 's/#PermitRootLogin yes/PermitRootLogin no/' /etc/ssh/sshd_config
sed -i 's/PermitRootLogin yes/PermitRootLogin no/' /etc/ssh/sshd_config
sed -i 's/#PermitRootLogin prohibit-password/PermitRootLogin no/' /etc/ssh/sshd_config
sed -i 's/PermitRootLogin prohibit-password/PermitRootLogin no/' /etc/ssh/sshd_config

# Disable password authentication (SSH key only)
sed -i 's/#PasswordAuthentication yes/PasswordAuthentication no/' /etc/ssh/sshd_config
sed -i 's/PasswordAuthentication yes/PasswordAuthentication no/' /etc/ssh/sshd_config

# Restart SSH service
systemctl restart sshd

# Configure UFW firewall
echo "--> Configuring UFW firewall..."
ufw --force reset
ufw default deny incoming
ufw default allow outgoing
ufw allow 22/tcp comment 'SSH'
ufw --force enable

# ========================================================
# 5. FINALIZE
# ========================================================
echo "--> Startup script completed successfully at $(date)"
echo "=== Startup Script Finished ==="

# Set proper ownership
chown -R ${ssh_user}:${ssh_user} /home/${ssh_user}/duckdns
