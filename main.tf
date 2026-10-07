terraform {
  required_version = "~> 1.9"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }

  # HCP Terraform backend
  # The API-driven pipeline never runs `terraform init` - it uploads this
  # directory as a configuration version and drives runs over the API. This
  # block (with TF_WORKSPACE) is only here so the code also works from a
  # laptop against the same workspaces (tf-demo-gated-api-dev / -qa / -prod).
  cloud {
    organization = "Mikes_sandbox"
  }
}

provider "aws" {
  region = var.region
}

# -----------------------------------------------
# EC2 Web Server
# -----------------------------------------------
# Create an EC2 Instance
resource "aws_instance" "web_server" {
  ami           = data.aws_ami.hc-base-ubuntu-2404["amd64"].id
  instance_type = var.instance_type

  key_name = var.key_name
  security_groups = [
    aws_security_group.allow_http.name
  ]

  tags = {
    Name        = "${var.server}-${var.environment}"
    Type        = var.demo
    Environment = var.environment
    Owner       = var.owner

  }

  user_data = templatefile("${path.module}/user_data.sh", {
    environment   = var.environment
    region        = var.region
    instance_type = var.instance_type
    github_run_id = var.github_run_id
    github_sha    = var.github_sha
    github_actor  = var.github_actor
    github_repo   = var.github_repository
  })
}

# -----------------------------------------------
# AMI - Amazon Linux 2023 (public, no account restriction)
# -----------------------------------------------
# Get AMI ID
data "aws_ami" "hc-base-ubuntu-2404" {
  for_each = toset(["amd64", "arm64"])
  filter {
    name   = "name"
    values = [format("hc-base-ubuntu-2404-%s-*", each.value)]
  }
  filter {
    name   = "state"
    values = ["available"]
  }
  most_recent = true
  owners      = ["888995627335"] # ami-prod account
}

# -----------------------------------------------
# Security Group
# -----------------------------------------------
resource "aws_security_group" "allow_http" {
  name        = "allow-http-${var.demo}-${var.environment}"
  description = "Allow HTTP and HTTPS inbound for demo web server"

  ingress {
    description = "HTTPS"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "HTTP"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    description = "Allow all outbound"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name        = "allow-http-${var.demo}-${var.environment}"
    Environment = var.environment
    ManagedBy   = "terraform"
  }
}
