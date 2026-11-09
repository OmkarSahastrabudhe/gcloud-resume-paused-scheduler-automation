#  GCP Cloud Scheduler Automated Morning Resume Engine (Exclude-List Mechanism)

| Document Property | Details |
| :--- | :--- |

| **Document Status** | `IMPLEMENTED & VERIFIED` |
| **Author / Owner** | Omkar Sahastrabudhe (DevOps Engineering) |
| **Target Platform** | Google Cloud Platform (Cloud Scheduler, Cloud Run Functions, IAM) |
| **Project & Region Scope** | Single-Project Architecture (`asia-south1`) |
| **Dedicated Identity** | `scheduler-resumer-sa@<PROJECT_ID>.iam.gserviceaccount.com` |
| **CI/CD Orchestration** | GitLab CI (Self-Hosted GCP Runner + Idempotent `deploy.sh` Engine) |
| **Last Updated** | November 8, 2026 |

---

## 1. Executive Summary & Problem Statement

### 1.1 Background (Nightly Cost-Optimization Setup)
To minimize cloud infrastructure spend across non-production environments, automated **Cloud Scheduler** jobs run every night to scale down or stop compute resources—including reducing GKE Node Pool counts, stopping Compute Engine VM instances, and scaling down RDS/SQL instances.

When developers perform late-night testing, debugging, or releases, they manually **Pause** specific scale-down schedulers in the GCP Console so their active testing environments are not terminated mid-session.

### 1.2 The Core Problem
1. **Forgotten Paused Schedulers (Cloud Cost Leakage):** Developers frequently forget to manually re-enable (`Resume`) the paused schedulers the next morning, leaving expensive compute resources running 24/7 over subsequent nights.
2. **Flaw in Legacy Automation (Static Include-List / Allowlist):** The previous morning recovery mechanism relied on a **hardcoded Include-List**. It only resumed schedulers explicitly listed inside its configuration:
   * Whenever a new scale-down scheduler was created in GCP, engineers had to remember to manually add it to the script's allowlist.
   * Any newly created or unlisted scheduler that was paused by a developer remained permanently paused without visibility.

---

## 2. Solution Overview (The Exclude-List Architecture)

Instead of maintaining a static list of schedulers *to resume*, we inverted the design into a **Dynamic Discovery + Exclude-List (Denylist) Engine**:

1. **Dynamic Discovery:** Every morning at `08:00 AM IST` (`0 8 * * *`), a Master Cloud Scheduler (`master-morning-resumer`) triggers a private HTTP Cloud Run Function (`resume-schedulers-fn`).
2. **Exclude-List Filtering:** The function dynamically queries the GCP Cloud Scheduler API (`projects.locations.jobs.list`) to discover **all** schedulers in the region, filters for jobs currently in the `PAUSED` state, and **automatically resumes every paused scheduler EXCEPT those explicitly listed in `ignore_list.txt`**.
3. **State-Aware Idempotent GitLab CI Pipeline:** A smart reconciliation script (`deploy.sh`) manages the lifecycle of both the Cloud Run Function and the Master Scheduler:
   * **First Run:** Creates the Cloud Run Function and Master Cloud Scheduler from scratch.
   * **Code or Python Runtime Changed:** Detects SHA256 fingerprint changes across `main.py`, `requirements.txt`, and `PYTHON_RUNTIME`, triggering a container rebuild.
   * **Only `ignore_list.txt` Changed (Fast Path):** Skips container building completely and updates the `IGNORE_SCHEDULERS` environment variable in **~5 seconds**.
   * **Only Cron Schedule Changed:** Updates the Master Scheduler timer without touching Cloud Run.
   * **No Changes Detected:** Performs a 2-second no-op `[SKIP]` without creating redundant Cloud Run revisions.

---

## 3. Repository Structure & File Responsibilities

All automation artifacts reside in a single GitLab repository. Responsibilities are strictly separated so developers only edit `ignore_list.txt` for day-to-day operations.

