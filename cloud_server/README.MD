# GCP Ubuntu Cloud Server with Terraform and Duck DNS

Terraform configuration for deploying a free-tier GCP Ubuntu 24.04 LTS server with automatic DDNS updates via Duck DNS.

## Features

- **Free Tier Optimized**: Uses GCP e2-micro instance (always free tier eligible)
- **Automated DDNS**: Duck DNS client auto-configured and updates every 5 minutes
- **Security Hardened**: SSH key-only auth, root login disabled, UFW firewall enabled
- **Auto-Updates**: Automatic security updates configured
- **Easy Deployment**: Single `terraform apply` deploys everything
- **Easy Cleanup**: `terraform destroy` removes all resources

## Prerequisites

### 1. GCP Account Setup

1. Create a GCP account at https://cloud.google.com
2. Create a new project or use existing project
3. Enable the Compute Engine API:
   ```bash
   gcloud services enable compute.googleapis.com
   ```

### 2. Install Required Tools

- **Terraform**: Install from https://www.terraform.io/downloads
  ```bash
  brew install terraform  # macOS
  ```
- **gcloud CLI**: Install from https://cloud.google.com/sdk/docs/install
  ```bash
  brew install google-cloud-sdk  # macOS
  ```
  
  **Troubleshooting**: If installation fails with Python path errors, try:
  ```bash
  # Option 1: Use existing Python
  export CLOUDSDK_PYTHON=$(which python3)
  brew install google-cloud-sdk
  
  # Option 2: Install Python first, then gcloud
  brew install python@3.12
  export CLOUDSDK_PYTHON=/opt/homebrew/opt/python@3.12/bin/python3
  brew install google-cloud-sdk
  
  # Option 3: Use official installer (bypasses Homebrew issues)
  curl https://sdk.cloud.google.com | bash
  exec -l $SHELL
  ```

### 3. Authenticate with GCP

```bash
gcloud auth login
gcloud auth application-default login
gcloud config set project YOUR_PROJECT_ID
gcloud auth application-default set-quota-project YOUR_PROJECT_ID
```

### 4. Duck DNS Account Setup

1. Go to https://www.duckdns.org
2. Sign in with your preferred OAuth provider (Google, GitHub, etc.)
3. Create a subdomain (e.g., `myserver`)
4. Copy your Duck DNS token from the top of the page

### 5. SSH Key Setup

Ensure you have an SSH keypair in your home directory:

```bash
# Check if you have a key
ls -la ~/.ssh/id_rsa.pub

# If not, create one
ssh-keygen -t rsa -b 4096 -C "your_email@example.com"
```

## Important: Free Tier Regional Limitations

**GCP's Always Free Tier e2-micro instances are ONLY available in US regions:**

- `us-east1` (South Carolina) - **Recommended** - Closest to UK (~80ms latency)
- `us-west1` (Oregon)
- `us-central1` (Iowa)

**European regions will incur charges (~$6/month):**
- `europe-west2` (London, UK)
- `europe-west1` (Belgium)
- `europe-west4` (Netherlands)

The default configuration uses `us-east1` to stay within free tier.

## Setup Instructions

### 1. Navigate to Directory

```bash
cd /Users/jholland/code/github/home-ops/cloud_based_host
```

### 2. Configure Variables

Copy the example variables file and edit it:

```bash
cp terraform.tfvars.example terraform.tfvars
vim terraform.tfvars
```

Edit `terraform.tfvars` with your values:

```hcl
project_id          = "your-actual-gcp-project-id"
region              = "us-east1"
zone                = "us-east1-b"
instance_name       = "ubuntu-cloud-server"
ssh_public_key_path = "~/.ssh/id_rsa.pub"
ssh_user            = "ubuntu"
duckdns_domain      = "your-actual-subdomain"
duckdns_token       = "your-actual-token-from-duckdns"
```

### 3. Set Up GCS Backend for Terraform State (Optional but Recommended)

