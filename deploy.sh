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
    echo " [FUNCTION - SKIP] Both Code Hash and Ignore List are already identical. Zero changes needed!"
  fi
else
  echo " [FUNCTION - FIRST RUN] Creating Function from scratch..."
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
    echo " [SCHEDULER - SKIP] Master Scheduler is already set to '${CURRENT_CRON}' (${CURRENT_TZ})."
  else
    echo " [SCHEDULER - UPDATE] Updating timer from '${CURRENT_CRON}' to '${TARGET_CRON}'..."
    gcloud scheduler jobs update http "$SCHEDULER_NAME" \
      --location="$REGION" \
      --project="$PROJECT_ID" \
      --schedule="$TARGET_CRON" \
      --time-zone="$TARGET_TZ" \
      --uri="$FUNC_URL"
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
    --oidc-service-account-email="$SA_EMAIL"
fi
