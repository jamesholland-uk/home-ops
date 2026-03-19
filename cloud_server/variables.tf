variable "project_id" {
  description = "GCP Project ID"
  type        = string
}

variable "region" {
  description = "GCP region for resources"
  type        = string
  default     = "us-east1" # Free tier eligible - closest to UK

  validation {
    condition = contains([
      "us-east1",     # South Carolina (FREE TIER)
      "us-west1",     # Oregon (FREE TIER)
      "us-central1",  # Iowa (FREE TIER)
      "europe-west1", # Belgium (PAID ~$6/month)
      "europe-west2", # London (PAID ~$6/month)
      "europe-west3", # Frankfurt (PAID ~$6/month)
      "europe-west4", # Netherlands (PAID ~$6/month)
      "europe-north1" # Finland (PAID ~$6/month)
    ], var.region)
    error_message = "Region must be a valid GCP region. Note: Only US regions are free tier eligible."
  }
}

variable "zone" {
  description = "GCP zone for the instance"
  type        = string
  default     = "us-east1-b" # Free tier eligible zone
}

variable "instance_name" {
  description = "Name of the compute instance"
  type        = string
  default     = "ubuntu-cloud-server"
}

variable "machine_type" {
  description = "Machine type for the instance"
  type        = string
  default     = "e2-micro" # Always free tier eligible

  validation {
    condition     = var.machine_type == "e2-micro"
    error_message = "Only e2-micro is eligible for GCP free tier."
  }
}

variable "ssh_public_key_path" {
  description = "Path to SSH public key file"
  type        = string
  default     = "~/.ssh/id_rsa.pub"
}

variable "ssh_user" {
  description = "SSH username to create on the instance"
  type        = string
  default     = "ubuntu"
}

variable "duckdns_domain" {
  description = "Duck DNS subdomain (without .duckdns.org)"
  type        = string
  sensitive   = false
}

variable "duckdns_token" {
  description = "Duck DNS token from https://www.duckdns.org/"
  type        = string
  sensitive   = true
}

variable "disk_size_gb" {
  description = "Boot disk size in GB (free tier includes 30GB)"
  type        = number
  default     = 30

  validation {
    condition     = var.disk_size_gb <= 30
    error_message = "Free tier includes up to 30GB of standard persistent disk."
  }
}

variable "disk_type" {
  description = "Boot disk type (pd-standard for free tier)"
  type        = string
  default     = "pd-standard"

  validation {
    condition     = var.disk_type == "pd-standard"
    error_message = "Only pd-standard is included in free tier. SSD disks incur charges."
  }
}

variable "network_tags" {
  description = "Network tags for the instance"
  type        = list(string)
  default     = ["ssh-server", "http-server", "https-server"]
}

variable "enable_https" {
  description = "Enable HTTPS firewall rule"
  type        = bool
  default     = false
}

variable "enable_http" {
  description = "Enable HTTP firewall rule"
  type        = bool
  default     = false
}

variable "terraform_state_bucket_name" {
  description = "Name of the GCS bucket for Terraform state storage (must be globally unique)"
  type        = string
  default     = ""
}
