terraform {
  required_version = ">= 1.0"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 7.0"
    }
  }

  # GCS backend configuration for remote state storage
  # This enables state to be stored in GCS, allowing multiple workstations
  # and CI/CD pipelines to share the same state.
  # 
  # The bucket name must be provided via backend configuration file or CLI flag:
  #   terraform init -backend-config="bucket=terraform-state-YOUR_PROJECT_ID"
  # 
  # Or create a backend.tfbackend file with:
  #   bucket = "terraform-state-YOUR_PROJECT_ID"
  #   prefix = "terraform/state"
  # Then use: terraform init -backend-config=backend.tfbackend
  # 
  # TEMPORARILY COMMENTED OUT FOR LOCAL TESTING
  # Uncomment and configure when ready to use GCS backend
  # backend "gcs" {
  #   bucket = ""
  #   prefix = "terraform/state"
  # }
}

provider "google" {
  project = var.project_id
  region  = var.region
  zone    = var.zone
}
