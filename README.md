# tf-demo-hashi_gha-gated-api

**Gated promotion through the HCP Terraform API, with no Terraform CLI in the pipeline.**

This is the third variant in the set:

| Demo | Pattern |
|---|---|
| `tf-demo-hashi_githubactions` | Merge, then one plan-and-apply run (`-auto-approve`) |
| `tf-demo-hashi_gha-gated-cli` | CLI saved plans (`plan -out` / `apply tfplan`) with an approval gate per environment |
| **`tf-demo-hashi_gha-gated-api`** | **The same gate, driven entirely by REST calls** |

This one is closest to how a Jenkins (or ADO, or any release tool) pipeline would
integrate. All the HCP Terraform interaction lives in **`scripts/tfc-api.sh`**,
plain `curl` + `jq` with nothing GitHub-specific. A Jenkins stage calls the same
script with the same arguments.

```bash
scripts/tfc-api.sh plan     <workspace> <config_dir> [message]   # saved-plan run; waits for plan + policy
scripts/tfc-api.sh apply    <run_id> [comment]                   # confirm the reviewed run
scripts/tfc-api.sh discard  <run_id> [comment]                   # reject it
scripts/tfc-api.sh speculative <workspace> <config_dir>          # plan-only, for PRs
```

## What the API calls are

| Step | Call | Notes |
|---|---|---|
| 1 | `GET /organizations/:org/workspaces/:name` | Resolves the workspace ID |
| 2 | `POST /workspaces/:id/configuration-versions` | `auto-queue-runs: false`, `provisional: true` |
| 3 | `PUT <upload-url>` | Config dir as `.tar.gz`, with files at the tarball root |
| 4 | `POST /runs` | `save-plan: true`, plus run-specific `variables` |
| 5 | Poll `GET /runs/:id` | Stops at `planned_and_saved` (or `planned_and_finished` if there are no changes) |
| *gate* | GitHub Environment approval | Only the **run ID** crosses the gate |
| 6 | `POST /runs/:id/actions/apply` | Refuses unless the run is still `planned_and_saved` |
| 6' | `POST /runs/:id/actions/discard` | If the approval is rejected or the pipeline is cancelled |

## Doc references (verified 2026-10-07 against `hashicorp/web-unified-docs`)

- API-driven workflow: `cloud-docs/workspaces/run/api.mdx`. The configuration must
  be the root of the tarball.
- `save-plan` on run create: "plans and checks the configuration without becoming
  the workspace's current run". Configuration versions for saved-plan runs should be
  `provisional`. Source: `cloud-docs/api-docs/run.mdx`.
- `planned_and_saved` status ("only used for saved plan runs"), and the apply and
  discard actions. Source: `cloud-docs/api-docs/run.mdx`.
- `auto-queue-runs`, `speculative` and `provisional`. Source: `cloud-docs/api-docs/configuration-versions.mdx`.
- Run-specific `variables` values are HCL, so strings need inner quotes. Source:
  `cloud-docs/api-docs/run.mdx`.

## Variables: how tfvars reach a run here

The API has no `-var-file`. This pipeline copies `env/<env>.tfvars` into the
upload as `environment.auto.tfvars`.

**Gotcha worth saying out loud:** `*.auto.tfvars` sits *below* workspace variables
in precedence (`cloud-docs/variables/index.mdx`, #14 vs #8). If someone also sets
`environment` on the workspace, the workspace value wins. The alternatives are:
- variable sets per environment
- sending the values as run-specific `variables`, which have the same precedence as
  CLI `-var`. The provenance values (`github_sha` etc.) already go in that way.

## Setup

1. Create a GitHub repo for this folder and push it. This folder is **not** a git
   repo yet.
2. ```bash
   TFC_TOKEN=<token> ./scripts/setup.sh mikemartinez-hashi/<repo-name>
   ```
   This creates `tf-demo-gated-api-{dev,qa,prod}` (remote execution, auto-apply off)
   and the GitHub environments `dev`, `qa` and `prod`, with you as required reviewer.
3. `gh secret set TF_API_TOKEN -R mikemartinez-hashi/<repo-name>`. The token needs
   permission to queue and apply runs on those workspaces.
4. Make sure the org's AWS credentials variable set applies to the new workspaces.
   **Do not** set `environment`, `region`, `instance_type` or `owner` as workspace
   variables.

## Demo flow

1. **PR:** the speculative plan runs over the API and posts to the PR. Point out
   that the Actions log shows no `terraform` binary, only `curl` against the API.
2. **Merge:** `Plan (dev)` uploads the config, creates a saved-plan run and waits.
   The job summary has the run link, the change counts (+/~/-) and the plan log.
3. **HCP Terraform:** the run is in history, planned and saved, with policy results.
   Its message names the GitHub run and commit.
4. **Approve `dev`** in GitHub. The apply call confirms the same run ID.
5. **Reject `qa`.** The discard job runs and the HCP run shows as discarded, with
   the comment. Run history now records that the change was turned down.
6. **Close:** open `scripts/tfc-api.sh`. *This is the whole integration. Your
   Jenkins stage calls this. Nothing about it needs GitHub.*

## Known limits

- Polling: every 5s, with a 30-minute timeout per phase (`RUN_TIMEOUT_SECONDS`).
- A soft-mandatory policy failure (`policy_override`) stops the pipeline. The script
  doesn't override policies.
- Same `concurrency` behavior as the CLI variant: one pipeline at a time, and only
  the newest pending pipeline is kept.

## Teardown

Queue a destroy run on each of `tf-demo-gated-api-{dev,qa,prod}` from
**Settings → Destruction and Deletion** in HCP Terraform. You can also run it from
a laptop with `TF_WORKSPACE=tf-demo-gated-api-<env> terraform destroy -var-file=env/<env>.tfvars`.
The `cloud` block is there for exactly that.
