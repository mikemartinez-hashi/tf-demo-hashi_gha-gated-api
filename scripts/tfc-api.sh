#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# tfc-api.sh - minimal HCP Terraform API client for an externally gated pipeline
#
# Nothing in here is GitHub-specific. It is plain curl + jq against the
# HCP Terraform API, so a Jenkins (or ADO, or any release orchestrator) stage
# can call the exact same script:
#
#   plan        <workspace> <config_dir> [message]  -> saved-plan run, waits for plan + policy
#   speculative <workspace> <config_dir> [message]  -> plan-only run (PR checks)
#   apply       <run_id> [comment]                   -> confirms a saved plan, waits for apply
#   discard     <run_id> [comment]                   -> discards a saved plan that was rejected
#
# Required env: TFC_TOKEN, TFC_ORG
# Optional env: TFC_ADDR (default https://app.terraform.io)
#               RUN_VARS_JSON  JSON array of run-specific variables,
#                              e.g. [{"key":"github_sha","value":"\"abc123\""}]
#                              (values are HCL - strings need the inner quotes)
#
# When GITHUB_OUTPUT / GITHUB_STEP_SUMMARY are set, results are also written
# there; otherwise they just go to stdout.
#
# API references (developer.hashicorp.com/terraform/cloud-docs/...):
#   workspaces/run/api, api-docs/configuration-versions, api-docs/run
# -----------------------------------------------------------------------------
set -euo pipefail

: "${TFC_TOKEN:?TFC_TOKEN must be set}"
: "${TFC_ORG:?TFC_ORG must be set}"
TFC_ADDR="${TFC_ADDR:-https://app.terraform.io}"
API="$TFC_ADDR/api/v2"
POLL_SECONDS=5
RUN_TIMEOUT_SECONDS=1800

api() {
  local method=$1 path=$2
  shift 2
  curl -sS --fail-with-body -X "$method" \
    -H "Authorization: Bearer $TFC_TOKEN" \
    -H "Content-Type: application/vnd.api+json" \
    "$@" "$API$path"
}

out() {
  echo "$1=$2"
  if [[ -n "${GITHUB_OUTPUT:-}" ]]; then echo "$1=$2" >>"$GITHUB_OUTPUT"; fi
}

summary() {
  if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then cat >>"$GITHUB_STEP_SUMMARY"; else cat; fi
}

run_status() { api GET "/runs/$1" | jq -r '.data.attributes.status'; }

# Poll a run until it reaches one of the given statuses (space separated).
wait_for_run() {
  local run_id=$1 stop_states=" $2 " status waited=0
  while true; do
    status=$(run_status "$run_id")
    if [[ "$stop_states" == *" $status "* ]]; then
      echo "$status"
      return
    fi
    if ((waited >= RUN_TIMEOUT_SECONDS)); then
      echo "timeout waiting on $run_id (last status: $status)" >&2
      exit 1
    fi
    echo "  $run_id: $status" >&2
    sleep "$POLL_SECONDS"
    waited=$((waited + POLL_SECONDS))
  done
}

# Upload a config dir as a new configuration version; prints the CV id.
upload_config() {
  local ws_id=$1 config_dir=$2 speculative=$3
  local tarball cv cv_id upload_url status
  tarball="$(mktemp -d)/config.tar.gz"

  # The config dir must be the root of the tarball (./main.tf, not ./dir/main.tf).
  tar -czf "$tarball" -C "$config_dir" .

  # auto-queue-runs=false: we create the run ourselves so we control its mode.
  # provisional=true: a saved plan's config only becomes current if applied.
  cv=$(api POST "/workspaces/$ws_id/configuration-versions" -d "$(jq -n \
    --argjson spec "$speculative" \
    '{data:{type:"configuration-versions",attributes:{
        "auto-queue-runs":false, speculative:$spec, provisional:($spec|not)}}}')")
  cv_id=$(jq -r '.data.id' <<<"$cv")
  upload_url=$(jq -r '.data.attributes."upload-url"' <<<"$cv")

  curl -sS --fail -X PUT -H "Content-Type: application/octet-stream" \
    --data-binary @"$tarball" "$upload_url" >/dev/null
  rm -f "$tarball"

  for _ in $(seq 1 30); do
    status=$(api GET "/configuration-versions/$cv_id" | jq -r '.data.attributes.status')
    [[ "$status" == "uploaded" ]] && break
    [[ "$status" == "errored" ]] && { echo "configuration upload errored" >&2; exit 1; }
    sleep 2
  done
  [[ "$status" == "uploaded" ]] || { echo "configuration $cv_id never reached 'uploaded'" >&2; exit 1; }
  echo "$cv_id"
}

# Pull the plan's raw log (ANSI stripped) for reviewers.
plan_log() {
  local run_id=$1 url
  url=$(api GET "/runs/$run_id?include=plan" | jq -r '.included[] | select(.type=="plans") | .attributes."log-read-url"')
  curl -sS "$url" | sed -e 's/\x1b\[[0-9;]*m//g' | tail -c 60000
}

