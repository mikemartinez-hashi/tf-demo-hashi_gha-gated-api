# prod inputs - the pipeline passes this file for the prod stage.
# Mirrors the "one tfvars file per environment" pattern from Jenkins.
environment   = "prod"
region        = "us-east-1"
instance_type = "t3.micro"
owner         = "SE Team"
