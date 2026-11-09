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