```text
scheduler-automation/
 ├── ignore_list.txt    # User-facing Denylist (Schedulers to keep PAUSED)
 ├── main.py            # Cloud Run Function Python logic (Zero-Hardcoded)
 ├── requirements.txt   # Python runtime dependencies
 ├── deploy.sh          # State-aware idempotent deployment & reconciliation engine
 └── .gitlab-ci.yml     # Automated CI/CD pipeline configuration
```

| File Name | Purpose & Architectural Role | Modified By |
| :--- | :--- | :--- |
| **`ignore_list.txt`** | Line-by-line list of Cloud Scheduler names that must **remain PAUSED** during the morning auto-resume run. Supports `#` comments and blank lines. | Developers / DevOps |
| **`main.py`** | HTTP Cloud Run Function entry point (`hello_http`). Reads configuration strictly from environment variables, queries the GCP Scheduler API, skips jobs in `IGNORE_SCHEDULERS`, and resumes all other `PAUSED` jobs with per-job fault isolation. | DevOps (Core logic only) |
| **`requirements.txt`** | Specifies Python packages (`functions-framework` and `google-cloud-scheduler`) installed automatically by GCP Buildpacks during image build. | DevOps |
| **`deploy.sh`** | Idempotent Bash engine executed by GitLab CI. Computes SHA256 fingerprints, inspects live Cloud Run JSON specs via `jq`, and executes the minimal required GCP update. | DevOps |
| **`.gitlab-ci.yml`** | Triggers `./deploy.sh` automatically on pushes to the default branch using the GCP GitLab Runner's native metadata identity. | DevOps |

---

## 4. Architecture Flow, IAM & Security Constraints

### 4.1 End-to-End Execution Diagram

```text
[GitLab Repository: ignore_list.txt / main.py / deploy.sh]
        │
        │ 1. CI/CD State Reconciliation (SHA256 Hash + jq Diff Check)
        ▼
[Master Cloud Scheduler: master-morning-resumer (0 8 * * * IST)]
        │
        │ 2. HTTP POST + OIDC ID Token (Header: Authorization: Bearer <JWT>)
        │    Identity: scheduler-resumer-sa (Checked for 'Cloud Run Invoker')
        ▼
[Cloud Run Function: resume-schedulers-fn (Python 3.12+)]
        │
        ├─► Reads Env Vars: GCP_PROJECT_ID, GCP_REGION, IGNORE_SCHEDULERS
        ├─► Calls GCP Scheduler API: client.list_jobs()
        │   Identity: scheduler-resumer-sa (Checked for 'Cloud Scheduler Admin')
        │
        ├──► Is Job PAUSED & NOT in Ignore List? ──► YES ──► client.resume_job() ──► [ENABLED]
        └──► Is Job PAUSED & IN Ignore List?     ──► YES ──► [SKIP] (Remains PAUSED)
```

### 4.2 Zero-Default-SA Policy & Single Custom Service Account Matrix
To avoid relying on the overly permissive Default Compute Engine Service Account (`*-compute@developer.gserviceaccount.com`), we enforce a **Single Custom Service Account (`scheduler-resumer-sa`)** across all three operational boundaries using `--build-service-account`, `--service-account`, and `--oidc-service-account-email`:

| Lifecycle Phase | Active GCP Service | Identity (Principal) | IAM Role Required | Technical Purpose |
| :--- | :--- | :--- | :--- | :--- |
| **1. Build Phase** | Cloud Build / Buildpacks | `scheduler-resumer-sa` | `roles/run.builder` (`Cloud Run Builder`) | Assigned via `--build-service-account`. Packages `main.py` and `requirements.txt` into a container image without using the Default Compute SA. |
| **2. Trigger Phase** | Master Cloud Scheduler | `scheduler-resumer-sa` | `roles/run.invoker` (`Cloud Run Invoker`) | Assigned via `--oidc-service-account-email`. Mints a Google-signed **OIDC JWT Token** attached to the HTTP `Authorization: Bearer` header to pass Cloud Run's authentication gatekeeper. |
| **3. Runtime Phase** | Cloud Run Function | `scheduler-resumer-sa` | `roles/cloudscheduler.admin` (`Cloud Scheduler Admin`) | Assigned via `--service-account`. Grants the Python container permission to execute `cloudscheduler.jobs.list` and `cloudscheduler.jobs.enable` (`resume_job`). |
| **4. CI/CD Runner** | GCP-Hosted GitLab Runner | Runner VM/GKE SA | `roles/run.admin`, `roles/cloudscheduler.admin`, `roles/iam.serviceAccountUser` | Allows the in-GCP GitLab Runner to deploy/update Cloud Run and Cloud Scheduler via Instance Metadata without static JSON service account keys. |

### 4.3 Why OIDC Token Instead of OAuth Token on Cloud Scheduler?
* **OIDC Token (`Add OIDC token`):** Used when Cloud Scheduler targets an application endpoint such as a **Cloud Run Function/Service** (`*.run.app`). Cloud Run's IAM gatekeeper validates the signed OpenID Connect ID card (`aud` = Function URL, `sub` = Service Account).
* **OAuth Token (`Add OAuth token`):** Only used when Cloud Scheduler directly calls a raw Google API endpoint (`*.googleapis.com`, such as triggering a Cloud Run Job API).

### 4.4 Architectural Constraints
1. **Single-Project & Regional Alignment:** The Master Scheduler, Cloud Run Function, and target scale-down schedulers reside in the same GCP Project and Region (`asia-south1`).
2. **Zero Hardcoding Policy (12-Factor App):** `main.py` contains zero hardcoded Project IDs, regions, or job names. If `GCP_PROJECT_ID` or `GCP_REGION` environment variables are missing, the function fails fast with `HTTP 500 Configuration_Error` rather than risking execution against a fallback environment.
3. **Strict Authentication (`--no-allow-unauthenticated`):** Public access to the Cloud Run Function URL is blocked at the GCP ingress layer.

---

## 5. Edge Cases Engineered & Verified