**⚠️ MANUAL STEP**: To enable CI/CD and multi-workstation access, set up a GCS bucket for Terraform state storage.

**Option A - Using Terraform** (Recommended):
1. Add `terraform_state_bucket_name` to your `terraform.tfvars`:
   ```hcl
   terraform_state_bucket_name = "terraform-state-YOUR_PROJECT_ID"
   ```
2. Run `terraform apply` to create the bucket
3. Then configure the backend (see Option B step 2)

**Option B - Using gcloud** (Quick manual method):
```bash
# Create the bucket
gsutil mb -p YOUR_PROJECT_ID -l us-east1 gs://terraform-state-YOUR_PROJECT_ID

# Enable versioning
gsutil versioning set on gs://terraform-state-YOUR_PROJECT_ID
```

Then initialize Terraform with the backend:
```bash
terraform init -backend-config="bucket=terraform-state-YOUR_PROJECT_ID"
```

**Note**: If you skip this step, Terraform will use local state files. This works fine for single-workstation use but prevents CI/CD workflows.

### 4. Initialize Terraform

```bash
# If using GCS backend (recommended for CI/CD):
terraform init -backend-config="bucket=terraform-state-YOUR_PROJECT_ID"

# If using local state (single workstation only):
terraform init
```

### 5. Review the Plan

```bash
terraform plan
```

Review the resources that will be created:
- 1x Compute Instance (e2-micro)
- 3x Firewall Rules (SSH, ICMP, optional HTTP/HTTPS)
- Startup script with Duck DNS configuration

### 6. Deploy

```bash
terraform apply
```

Type `yes` when prompted.

Deployment takes approximately 2-3 minutes.

### 7. Get Connection Information

After successful deployment, Terraform will output connection details:

```bash
# View all outputs
terraform output

# Get SSH command
terraform output ssh_connection_command

# Get Duck DNS hostname
terraform output duckdns_hostname
```

### 8. Connect to Your Server

Using IP address:
```bash
ssh ubuntu@<EXTERNAL_IP>
```

Using Duck DNS hostname (after DNS propagates, ~5 minutes):
```bash
ssh ubuntu@your-subdomain.duckdns.org
```

## Post-Deployment Verification

### Check Duck DNS Status

On the server:
```bash
# Check Duck DNS update log
cat ~/duckdns/duck.log

# Run status check script
~/check-duckdns.sh

# View cron jobs
crontab -l
```

### Check System Status

```bash
# Check startup script logs
sudo tail -f /var/log/startup-script.log

# Check firewall status
sudo ufw status verbose

# Check automatic updates
sudo cat /etc/apt/apt.conf.d/50unattended-upgrades
```

### Verify Duck DNS Resolution

From your local machine:
```bash
nslookup your-subdomain.duckdns.org
ping your-subdomain.duckdns.org
```

## Management Commands

### View Current State

```bash
terraform show
terraform state list
```

### Update Configuration

1. Edit `terraform.tfvars` or `.tf` files
2. Run `terraform plan` to preview changes
3. Run `terraform apply` to apply changes

### Destroy Resources

To remove all created resources:

```bash
terraform destroy
```

Type `yes` when prompted. This will:
- Delete the compute instance
- Remove firewall rules
- Clean up all associated resources

**Note**: This is completely safe and free to do. You can recreate everything with `terraform apply`.

## CI/CD Setup with GitHub Actions

This repository includes GitHub Actions workflows for automated Terraform operations. This enables you to run Terraform from anywhere without needing local credentials or workstation setup.

### Benefits

- **No Workstation Dependency**: Run Terraform from any device via GitHub
- **No Expiring Keys**: Uses Workload Identity Federation (OIDC) - no key rotation needed
- **Free Tier**: GitHub Actions (2,000 min/month free) + GCS backend (5GB free)
- **State Locking**: Automatic state locking prevents conflicts
- **Audit Trail**: All changes tracked in GitHub Actions logs

### ⚠️ Manual Setup Steps Required

