#!/bin/bash
export instance_type="${instance_type}"
export environment="${environment}"
export region="${region}"
export github_run_id="${github_run_id}"
export github_sha="${github_sha}"
export github_actor="${github_actor}"
export github_repo="${github_repo}"

# Update and install Apache (Ubuntu uses apt + apache2, not yum + httpd)
sudo apt-get update -y
sudo apt-get install -y apache2
sudo systemctl enable apache2
sudo systemctl start apache2

sudo cat <<EOF > /var/www/html/index.html
<h1>HashiCorp Terraform Demo &mdash; SE Team</h1>
<h2>Infrastructure Details</h2>
<p><strong>Environment:</strong> $environment</p>
<p><strong>Region:</strong> $region</p>
<p><strong>Instance Type:</strong> $instance_type</p>

<hr>

<h2>GitHub Actions Deployment:</h2>
<p><strong>GitHub Actions Run ID:</strong> $github_run_id</p>
<p><strong>Commit SHA:</strong> $github_sha</p>
<p><strong>Deployed by:</strong> @$github_actor</p>
<p><strong>Run Link:</strong> <a href="https://github.com/$github_repo/actions/runs/$github_run_id">View GitHub Actions Run</a></p>
EOF
