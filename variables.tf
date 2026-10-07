variable "region" {
  description = "AWS region to deploy resources into"
  type        = string
  default     = "us-east-1"
}

variable "instance_type" {
  description = "EC2 instance type"
  type        = string
  default     = "t3.micro"
}

variable "key_name" {
  description = "Name of an existing EC2 key pair for SSH access"
  type        = string
  default     = "linux-demo-kp"
}

variable "server" {
  description = "Base name for the web server resource"
  type        = string
  default     = "tf-gha-gated-api-web-server"
}

variable "demo" {
  description = "Demo tag value for resource identification"
  type        = string
  default     = "tf-gha-gated-api"
}

variable "environment" {
  description = "Deployment environment (dev, staging, prod)"
  type        = string
  default     = "Test"
}

variable "owner" {
  description = "Owner tag for resource tracking"
  type        = string
  default     = "SE Team"
}

# -----------------------------------------------
# GitHub Actions deployment provenance
# Set automatically by the pipeline at plan time.
# Defaults to "local" so manual terraform runs still work.
# -----------------------------------------------
variable "github_run_id" {
  description = "GitHub Actions Run ID that triggered this deploy"
  type        = string
  default     = "local"
}

variable "github_sha" {
  description = "Git commit SHA that was deployed"
  type        = string
  default     = "local"
}

variable "github_actor" {
  description = "GitHub username that triggered the workflow"
  type        = string
  default     = "local"
}

variable "github_repository" {
  description = "owner/repo the deploy came from (used for the run link on the web page)"
  type        = string
  default     = "local"
}