These steps must be completed manually before CI/CD will work:

#### 1. Set Up Workload Identity Federation in GCP

**Enable Required APIs**:
```bash
gcloud services enable iamcredentials.googleapis.com sts.googleapis.com
```

**Create Workload Identity Pool**:
```bash
gcloud iam workload-identity-pools create github-pool \
  --project=YOUR_PROJECT_ID \
  --location="global" \
  --display-name="GitHub Actions Pool"
```

**Create Workload Identity Provider** (links GitHub to GCP):
```bash
gcloud iam workload-identity-pools providers create-oidc github-provider \
  --project=YOUR_PROJECT_ID \
  --location="global" \
  --workload-identity-pool="github-pool" \
  --display-name="GitHub Provider" \
  --attribute-mapping="google.subject=assertion.sub,attribute.actor=assertion.actor,attribute.repository=assertion.repository" \
  --issuer-uri="https://token.actions.githubusercontent.com"
```

**Create Service Account**:
```bash
gcloud iam service-accounts create github-actions-terraform \
  --project=YOUR_PROJECT_ID \
  --display-name="GitHub Actions Terraform"
```

**Grant Service Account Permissions**:
```bash
# Compute permissions (for managing instances)
gcloud projects add-iam-policy-binding YOUR_PROJECT_ID \
  --member="serviceAccount:github-actions-terraform@YOUR_PROJECT_ID.iam.gserviceaccount.com" \
  --role="roles/compute.admin"

# Storage permissions (for Terraform state)
gcloud projects add-iam-policy-binding YOUR_PROJECT_ID \
  --member="serviceAccount:github-actions-terraform@YOUR_PROJECT_ID.iam.gserviceaccount.com" \
  --role="roles/storage.objectAdmin"
```

**Allow GitHub to Impersonate Service Account**:
```bash
# Get your project number first
PROJECT_NUMBER=$(gcloud projects describe YOUR_PROJECT_ID --format="value(projectNumber)")

# Get your GitHub username (replace YOUR_GITHUB_USERNAME)
gcloud iam service-accounts add-iam-policy-binding \
  github-actions-terraform@YOUR_PROJECT_ID.iam.gserviceaccount.com \
  --project=YOUR_PROJECT_ID \
  --role="roles/iam.workloadIdentityUser" \
  --member="principalSet://iam.googleapis.com/projects/${PROJECT_NUMBER}/locations/global/workloadIdentityPools/github-pool/attribute.repository/YOUR_GITHUB_USERNAME/home-ops"
```

**Get the Workload Identity Provider Resource Name**:
```bash
gcloud iam workload-identity-pools providers describe github-provider \
  --project=YOUR_PROJECT_ID \
  --location="global" \
  --workload-identity-pool="github-pool" \
  --format="value(name)"
```

Save this output - you'll need it for GitHub Secrets.

#### 2. Configure GitHub Repository Settings

1. Go to your GitHub repository
2. Navigate to: **Settings → Actions → General**
3. Under **"Workflow permissions"**: Select **"Read and write permissions"**
4. Check **"Allow GitHub Actions to create and approve pull requests"**
5. Click **Save**

#### 3. Add GitHub Secrets

Go to: **Settings → Secrets and variables → Actions → New repository secret**

Add the following secrets:

- **`GCP_PROJECT_ID`**: Your GCP project ID (e.g., `jholland-root-project`)
- **`GCP_WORKLOAD_IDENTITY_PROVIDER`**: Full provider resource name from step 1 (format: `projects/PROJECT_NUMBER/locations/global/workloadIdentityPools/github-pool/providers/github-provider`)
- **`GCP_SERVICE_ACCOUNT`**: Service account email (e.g., `github-actions-terraform@YOUR_PROJECT_ID.iam.gserviceaccount.com`)
- **`GCP_TERRAFORM_STATE_BUCKET`**: GCS bucket name for Terraform state (e.g., `terraform-state-YOUR_PROJECT_ID`)
- **`DUCKDNS_DOMAIN`**: Your Duck DNS subdomain (without `.duckdns.org`)
- **`DUCKDNS_TOKEN`**: Your Duck DNS token

