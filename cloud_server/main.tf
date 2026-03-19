# Compute instance resource
resource "google_compute_instance" "ubuntu_server" {
  name         = var.instance_name
  machine_type = var.machine_type
  zone         = var.zone
  tags         = var.network_tags

  # Boot disk configuration
  boot_disk {
    initialize_params {
      image = "ubuntu-os-cloud/ubuntu-2404-lts-amd64"
      size  = var.disk_size_gb
      type  = var.disk_type
    }

    auto_delete = true
  }

  # Network interface with ephemeral external IP
  network_interface {
    network = data.google_compute_network.default.name

    # Ephemeral external IP (free tier)
    access_config {
      # Empty block creates ephemeral IP
      # nat_ip can be specified for static IP (costs money)
    }
  }

  # SSH key configuration
  metadata = {
    ssh-keys = "${var.ssh_user}:${file(pathexpand(var.ssh_public_key_path))}"

    # Enable OS Login (recommended for production)
    enable-oslogin = "FALSE" # Set to FALSE to use SSH keys

    # Startup script
    startup-script = templatefile("${path.module}/scripts/startup.sh", {
      duckdns_domain = var.duckdns_domain
      duckdns_token  = var.duckdns_token
      ssh_user       = var.ssh_user
    })
  }

  # Lifecycle rules
  lifecycle {
    create_before_destroy = false
    ignore_changes = [
      # Ignore changes to metadata that might be updated by GCP
      metadata["ssh-keys"]
    ]
  }

  # Service account with minimal permissions
  service_account {
    scopes = [
      "https://www.googleapis.com/auth/devstorage.read_only",
      "https://www.googleapis.com/auth/logging.write",
      "https://www.googleapis.com/auth/monitoring.write",
    ]
  }

  # Allow instance to be stopped/started for maintenance
  allow_stopping_for_update = true

  # Scheduling configuration for free tier
  scheduling {
    # Automatic restart if instance crashes
    automatic_restart = true

    # Not preemptible (required for free tier)
    preemptible = false

    # Maintenance behavior
    on_host_maintenance = "MIGRATE"
  }
}
