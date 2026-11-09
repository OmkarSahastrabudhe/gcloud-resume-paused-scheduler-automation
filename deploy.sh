#!/usr/bin/env bash
set -euo pipefail

# Dynamic configuration via Environment Variables or active gcloud config
PROJECT_ID="${GCP_PROJECT_ID:-$(gcloud config get-value project)}"
REGION="${GCP_REGION:-asia-south1}"
FUNCTION_NAME="${FUNCTION_NAME:-resume-schedulers-fn}"
SCHEDULER_NAME="${SCHEDULER_NAME:-master-morning-resumer}"

# ---------------------------------------------------------
# Least-privilege identity split (one SA per responsibility)
#   FUNCTION_SA_EMAIL  -> Cloud Run Function runtime identity (needs Cloud Scheduler list/resume)
#   SCHEDULER_SA_EMAIL -> Master Cloud Scheduler OIDC identity (needs ONLY run.invoker on this function)
#   BUILD_SA_EMAIL     -> OPTIONAL Cloud Build identity for --source deploys.
#                         Empty = flag omitted, GCP uses the project's default Cloud Build SA.
# ---------------------------------------------------------
FUNCTION_SA_EMAIL="${FUNCTION_SA_EMAIL:?FUNCTION_SA_EMAIL must be set (Cloud Run Function runtime SA)}"
SCHEDULER_SA_EMAIL="${SCHEDULER_SA_EMAIL:?SCHEDULER_SA_EMAIL must be set (Master Scheduler OIDC invoker SA)}"
BUILD_SA_EMAIL="${BUILD_SA_EMAIL:-}"

BUILD_SA_FLAG=()
if [[ -n "$BUILD_SA_EMAIL" ]]; then
  BUILD_SA_FLAG=(--build-service-account="projects/${PROJECT_ID}/serviceAccounts/${BUILD_SA_EMAIL}")
fi

TARGET_CRON="${TARGET_CRON:-0 8 * * *}"
TARGET_TZ="${TARGET_TZ:-Asia/Kolkata}"
PYTHON_RUNTIME="${PYTHON_RUNTIME:-python312}"

if [[ "$FUNCTION_SA_EMAIL" == "$SCHEDULER_SA_EMAIL" ]]; then
  echo "❌ FUNCTION_SA_EMAIL and SCHEDULER_SA_EMAIL must be different service accounts." >&2
  exit 1
fi

# 0. Pre-flight: fail fast if any SA does not exist (or runner cannot see it)
for sa in "$FUNCTION_SA_EMAIL" "$SCHEDULER_SA_EMAIL" ${BUILD_SA_EMAIL:+"$BUILD_SA_EMAIL"}; do
  if ! gcloud iam service-accounts describe "$sa" --project="$PROJECT_ID" >/dev/null 2>&1; then
    echo "❌ Service account not found or not accessible: ${sa}" >&2
    exit 1
  fi
done

# 1. Cleanly parse ignore_list.txt (strip # comments, blank lines, CR, and spaces)
IGNORE_LIST=$(grep -v '^[[:space:]]*#' ignore_list.txt | grep -v '^[[:space:]]*$' | tr -d ' \r' | paste -sd ',' - || true)

# 2. Calculate SHA256 Fingerprint of main.py + requirements.txt + PYTHON_RUNTIME
LOCAL_CODE_HASH=$( (cat main.py requirements.txt; echo "$PYTHON_RUNTIME") | sha256sum | awk '{print $1}' )

ENV_VARS="^@^GCP_PROJECT_ID=${PROJECT_ID}@GCP_REGION=${REGION}@MASTER_SCHEDULER_NAME=${SCHEDULER_NAME}@IGNORE_SCHEDULERS=${IGNORE_LIST}@CODE_HASH=${LOCAL_CODE_HASH}"

echo "========================================================"
echo "Dynamic Project ID : ${PROJECT_ID}"
echo "Dynamic Region     : ${REGION}"
echo "Python Runtime     : ${PYTHON_RUNTIME}"
echo "Function SA        : ${FUNCTION_SA_EMAIL}"
echo "Scheduler SA       : ${SCHEDULER_SA_EMAIL}"
echo "Build SA           : ${BUILD_SA_EMAIL:-<GCP default Cloud Build SA>}"
echo "Parsed Ignore List : [${IGNORE_LIST}]"
echo "Target Cron Timer  : ${TARGET_CRON} (${TARGET_TZ})"
echo "Local Code Hash    : ${LOCAL_CODE_HASH}"
echo "========================================================"

deploy_function_from_source() {
  gcloud run deploy "$FUNCTION_NAME" \
    --source=. \
    --function=hello_http \
    --base-image="$PYTHON_RUNTIME" \
    --region="$REGION" \
    --project="$PROJECT_ID" \
    --service-account="$FUNCTION_SA_EMAIL" \
    ${BUILD_SA_FLAG[@]+"${BUILD_SA_FLAG[@]}"} \
    --no-allow-unauthenticated \
    --set-env-vars="$ENV_VARS"
}