**Note**: No service account keys needed! Workload Identity Federation uses OIDC tokens that don't expire.

#### 4. Migrate Existing State to GCS (If Applicable)

If you have existing local Terraform state and want to migrate it to GCS:

```bash
# Initialize with GCS backend
terraform init -backend-config="bucket=terraform-state-YOUR_PROJECT_ID" -migrate-state

# Verify migration
terraform state list

# Remove local state file (already in .gitignore)
rm terraform.tfstate terraform.tfstate.backup
```

### Using GitHub Actions Workflows

After setup, Terraform operations work as follows:

#### Automatic Plan on Pull Requests

1. Create a branch and make changes to Terraform files
2. Push to GitHub and create a Pull Request
3. GitHub Actions automatically runs `terraform plan`
4. Check the Actions tab or PR comments for plan output

#### Manual Apply via GitHub Actions

1. Go to **Actions** tab in GitHub
2. Select **"Terraform"** workflow
3. Click **"Run workflow"** button
4. Select:
   - Branch: `main` (or your branch)
   - Action: `apply`
5. Click **"Run workflow"**
6. Monitor the workflow run in the Actions tab

#### Manual Plan via GitHub Actions

Same as above, but select `plan` as the action.

#### Destroy Resources

⚠️ **Use with caution**: Same workflow, select `destroy` as the action.

### Workflow Features

- **Automatic Planning**: Runs `terraform plan` on every PR
- **Manual Apply**: Requires explicit workflow trigger for safety
- **State Locking**: GCS backend provides automatic state locking
- **No Keys**: Uses Workload Identity Federation (OIDC) - no key management
- **Free Tier**: All within free tier limits

### Troubleshooting CI/CD

**Workflow fails with authentication error**:
- Verify Workload Identity Provider is correctly configured
- Check GitHub Secrets are set correctly
- Ensure service account has required IAM roles

**State locking errors**:
- Another workflow run may be in progress
- Wait for the other run to complete
- Check GCS bucket for lock files (they auto-expire)

**Plan shows no changes when there should be**:
- Verify you're using the correct state bucket
- Check that state was migrated correctly
- Ensure backend configuration matches in workflow

## Cost Optimization

### Free Tier Allowances

GCP Always Free Tier includes:
- 1x e2-micro instance (0.25-2 vCPU, 1GB RAM)
- 30GB standard persistent disk
- 1GB network egress per month (to most regions)
- Ephemeral external IP (no charge)

### What Will Cost Money

- **Egress over 1GB/month**: First 1GB free, then ~$0.12/GB
- **European regions**: ~$6.11/month for e2-micro
- **SSD disks**: Use `pd-standard`, not `pd-ssd`
- **Static IPs**: Use ephemeral (configured by default)

### Monitoring Costs

Monitor your usage:
```bash
gcloud compute instances describe ubuntu-cloud-server --zone=us-east1-b
```

Check billing: https://console.cloud.google.com/billing

## Troubleshooting

### SSH Connection Refused

1. Check firewall rules:
   ```bash
   gcloud compute firewall-rules list
   ```

2. Verify instance is running:
   ```bash
   gcloud compute instances list
   ```

3. Check SSH key was added:
   ```bash
   gcloud compute instances describe ubuntu-cloud-server --zone=us-east1-b --format="get(metadata.items[ssh-keys])"
   ```

### Duck DNS Not Updating

1. Check startup script logs:
   ```bash
   sudo tail -100 /var/log/startup-script.log
   ```

2. Manually run update:
   ```bash
   ~/duckdns/duck.sh
   cat ~/duckdns/duck.log
   ```

   Should show `OK` if successful, `KO` if failed.

3. Verify cron job:
   ```bash
   crontab -l | grep duck
   ```

### Instance Won't Start

