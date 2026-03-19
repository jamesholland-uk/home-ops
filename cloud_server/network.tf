# Use default VPC network (free tier friendly)
data "google_compute_network" "default" {
  name = "default"
}

# Firewall rule for SSH access
resource "google_compute_firewall" "ssh" {
  name    = "${var.instance_name}-allow-ssh"
  network = data.google_compute_network.default.name

  allow {
    protocol = "tcp"
    ports    = ["22"]
  }

  source_ranges = ["0.0.0.0/0"]
  target_tags   = ["ssh-server"]

  description = "Allow SSH access from anywhere"
}

# Optional: Firewall rule for HTTP
resource "google_compute_firewall" "http" {
  count   = var.enable_http ? 1 : 0
  name    = "${var.instance_name}-allow-http"
  network = data.google_compute_network.default.name

  allow {
    protocol = "tcp"
    ports    = ["80"]
  }

  source_ranges = ["0.0.0.0/0"]
  target_tags   = ["http-server"]

  description = "Allow HTTP access from anywhere"
}

# Optional: Firewall rule for HTTPS
resource "google_compute_firewall" "https" {
  count   = var.enable_https ? 1 : 0
  name    = "${var.instance_name}-allow-https"
  network = data.google_compute_network.default.name

  allow {
    protocol = "tcp"
    ports    = ["443"]
  }

  source_ranges = ["0.0.0.0/0"]
  target_tags   = ["https-server"]

  description = "Allow HTTPS access from anywhere"
}

# Firewall rule for ICMP (ping) - useful for monitoring
resource "google_compute_firewall" "icmp" {
  name    = "${var.instance_name}-allow-icmp"
  network = data.google_compute_network.default.name

  allow {
    protocol = "icmp"
  }

  source_ranges = ["0.0.0.0/0"]
  target_tags   = ["ssh-server"]

  description = "Allow ICMP (ping) for network diagnostics"
}