# ---------------------------------------------------------
# PART A: CLOUD RUN FUNCTION CHECK & UPDATE
# ---------------------------------------------------------
if SERVICE_JSON=$(gcloud run services describe "$FUNCTION_NAME" --region="$REGION" --project="$PROJECT_ID" --format=json 2>/dev/null); then
  DEPLOYED_HASH=$(echo "$SERVICE_JSON" | jq -r '.spec.template.spec.containers[0].env[]? | select(.name=="CODE_HASH") | .value // empty' || true)
  DEPLOYED_IGNORE=$(echo "$SERVICE_JSON" | jq -r '.spec.template.spec.containers[0].env[]? | select(.name=="IGNORE_SCHEDULERS") | .value // empty' || true)
  DEPLOYED_SA=$(echo "$SERVICE_JSON" | jq -r '.spec.template.spec.serviceAccountName // empty' || true)

  echo "Deployed Code Hash : ${DEPLOYED_HASH:-<none>}"
  echo "Deployed Ignore    : [${DEPLOYED_IGNORE}]"
  echo "Deployed Func SA   : ${DEPLOYED_SA:-<none>}"
  echo "--------------------------------------------------------"

  if [[ "$LOCAL_CODE_HASH" != "$DEPLOYED_HASH" ]]; then
    echo "🔨 [FUNCTION - CODE/RUNTIME CHANGED] Deploying updated source / runtime..."
    deploy_function_from_source
  elif [[ "$IGNORE_LIST" != "$DEPLOYED_IGNORE" || "$FUNCTION_SA_EMAIL" != "$DEPLOYED_SA" ]]; then
    echo "⚡ [FUNCTION - FAST PATH] Code unchanged! Updating ignore list / runtime SA only..."
    gcloud run services update "$FUNCTION_NAME" \
      --region="$REGION" \
      --project="$PROJECT_ID" \
      --service-account="$FUNCTION_SA_EMAIL" \
      --update-env-vars="$ENV_VARS"
  else
    echo " [FUNCTION - SKIP] Code Hash, Ignore List and Runtime SA are already identical. Zero changes needed!"
  fi
else
  echo " [FUNCTION - FIRST RUN] Creating Function from scratch..."
  deploy_function_from_source
fi

FUNC_URL=$(gcloud run services describe "$FUNCTION_NAME" --region="$REGION" --project="$PROJECT_ID" --format="value(status.url)")

# ---------------------------------------------------------
# PART A.2: GRANT INVOKER TO SCHEDULER SA (resource-level, idempotent)
# Scoped to THIS service only — not a project-wide roles/run.invoker grant.
# ---------------------------------------------------------
echo " [IAM] Ensuring ${SCHEDULER_SA_EMAIL} has roles/run.invoker on ${FUNCTION_NAME}..."
gcloud run services add-iam-policy-binding "$FUNCTION_NAME" \
  --region="$REGION" \
  --project="$PROJECT_ID" \
  --member="serviceAccount:${SCHEDULER_SA_EMAIL}" \
  --role="roles/run.invoker" \
  --quiet >/dev/null

# ---------------------------------------------------------
# PART B: MASTER CLOUD SCHEDULER CHECK & UPDATE
# ---------------------------------------------------------
if JOB_JSON=$(gcloud scheduler jobs describe "$SCHEDULER_NAME" --location="$REGION" --project="$PROJECT_ID" --format=json 2>/dev/null); then
  CURRENT_CRON=$(echo "$JOB_JSON" | jq -r '.schedule // empty')
  CURRENT_TZ=$(echo "$JOB_JSON" | jq -r '.timeZone // empty')
  CURRENT_URI=$(echo "$JOB_JSON" | jq -r '.httpTarget.uri // empty')
  CURRENT_OIDC_SA=$(echo "$JOB_JSON" | jq -r '.httpTarget.oidcToken.serviceAccountEmail // empty')

  echo "Scheduler Cron/TZ  : ${CURRENT_CRON} (${CURRENT_TZ})"
  echo "Scheduler OIDC SA  : ${CURRENT_OIDC_SA:-<none>}"

  if [[ "$CURRENT_CRON" == "$TARGET_CRON" && "$CURRENT_TZ" == "$TARGET_TZ" \
        && "${CURRENT_URI%/}" == "${FUNC_URL%/}" && "$CURRENT_OIDC_SA" == "$SCHEDULER_SA_EMAIL" ]]; then
    echo " [SCHEDULER - SKIP] Master Scheduler schedule, target and OIDC SA already match."
  else
    echo " [SCHEDULER - UPDATE] Reconciling schedule / target / OIDC SA..."
    gcloud scheduler jobs update http "$SCHEDULER_NAME" \
      --location="$REGION" \
      --project="$PROJECT_ID" \
      --schedule="$TARGET_CRON" \
      --time-zone="$TARGET_TZ" \
      --uri="$FUNC_URL" \
      --http-method=POST \
      --oidc-service-account-email="$SCHEDULER_SA_EMAIL" \
      --oidc-token-audience="$FUNC_URL"
  fi
else
  echo " [SCHEDULER - FIRST RUN] Creating Master Scheduler '$SCHEDULER_NAME'..."
  gcloud scheduler jobs create http "$SCHEDULER_NAME" \
    --location="$REGION" \
    --project="$PROJECT_ID" \
    --schedule="$TARGET_CRON" \
    --time-zone="$TARGET_TZ" \
    --uri="$FUNC_URL" \
    --http-method=POST \
    --oidc-service-account-email="$SCHEDULER_SA_EMAIL" \
    --oidc-token-audience="$FUNC_URL"
fi
