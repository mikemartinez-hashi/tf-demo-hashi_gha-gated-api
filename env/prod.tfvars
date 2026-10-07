# prod inputs - the pipeline passes this file for the prod stage.
# Mirrors the "one tfvars file per environment" pattern from Jenkins.
# Environment tag casing matters: org Sentinel policy Required_tags allows Dev, QA, Prod, ...
environment   = "Prod"
region        = "us-east-1"
instance_type = "t3.micro"
owner         = "SE Team"