| # | Edge Case Scenario | Root Cause / Technical Risk | Engineered Solution |
| :--- | :--- | :--- | :--- |
| **1** | **Slow Container Rebuilds on Ignore-List Edits** | Running `gcloud run deploy --source=.` takes ~2 minutes even when a developer only edits `ignore_list.txt`. | **SHA256 Fingerprinting (`CODE_HASH`):** `deploy.sh` hashes `main.py`, `requirements.txt`, and `PYTHON_RUNTIME`. When unchanged, it skips building and runs a **5-second Fast-Path Env Update** (`gcloud run services update`). |
| **2** | **Future Python Runtime Upgrades (`python312` -> `python313`)** | If `PYTHON_RUNTIME` is upgraded without modifying `main.py` or `requirements.txt`, a file-only hash wouldn't detect the change and would skip deployment. | Baked `echo "$PYTHON_RUNTIME"` directly into the `LOCAL_CODE_HASH` calculation so any base-image upgrade automatically triggers a fresh build. |
| **3** | **Redundant Cloud Run Revisions on No-Op Runs** | Running `services update` when neither code nor `ignore_list.txt` changed creates unnecessary Cloud Run revisions. | `deploy.sh` compares both `LOCAL_CODE_HASH == DEPLOYED_HASH` and `IGNORE_LIST == DEPLOYED_IGNORE`. If both match, Cloud Run is untouched (`[FUNCTION - SKIP]`). |
| **4** | **Empty Ignore List (`null` Value Quirk in Knative)** | When `IGNORE_SCHEDULERS=""` is set, Cloud Run/Knative omits the `.value` key in the container YAML. Standard `jq` queries return `"null"`, breaking idempotency (`"" != "null"`). | Used `jq -r '... | .value // empty'` in `deploy.sh` so missing YAML keys resolve cleanly to an empty string `""`. |
| **5** | **Commas Inside `--update-env-vars` Values** | `gcloud` normally splits `--update-env-vars` on commas, which breaks comma-separated scheduler lists (`job1,job2`). | Used `gcloud` custom delimiter syntax: `^@^KEY1=VAL1@IGNORE_SCHEDULERS=job1,job2`. |
| **6** | **Comments, Blank Lines & Spaces in `ignore_list.txt`** | Developers adding `# comments`, blank lines, or trailing spaces in Git would corrupt the parsed environment variable. | Sanitized via `grep -v '^[[:space:]]*#' ignore_list.txt \| grep -v '^[[:space:]]*$' \| tr -d ' \r' \| paste -sd ',' -`. |
| **7** | **Master Scheduler Cron Timer Drift** | If the team updates `TARGET_CRON` (e.g., from `0 8 * * *` to `15 9 * * *`), a naive `if exists -> skip` check ignores the schedule change. | `deploy.sh` inspects the live `schedule` and `timeZone` of the Master Scheduler and executes `gcloud scheduler jobs update http` whenever drift is detected. |
| **8** | **Single-Job Failure Halting the Loop** | If 1 out of 10 paused schedulers throws an API error during `resume_job()`, an unguarded loop aborts and leaves the remaining 9 jobs paused. | Wrapped `client.resume_job()` in a per-job `try/except` block inside `main.py` to log failures in `failed_to_resume` (`Partial_Success`) while resuming all remaining jobs. |
| **9** | **Ad-Hoc One-Day Override via HTTP Payload** | An engineer wants to test or override the ignore list for a single manual invocation without committing to Git. | `main.py` merges both the `IGNORE_SCHEDULERS` env var and any `{"ignore": [...]}` JSON array passed in the HTTP POST request body. |

---

## 6. Complete Implementation Code Reference

### 6.1 `ignore_list.txt`
```text
# Schedulers listed below (one per line) will remain PAUSED during the morning auto-resume run.
# Blank lines and lines starting with '#' are automatically ignored.

vm-night-scaledown
```

### 6.2 `requirements.txt`
```text
functions-framework==3.*
google-cloud-scheduler==2.*
```

### 6.3 `main.py`
```python
import os
import functions_framework
from google.cloud import scheduler_v1

@functions_framework.http
def hello_http(request):
    # 1. Pure Dynamic Configuration from Environment Variables (Zero Hardcoding)
    project_id = os.environ.get("GCP_PROJECT_ID")
    region = os.environ.get("GCP_REGION")
    master_job = os.environ.get("MASTER_SCHEDULER_NAME")

    # Fail-fast validation if required environment variables are missing
    if not project_id or not region:
        return {
            "status": "Configuration_Error",
            "message": "Missing required environment variables: GCP_PROJECT_ID or GCP_REGION"
        }, 500

    # 2. Parse IGNORE_SCHEDULERS from Environment Variable safely
    raw_ignore = os.environ.get("IGNORE_SCHEDULERS", "")
    ignore_set = {job.strip() for job in raw_ignore.split(",") if job.strip()}

    # 3. Merge optional ad-hoc overrides from HTTP POST JSON body
    req_json = request.get_json(silent=True) or {}
    extra_ignore = req_json.get("ignore", [])
    if isinstance(extra_ignore, list):
        for job in extra_ignore:
            if str(job).strip():
                ignore_set.add(str(job).strip())

    client = scheduler_v1.CloudSchedulerClient()
    parent = f"projects/{project_id}/locations/{region}"

    resumed_jobs = []
    skipped_jobs = []
    already_enabled = []
    failed_jobs = {}

    try:
        for job in client.list_jobs(parent=parent):
            short_name = job.name.split("/")[-1]
            state_name = scheduler_v1.Job.State(job.state).name

            # Self-protection: Skip the master morning resumer job itself
            if master_job and short_name == master_job:
                continue

            if state_name == "PAUSED":
                if short_name in ignore_set:
                    print(f"[SKIP] '{short_name}' is in ignore list. Leaving PAUSED.")
                    skipped_jobs.append(short_name)
                else:
                    # Per-job fault isolation so one broken job never halts others
                    try:
                        print(f"[RESUME] Resuming '{short_name}'...")
                        client.resume_job(name=job.name)
                        resumed_jobs.append(short_name)
                    except Exception as job_err:
                        print(f"[ERROR] Failed to resume '{short_name}': {job_err}")
                        failed_jobs[short_name] = str(job_err)
            else:
                already_enabled.append(short_name)

        return {
            "status": "Success" if not failed_jobs else "Partial_Success",
            "project_id": project_id,
            "region": region,
            "active_ignore_list": sorted(list(ignore_set)),
            "resumed_now": resumed_jobs,
            "skipped_paused": skipped_jobs,
            "already_enabled": already_enabled,
            "failed_to_resume": failed_jobs
        }, 200

    except Exception as e:
        print(f"[CRITICAL ERROR] Failed to list schedulers: {e}")
        return {"status": "Error", "message": str(e)}, 500
```

