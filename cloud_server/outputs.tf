output "instance_name" {
  description = "Name of the created instance"
  value       = google_compute_instance.ubuntu_server.name
}

output "instance_id" {
  description = "ID of the created instance"
  value       = google_compute_instance.ubuntu_server.instance_id
}

output "instance_zone" {
  description = "Zone where the instance is running"
  value       = google_compute_instance.ubuntu_server.zone
}

output "external_ip" {
  description = "External IP address of the instance"
  value       = google_compute_instance.ubuntu_server.network_interface[0].access_config[0].nat_ip
}

output "internal_ip" {
  description = "Internal IP address of the instance"
  value       = google_compute_instance.ubuntu_server.network_interface[0].network_ip
}

output "ssh_connection_command" {
  description = "SSH command to connect to the instance"
  value       = "ssh ${var.ssh_user}@${google_compute_instance.ubuntu_server.network_interface[0].access_config[0].nat_ip}"
}

output "duckdns_hostname" {
  description = "Duck DNS hostname for the instance"
  value       = "${var.duckdns_domain}.duckdns.org"
}

output "ssh_connection_via_duckdns" {
  description = "SSH command using Duck DNS hostname"
  value       = "ssh ${var.ssh_user}@${var.duckdns_domain}.duckdns.org"
}

output "machine_type" {
  description = "Machine type of the instance"
  value       = google_compute_instance.ubuntu_server.machine_type
}

output "boot_disk_size" {
  description = "Boot disk size in GB"
  value       = google_compute_instance.ubuntu_server.boot_disk[0].initialize_params[0].size
}

output "network_tags" {
  description = "Network tags applied to the instance"
  value       = google_compute_instance.ubuntu_server.tags
}

output "instance_self_link" {
  description = "Self link of the instance"
  value       = google_compute_instance.ubuntu_server.self_link
}
