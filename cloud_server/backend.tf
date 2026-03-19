# Define the GCS bucket used for Terraform state storage

terraform {
  backend "gcs" {
    bucket = var.terraform_state_bucket_name
    prefix = "terraform/state"
  }
}