cmd_plan() {
  local mode=$1 ws=$2 config_dir=$3 message=${4:-"Queued by external pipeline"}
  local ws_id cv_id payload run_id status run_json has_changes run_url adds chgs dels

  ws_id=$(api GET "/organizations/$TFC_ORG/workspaces/$ws" | jq -r '.data.id')
  echo "workspace $ws -> $ws_id" >&2

  if [[ "$mode" == "speculative" ]]; then
    cv_id=$(upload_config "$ws_id" "$config_dir" true)
  else
    cv_id=$(upload_config "$ws_id" "$config_dir" false)
  fi
  echo "configuration version $cv_id uploaded" >&2

  payload=$(jq -n \
    --arg msg "$message" --arg ws "$ws_id" --arg cv "$cv_id" \
    --argjson vars "${RUN_VARS_JSON:-[]}" \
    --argjson spec "$([[ "$mode" == "speculative" ]] && echo true || echo false)" \
    '{data:{type:"runs",
        attributes:({message:$msg, variables:$vars}
          + (if $spec then {"plan-only":true} else {"save-plan":true} end)),
        relationships:{
          workspace:{data:{type:"workspaces",id:$ws}},
          "configuration-version":{data:{type:"configuration-versions",id:$cv}}}}}')
  run_id=$(api POST "/runs" -d "$payload" | jq -r '.data.id')
  run_url="$TFC_ADDR/app/$TFC_ORG/workspaces/$ws/runs/$run_id"
  echo "run $run_id created: $run_url" >&2

  status=$(wait_for_run "$run_id" \
    "planned_and_saved planned_and_finished policy_override policy_soft_failed errored discarded canceled force_canceled")

  run_json=$(api GET "/runs/$run_id?include=plan")
  has_changes=$(jq -r '.data.attributes."has-changes"' <<<"$run_json")
  adds=$(jq -r '.included[] | select(.type=="plans") | .attributes."resource-additions"' <<<"$run_json")
  chgs=$(jq -r '.included[] | select(.type=="plans") | .attributes."resource-changes"' <<<"$run_json")
  dels=$(jq -r '.included[] | select(.type=="plans") | .attributes."resource-destructions"' <<<"$run_json")

  out run_id "$run_id"
  out run_url "$run_url"
  out status "$status"
  out has_changes "$([[ "$status" == "planned_and_saved" && "$has_changes" == "true" ]] && echo true || echo false)"

  {
    echo "### $([[ "$mode" == "speculative" ]] && echo "Speculative plan" || echo "Saved plan") - \`$ws\`"
    echo ""
    echo "| | |"
    echo "|---|---|"
    echo "| HCP Terraform run | [$run_id]($run_url) |"
    echo "| Status | \`$status\` |"
    echo "| Changes | +$adds ~$chgs -$dels |"
    echo ""
    echo "<details><summary>Plan output</summary>"
    echo ""
    echo '```'
    plan_log "$run_id"
    echo '```'
    echo "</details>"
    echo ""
  } | summary

  case "$status" in
    planned_and_saved | planned_and_finished) ;;
    policy_override | policy_soft_failed)
      echo "Policy check soft-failed on $run_id - override in HCP Terraform or fix the change." >&2
      exit 1 ;;
    *)
      echo "Run $run_id ended in status '$status'." >&2
      exit 1 ;;
  esac
}

cmd_apply() {
  local run_id=$1 comment=${2:-"Approved in external pipeline"} status

  # A saved plan goes stale (and HCP Terraform discards it) if anything else
  # applied to the workspace after it was planned. Refuse rather than re-plan:
  # the reviewer approved *this* plan, not whatever a new one would say.
  status=$(run_status "$run_id")
  if [[ "$status" != "planned_and_saved" ]]; then
    echo "Run $run_id is '$status', not 'planned_and_saved' - the reviewed plan can no longer be applied." >&2
    exit 1
  fi

  api POST "/runs/$run_id/actions/apply" -d "$(jq -n --arg c "$comment" '{comment:$c}')" >/dev/null
  echo "apply confirmed for $run_id" >&2

  status=$(wait_for_run "$run_id" "applied errored discarded canceled force_canceled")
  out status "$status"
  echo "### Apply - \`$run_id\`: \`$status\`" | summary
  [[ "$status" == "applied" ]] || exit 1
}

cmd_discard() {
  local run_id=$1 comment=${2:-"Rejected in external pipeline"} status
  status=$(run_status "$run_id")
  # Discardable states per the runs API - includes a run paused on a
  # soft-mandatory policy failure (policy_override).
  if [[ " planned planned_and_saved cost_estimated policy_checked policy_override post_plan_running post_plan_completed " == *" $status "* ]]; then
    api POST "/runs/$run_id/actions/discard" -d "$(jq -n --arg c "$comment" '{comment:$c}')" >/dev/null
    echo "discarded $run_id" >&2
  else
    echo "run $run_id is '$status' - nothing to discard" >&2
  fi
}

case "${1:-}" in
  plan)        shift; cmd_plan saved "$@" ;;
  speculative) shift; cmd_plan speculative "$@" ;;
  apply)       shift; cmd_apply "$@" ;;
  discard)     shift; cmd_discard "$@" ;;
  *)
    echo "usage: $0 {plan|speculative} <workspace> <config_dir> [message]" >&2
    echo "       $0 {apply|discard} <run_id> [comment]" >&2
    exit 2 ;;
esac
