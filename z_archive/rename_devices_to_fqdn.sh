#!/bin/bash
# Script to rename Observium devices to their FQDNs
# Run this inside the observium-app container or on the host with docker exec

# Devices that need renaming (current name -> FQDN)
# Note: You'll need to replace IP addresses with actual device IPs from Observium

sudo docker exec observium-app /opt/observium/rename_device.php ai ai.jamoi.xyz
sudo docker exec observium-app /opt/observium/rename_device.php ap-bedroom ap-bedroom.jamoi.xyz
sudo docker exec observium-app /opt/observium/rename_device.php ap-dc ap-dc.jamoi.xyz
sudo docker exec observium-app /opt/observium/rename_device.php ap-dc-wifi7 ap-dc-wifi7.jamoi.xyz
sudo docker exec observium-app /opt/observium/rename_device.php ap-office ap-office.jamoi.xyz
sudo docker exec observium-app /opt/observium/rename_device.php dc-switch-24 dc-switch-24.jamoi.xyz
sudo docker exec observium-app /opt/observium/rename_device.php docker01 docker01.jamoi.xyz
sudo docker exec observium-app /opt/observium/rename_device.php docker02 docker02.jamoi.xyz
sudo docker exec observium-app /opt/observium/rename_device.php nas2 nas2.jamoi.xyz
sudo docker exec observium-app /opt/observium/rename_device.php newbuntu newbuntu.jamoi.xyz
sudo docker exec observium-app /opt/observium/rename_device.php pihole01 pihole01.jamoi.xyz
sudo docker exec observium-app /opt/observium/rename_device.php pihole02 pihole02.jamoi.xyz
sudo docker exec observium-app /opt/observium/rename_device.php plex02 plex02.jamoi.xyz
sudo docker exec observium-app /opt/observium/rename_device.php ship ship.jamoi.xyz
sudo docker exec observium-app /opt/observium/rename_device.php switch-8 switch-8.jamoi.xyz
sudo docker exec observium-app /opt/observium/rename_device.php unifi-controller unifi-controller.jamoi.xyz

# Devices that already have FQDNs (no action needed):
# - nuc1.jamoi.xyz
# - nuc2.jamoi.xyz
# - ubuntu.jamoi.xyz
# - vm-series-a.jamoi.xyz
# - vm-series-b.jamoi.xyz

echo "Done! All devices renamed to FQDNs."