1. Check GCP Console for error messages
2. Verify quota limits:
   ```bash
   gcloud compute project-info describe --project=YOUR_PROJECT_ID
   ```

3. Check Compute Engine API is enabled:
   ```bash
   gcloud services list --enabled | grep compute
   ```

## Security Recommendations

### Implemented Security Measures

- SSH key-only authentication (password auth disabled)
- Root login disabled
- UFW firewall enabled (deny all incoming except SSH)
- Automatic security updates enabled
- Minimal service account permissions

### Additional Hardening (Optional)

1. **Install fail2ban**:
   ```bash
   sudo apt install fail2ban
   ```

2. **Change SSH port** (edit `/etc/ssh/sshd_config` and firewall rules)

3. **Enable 2FA for SSH**:
   ```bash
   sudo apt install libpam-google-authenticator
   ```

4. **Set up monitoring**:
   - Enable GCP Cloud Monitoring
   - Configure alerting for unusual activity

## Customization

### Add HTTP/HTTPS Access

Edit `terraform.tfvars`:
```hcl
enable_http  = true
enable_https = true
```

Then apply:
```bash
terraform apply
```

### Change Instance Name

Edit `terraform.tfvars`:
```hcl
instance_name = "my-custom-name"
```

### Switch to European Region (Paid)

Edit `terraform.tfvars`:
```hcl
region = "europe-west2" # London
zone   = "europe-west2-a"
```

**Note**: This will incur charges (~$6/month).

### Add Custom Startup Tasks

Edit `scripts/startup.sh` and add your custom commands at the end.

## Backup and Recovery

### Create Snapshot

```bash
gcloud compute disks snapshot ubuntu-cloud-server \
    --zone=us-east1-b \
    --snapshot-names=ubuntu-cloud-server-backup-$(date +%Y%m%d)
```

### Restore from Snapshot

Modify `main.tf` boot_disk block:
```hcl
boot_disk {
  initialize_params {
    snapshot = "projects/YOUR_PROJECT/global/snapshots/SNAPSHOT_NAME"
  }
}
```

## Integration with Ansible

This server can be managed with your existing Ansible playbooks:

1. Add to `inventory.yml`:
   ```yaml
   singles:
     hosts:
       gcp-cloudsvr:
         ansible_host: your-subdomain.duckdns.org
         ansible_user: ubuntu
         ansible_python_interpreter: /usr/bin/python3.12
   ```

2. Run playbooks:
   ```bash
   ansible-playbook -i inventory.yml configure-ubuntu-for-snmp.yml
   ```

## File Structure

```
cloud_server/
├── provider.tf              # GCP provider, Terraform config, and GCS backend
├── variables.tf             # Variable definitions with validation
├── main.tf                  # Compute instance resource
├── network.tf               # Firewall rules
├── backend.tf               # GCS bucket resource for Terraform state
├── outputs.tf               # Output values
├── terraform.tfvars.example # Template for user configuration
├── .gitignore              # Exclude secrets and state files
├── scripts/
│   └── startup.sh          # Duck DNS installation script
└── README.MD               # This file

.github/
└── workflows/
    └── terraform.yml       # GitHub Actions workflow for CI/CD
```

## Resources

- [GCP Free Tier Documentation](https://cloud.google.com/free/docs/compute-getting-started)
- [Duck DNS Installation Guide](https://www.duckdns.org/install.jsp)
- [Terraform GCP Provider Docs](https://registry.terraform.io/providers/hashicorp/google/latest/docs)
- [Terraform GCS Backend Docs](https://developer.hashicorp.com/terraform/language/settings/backends/gcs)
- [Workload Identity Federation with GitHub Actions](https://github.com/google-github-actions/auth#setting-up-workload-identity-federation)
- [GitHub Actions Documentation](https://docs.github.com/en/actions)
- [Ubuntu 24.04 LTS Release Notes](https://releases.ubuntu.com/24.04/)

## License

MIT License - See repository root LICENSE file

## Author

Created for home-ops repository