### 6.4 `deploy.sh`
```bash
#!/usr/bin/env bash
set -euo pipefail

# Dynamic configuration via Environment Variables or active gcloud config
PROJECT_ID="${GCP_PROJECT_ID:-$(gcloud config get-value project)}"
REGION="${GCP_REGION:-asia-south1}"
FUNCTION_NAME="${FUNCTION_NAME:-resume-schedulers-fn}"
SCHEDULER_NAME="${SCHEDULER_NAME:-master-morning-resumer}"
SA_EMAIL="${SA_EMAIL:-scheduler-resumer-sa@${PROJECT_ID}.iam.gserviceaccount.com}"

TARGET_CRON="${TARGET_CRON:-0 8 * * *}"
TARGET_TZ="${TARGET_TZ:-Asia/Kolkata}"
PYTHON_RUNTIME="${PYTHON_RUNTIME:-python312}"

# 1. Cleanly parse ignore_list.txt (strip # comments, blank lines, CR, and spaces)
IGNORE_LIST=$(grep -v '^[[:space:]]*#' ignore_list.txt | grep -v '^[[:space:]]*$' | tr -d ' \r' | paste -sd ',' - || true)

# 2. Calculate SHA256 Fingerprint of main.py + requirements.txt + PYTHON_RUNTIME
LOCAL_CODE_HASH=$( (cat main.py requirements.txt; echo "$PYTHON_RUNTIME") | sha256sum | awk '{print $1}' )

echo "========================================================"
echo "Dynamic Project ID : ${PROJECT_ID}"
echo "Dynamic Region     : ${REGION}"
echo "Python Runtime     : ${PYTHON_RUNTIME}"
echo "Parsed Ignore List : [${IGNORE_LIST}]"
echo "Target Cron Timer  : ${TARGET_CRON} (${TARGET_TZ})"
echo "Local Code Hash    : ${LOCAL_CODE_HASH}"
echo "========================================================"

# ---------------------------------------------------------
# PART A: CLOUD RUN FUNCTION CHECK & UPDATE
# ---------------------------------------------------------
if SERVICE_JSON=$(gcloud run services describe "$FUNCTION_NAME" --region="$REGION" --project="$PROJECT_ID" --format=json 2>/dev/null); then
  DEPLOYED_HASH=$(echo "$SERVICE_JSON" | jq -r '.spec.template.spec.containers[0].env[]? | select(.name=="CODE_HASH") | .value // empty' || true)
  DEPLOYED_IGNORE=$(echo "$SERVICE_JSON" | jq -r '.spec.template.spec.containers[0].env[]? | select(.name=="IGNORE_SCHEDULERS") | .value // empty' || true)

  echo "Deployed Code Hash : ${DEPLOYED_HASH:-<none>}"
  echo "Deployed Ignore    : [${DEPLOYED_IGNORE}]"
  echo "--------------------------------------------------------"

  if [[ "$LOCAL_CODE_HASH" != "$DEPLOYED_HASH" ]]; then
    echo "🔨 [FUNCTION - CODE/RUNTIME CHANGED] Deploying updated source / runtime..."
    gcloud run deploy "$FUNCTION_NAME" \
      --source=. \
      --function=hello_http \
      --base-image="$PYTHON_RUNTIME" \
      --region="$REGION" \
      --project="$PROJECT_ID" \
      --service-account="$SA_EMAIL" \
      --build-service-account="projects/${PROJECT_ID}/serviceAccounts/${SA_EMAIL}" \
      --no-allow-unauthenticated \
      --set-env-vars="^@^GCP_PROJECT_ID=${PROJECT_ID}@GCP_REGION=${REGION}@MASTER_SCHEDULER_NAME=${SCHEDULER_NAME}@IGNORE_SCHEDULERS=${IGNORE_LIST}@CODE_HASH=${LOCAL_CODE_HASH}"
  elif [[ "$IGNORE_LIST" != "$DEPLOYED_IGNORE" ]]; then
    echo "⚡ [FUNCTION - FAST PATH] Code unchanged! Updating ONLY IGNORE_SCHEDULERS from [${DEPLOYED_IGNORE}] to [${IGNORE_LIST}]..."
    gcloud run services update "$FUNCTION_NAME" \
      --region="$REGION" \
      --project="$PROJECT_ID" \
      --update-env-vars="^@^GCP_PROJECT_ID=${PROJECT_ID}@GCP_REGION=${REGION}@MASTER_SCHEDULER_NAME=${SCHEDULER_NAME}@IGNORE_SCHEDULERS=${IGNORE_LIST}@CODE_HASH=${LOCAL_CODE_HASH}"
  else
    echo "✅ [FUNCTION - SKIP] Both Code Hash and Ignore List are already identical. Zero changes needed!"
  fi
else
  echo "🚀 [FUNCTION - FIRST RUN] Creating Function from scratch..."
  gcloud run deploy "$FUNCTION_NAME" \
    --source=. \
    --function=hello_http \
    --base-image="$PYTHON_RUNTIME" \
    --region="$REGION" \
    --project="$PROJECT_ID" \
    --service-account="$SA_EMAIL" \
    --build-service-account="projects/${PROJECT_ID}/serviceAccounts/${SA_EMAIL}" \
    --no-allow-unauthenticated \
    --set-env-vars="^@^GCP_PROJECT_ID=${PROJECT_ID}@GCP_REGION=${REGION}@MASTER_SCHEDULER_NAME=${SCHEDULER_NAME}@IGNORE_SCHEDULERS=${IGNORE_LIST}@CODE_HASH=${LOCAL_CODE_HASH}"
fi

FUNC_URL=$(gcloud run services describe "$FUNCTION_NAME" --region="$REGION" --project="$PROJECT_ID" --format="value(status.url)")

# ---------------------------------------------------------
# PART B: MASTER CLOUD SCHEDULER CHECK & UPDATE
# ---------------------------------------------------------
if gcloud scheduler jobs describe "$SCHEDULER_NAME" --location="$REGION" --project="$PROJECT_ID" >/dev/null 2>&1; then
  CURRENT_CRON=$(gcloud scheduler jobs describe "$SCHEDULER_NAME" --location="$REGION" --project="$PROJECT_ID" --format="value(schedule)")
  CURRENT_TZ=$(gcloud scheduler jobs describe "$SCHEDULER_NAME" --location="$REGION" --project="$PROJECT_ID" --format="value(timeZone)")

  if [[ "$CURRENT_CRON" == "$TARGET_CRON" && "$CURRENT_TZ" == "$TARGET_TZ" ]]; then
    echo "✅ [SCHEDULER - SKIP] Master Scheduler is already set to '${CURRENT_CRON}' (${CURRENT_TZ})."
  else
    echo "🔄 [SCHEDULER - UPDATE] Updating timer from '${CURRENT_CRON}' to '${TARGET_CRON}'..."
    gcloud scheduler jobs update http "$SCHEDULER_NAME" \
      --location="$REGION" \
      --project="$PROJECT_ID" \
      --schedule="$TARGET_CRON" \
      --time-zone="$TARGET_TZ" \
      --uri="$FUNC_URL"
  fi
else
  echo "⏰ [SCHEDULER - FIRST RUN] Creating Master Scheduler '$SCHEDULER_NAME'..."
  gcloud scheduler jobs create http "$SCHEDULER_NAME" \
    --location="$REGION" \
    --project="$PROJECT_ID" \
    --schedule="$TARGET_CRON" \
    --time-zone="$TARGET_TZ" \
    --uri="$FUNC_URL" \
    --http-method=POST \
    --oidc-service-account-email="$SA_EMAIL"
fi
```

