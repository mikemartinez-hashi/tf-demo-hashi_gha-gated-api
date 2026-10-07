#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# One-time setup for this demo. Idempotent - safe to re-run.
#
#   1. HCP Terraform: creates workspaces <prefix>-dev / -qa / -prod
#      (remote execution, auto-apply off, pinned Terraform version, in PROJECT)
#   2. GitHub: creates environments dev / qa / prod on REPO, each requiring
#      approval from the reviewer before a deployment job runs
#
# Usage:
#   TFC_TOKEN=... ./scripts/setup.sh <owner/repo> [reviewer-github-login]
#
# Needs: curl, jq, and an authenticated `gh` CLI with admin on the repo.
# Does NOT create AWS credentials - the workspaces pick them up from the
# org's AWS variable set; make sure it applies to these workspaces/project.
# -----------------------------------------------------------------------------
set -euo pipefail

REPO=${1:?usage: setup.sh <owner/repo> [reviewer-login]}
REVIEWER=${2:-$(gh api user --jq .login)}
: "${TFC_TOKEN:?TFC_TOKEN must be set}"
TFC_ORG=${TFC_ORG:-Mikes_sandbox}
TFC_ADDR=${TFC_ADDR:-https://app.terraform.io}
PROJECT=${PROJECT:-Mike-Demos}
WS_PREFIX=tf-demo-gated-api
TF_VERSION=1.9.8   # the API pipeline has no local CLI; this just pins the remote runs
ENVIRONMENTS=(dev qa prod)

api() {
  local method=$1 path=$2
  shift 2
  curl -sS --fail-with-body -X "$method" \
    -H "Authorization: Bearer $TFC_TOKEN" \
    -H "Content-Type: application/vnd.api+json" \
    "$@" "$TFC_ADDR/api/v2$path"
}

project_id=$(api GET "/organizations/$TFC_ORG/projects?filter%5Bnames%5D=$PROJECT" | jq -r '.data[0].id // empty')
[[ -n "$project_id" ]] || { echo "project '$PROJECT' not found in $TFC_ORG" >&2; exit 1; }
echo "project $PROJECT -> $project_id"

for env in "${ENVIRONMENTS[@]}"; do
  ws="$WS_PREFIX-$env"
  if api GET "/organizations/$TFC_ORG/workspaces/$ws" >/dev/null 2>&1; then
    echo "workspace $ws already exists - leaving it alone"
  else
    api POST "/organizations/$TFC_ORG/workspaces" -d "$(jq -n \
      --arg name "$ws" --arg ver "$TF_VERSION" --arg proj "$project_id" --arg env "$env" \
      '{data:{type:"workspaces",
         attributes:{name:$name, "execution-mode":"remote", "auto-apply":false,
                     "terraform-version":$ver,
                     description:("Gated pipeline demo - " + $env)},
         relationships:{project:{data:{type:"projects",id:$proj}}}}}')" >/dev/null
    echo "workspace $ws created"
  fi
done

reviewer_id=$(gh api "users/$REVIEWER" --jq .id)
for env in "${ENVIRONMENTS[@]}"; do
  # prevent_self_review=false so a solo presenter can merge AND approve.
  # For a customer-realistic setup, flip it to true.
  jq -n --argjson id "$reviewer_id" \
    '{reviewers:[{type:"User",id:$id}], prevent_self_review:false}' |
    gh api -X PUT "repos/$REPO/environments/$env" --input - >/dev/null
  echo "GitHub environment $env: approval required from @$REVIEWER"
done

echo
echo "Remaining manual steps:"
echo "  - GitHub secret TF_API_TOKEN on $REPO (gh secret set TF_API_TOKEN -R $REPO)"
echo "  - Confirm the AWS credentials variable set applies to $WS_PREFIX-* workspaces"
echo "  - Do NOT set environment/region/instance_type/owner as workspace variables;"
echo "    they come from env/<env>.tfvars, and here workspace vars would override them"