### 6.5 `.gitlab-ci.yml`
```yaml
stages:
  - sync_schedulers

variables:
  GCP_PROJECT_ID: "project-23b4d130-a5d8-4d92-806"
  GCP_REGION: "asia-south1"
  FUNCTION_NAME: "resume-schedulers-fn"
  SCHEDULER_NAME: "master-morning-resumer"
  TARGET_CRON: "0 8 * * *"
  TARGET_TZ: "Asia/Kolkata"
  PYTHON_RUNTIME: "python312"

sync_resumer_pipeline:
  stage: sync_schedulers
  image: google/cloud-sdk:slim
  before_script:
    - apt-get update -qq && apt-get install -y -qq jq >/dev/null
  script:
    - chmod +x ./deploy.sh
    - ./deploy.sh
  rules:
    - if: $CI_COMMIT_BRANCH == $CI_DEFAULT_BRANCH
      changes:
        - ignore_list.txt
        - main.py
        - requirements.txt
        - deploy.sh
        - .gitlab-ci.yml
```

---

## 7. Standard Operating Procedure (SOP) & Verification Runbook

### 7.1 Daily Developer Workflows
* **Workflow 1 — Pause a Scheduler for Tonight Only (Auto-Resumes Tomorrow at 8:00 AM):**
  1. Navigate to **GCP Console -> Cloud Scheduler** and click **Pause** on the target scale-down job.
  2. Do **not** modify `ignore_list.txt`. The next morning at `08:00 AM IST`, `master-morning-resumer` will automatically resume the job.
* **Workflow 2 — Keep a Scheduler Paused Across Multiple Days (Exclude from Auto-Resume):**
  1. Pause the target job in the GCP Console.
  2. Open `ignore_list.txt` in the GitLab repository, add the exact scheduler job name on a new line, and commit/merge to the default branch.
  3. The GitLab CI pipeline will run the **5-second Fast Path** and add the job to `IGNORE_SCHEDULERS`.
* **Workflow 3 — Re-enable Auto-Resume for an Ignored Scheduler:**
  1. Remove or comment out (`#`) the scheduler name in `ignore_list.txt` and push to the default branch.

### 7.2 Manual Verification Command (Cloud Shell / CLI)
To manually test the Cloud Run Function with an authenticated OIDC token and an ad-hoc override payload:

```bash
FUNC_URL=$(gcloud run services describe resume-schedulers-fn --region=asia-south1 --format="value(status.url)")

curl -X POST "$FUNC_URL" \
  -H "Authorization: bearer $(gcloud auth print-identity-token)" \
  -H "Content-Type: application/json" \
  -d '{"ignore": ["optional-one-time-job-to-skip"]}'
```
