# Postgres runbook — Cloud SQL instance backing n8n

Audience: an engineer who has never touched this stack, at 2am, with `gcloud`
installed and `roles/cloudsql.admin` on the workload project. Every command is
copy-pasteable once you set the three variables at the top.

```sh
export PROJECT=lz-n8n-prod-a1
export REGION=us-central1
export INSTANCE=prod-n8n-pg-01          # terraform output -raw instance_name
```

Facts you need before you do anything:

- **Private IP only.** No public IP, no authorized networks. Interactive `psql`
  goes through the Cloud SQL Auth Proxy from an IAP-tunnelled ops VM
  (section 6), or via `gcloud sql connect` which will not work here because it
  needs a public IP. Don't fight it; use the proxy.
- **PITR always creates a new instance.** You cannot rewind an instance in
  place. Recovery is: clone to a point in time → verify → repoint n8n → retire
  the old one.
- **n8n keeps its DB password in Secret Manager**, and Cloud Run reads it at
  revision start. Repointing n8n means "new secret version + new revision",
  not "edit an env var".

---

## 1. Check backup and PITR status (do this first, every time)

```sh
gcloud sql instances describe "$INSTANCE" --project "$PROJECT" \
  --format='yaml(settings.backupConfiguration,settings.deletionProtectionEnabled,settings.availabilityType,ipAddresses)'
```

Expected:

```yaml
settings:
  backupConfiguration:
    enabled: true
    pointInTimeRecoveryEnabled: true
    startTime: '03:00'
    transactionLogRetentionDays: 7
    backupRetentionSettings: {retainedBackups: 30, retentionUnit: COUNT}
  deletionProtectionEnabled: true
ipAddresses:
- type: PRIVATE
```

If `pointInTimeRecoveryEnabled` is false, PITR is *not* available and you are
limited to section 3 (backup restore). Turning it on (`gcloud sql instances
patch "$INSTANCE" --enable-point-in-time-recovery`) starts WAL retention from
now; it does not retroactively cover the past.

What window can you actually recover into?

```sh
gcloud sql instances get-latest-recovery-time "$INSTANCE" --project "$PROJECT"
# → earliestRecoveryTime / latestRecoveryTime (RFC 3339, UTC)
```

List the automated + on-demand backups:

```sh
gcloud sql backups list --instance "$INSTANCE" --project "$PROJECT"
```

## 2. Point-in-time recovery (the common case: "someone deleted workflows at 14:07")

### 2.1 Take an on-demand backup of the *current* state first

Even if the current state is bad, you may need it for forensics or to
salvage rows created after the incident.

```sh
gcloud sql backups create --instance "$INSTANCE" --project "$PROJECT" \
  --description "pre-PITR safety $(date -u +%Y%m%dT%H%M%SZ)"
```

### 2.2 Pick the timestamp

Use UTC, RFC 3339, and go *before* the bad event, not at it. n8n execution
logs (Cloud Logging, filter `resource.type="cloud_run_revision"`) will tell you
when the offending workflow ran; Query Insights on the instance shows the
DELETE.

```sh
export PITR_TS='2026-09-07T14:05:00Z'
```

### 2.3 Clone to a new instance at that point

The new instance must land in the **same VPC's private-services range**, so
pass the allocated range name from `terraform/networking`
(`terraform output -raw cloud_sql_peering_range_name`, e.g. `prod-n8n-cloudsql-psa`).

```sh
export RESTORED="${INSTANCE}-pitr-$(date -u +%Y%m%d%H%M)"

gcloud sql instances clone "$INSTANCE" "$RESTORED" \
  --project "$PROJECT" \
  --point-in-time "$PITR_TS" \
  --allocated-ip-range-name prod-n8n-cloudsql-psa
```

This takes 5-20 minutes. Watch it:

```sh
gcloud sql operations list --instance "$RESTORED" --project "$PROJECT" --limit 3
```

If the **source instance was deleted**, the same command works for the
retention window with one extra flag:

```sh
gcloud sql instances clone "$INSTANCE" "$RESTORED" --project "$PROJECT" \
  --point-in-time "$PITR_TS" \
  --source-instance-deletion-time '2026-09-07T15:30:00Z' \
  --allocated-ip-range-name prod-n8n-cloudsql-psa
```

### 2.4 Verify the clone before touching prod

The clone keeps the same users and passwords. From the ops VM (section 6),
point a second proxy at it and inspect:

```sh
export RESTORED_CONN=$(gcloud sql instances describe "$RESTORED" --project "$PROJECT" --format 'value(connectionName)')

cloud-sql-proxy --private-ip --port 5433 "$RESTORED_CONN" &
PGPASSWORD=$(gcloud secrets versions access latest --secret n8n-db-password-prod --project "$PROJECT") \
  psql -h 127.0.0.1 -p 5433 -U n8n -d n8n -c '
    select count(*) as workflows from workflow_entity;
    select count(*) as credentials from credentials_entity;
    select max("startedAt") as last_execution from execution_entity;'
```

`last_execution` should be at or just before `$PITR_TS`. If the workflows you
were trying to recover aren't there, pick an earlier timestamp and clone again;
clones are cheap compared to guessing.

### 2.5 Repoint n8n to the restored instance

n8n connects through the Auth Proxy sidecar, whose argument is the **instance
connection name**. That is a Terraform variable on the n8n module, so the
clean path is:

1. In `terraform/n8n` set `cloud_sql_instance_connection_name = "<RESTORED_CONN>"`
   (or, if you are driving everything from one root, change the database
   module's `instance_name_suffix` after importing the clone — see 2.7).
2. `terraform plan` → confirm the only change is the sidecar arg + a new
   revision. `terraform apply`.
3. Cloud Run rolls a new revision; n8n's startup migrations run against the
   restored DB (they are idempotent on a same-version restore).
4. Check health: `curl -fsS https://<n8n-url>/healthz` and
   `/healthz/readiness` (readiness = DB reachable).

Emergency path without Terraform (drift, fix it in Terraform afterwards):

```sh
gcloud run services update n8n-prod --project "$PROJECT" --region "$REGION" \
  --container cloud-sql-proxy \
  --args="--private-ip,--port=5432,--structured-logs,--health-check,--http-address=0.0.0.0,$RESTORED_CONN"
```

### 2.6 Freeze and retire the old instance

Do **not** delete it immediately. Stop it so it can't take writes, keep it for
the WAL retention window, then delete.

```sh
gcloud sql instances patch "$INSTANCE" --project "$PROJECT" --activation-policy NEVER
# ... a week later, once nobody needs it:
gcloud sql instances patch "$INSTANCE" --project "$PROJECT" --no-deletion-protection
gcloud sql instances delete "$INSTANCE" --project "$PROJECT"
```

### 2.7 Bring the restored instance under Terraform

The clone is real infrastructure Terraform doesn't know about. Either import it:

```sh
cd terraform/database
terraform import google_sql_database_instance.n8n "projects/$PROJECT/instances/$RESTORED"
# then set instance_name_suffix so local.name == $RESTORED, plan, expect no changes
```

or treat the clone as temporary: once verified, clone *it* back into a
Terraform-named instance with `instance_name_suffix = "02"` and a fresh
`terraform apply`, then repoint n8n a second time. The import route is faster;
the second route keeps naming tidy. Either is fine; write down which you did.

## 3. Restore from a backup (whole-instance rollback)

Use when PITR isn't available, or when you want "exactly last night's state".
Unlike PITR this **overwrites the target instance in place**, so target a fresh
instance unless you truly want to roll prod back.

```sh
gcloud sql backups list --instance "$INSTANCE" --project "$PROJECT"
export BACKUP_ID=1694000000000

# Safe variant: restore into a new, empty instance with matching config
gcloud sql instances create "${INSTANCE}-restore" --project "$PROJECT" \
  --database-version POSTGRES_16 --tier db-custom-2-8192 --region "$REGION" \
  --network "projects/$PROJECT/global/networks/prod-n8n-vpc" --no-assign-ip \
  --allocated-ip-range-name prod-n8n-cloudsql-psa

gcloud sql backups restore "$BACKUP_ID" \
  --restore-instance "${INSTANCE}-restore" \
  --backup-instance "$INSTANCE" \
  --project "$PROJECT"

# Destructive variant: roll prod itself back (n8n must be scaled to 0 first)
gcloud run services update n8n-prod --project "$PROJECT" --region "$REGION" --max-instances 0
gcloud sql backups restore "$BACKUP_ID" --restore-instance "$INSTANCE" --project "$PROJECT"
gcloud run services update n8n-prod --project "$PROJECT" --region "$REGION" --max-instances 3
```

Then verify exactly as in 2.4.

## 4. Rotate the n8n database password

The password is generated by `random_password.n8n` in `terraform/database` and
published to Secret Manager. Rotation is a Terraform change:

1. Bump `keepers.rotation` (`"v1"` → `"v2"`) in `terraform/database/main.tf`.
2. `terraform apply` in `terraform/database`: updates the Postgres role **and**
   adds a new secret version in the same apply.
3. `terraform apply` in `terraform/n8n` (or `gcloud run deploy` no-op): Cloud Run
   resolves `latest` at revision creation, so a new revision is required to
   pick up the new password. Until then, the old revision keeps working only
   as long as its pooled connections survive; do step 3 immediately.
4. Old secret versions are disabled, not destroyed (`deletion_policy = "DISABLE"`);
   destroy them after a week.

## 5. Routine checks worth automating

| Check | Command | Alert if |
|---|---|---|
| Last successful backup | `gcloud sql backups list --instance $INSTANCE --limit 1 --format 'value(status,endTime)'` | status ≠ SUCCESSFUL or older than 26h |
| PITR window | `gcloud sql instances get-latest-recovery-time $INSTANCE` | latestRecoveryTime older than 15 min |
| Disk | `cloudsql.googleapis.com/database/disk/utilization` metric | > 80 % |
| Execution table bloat | `select pg_size_pretty(pg_total_relation_size('execution_data'));` | growing faster than `EXECUTIONS_DATA_MAX_AGE` should allow → pruning isn't running |

The uptime check and alert policy in `terraform/monitoring` cover the n8n
endpoint; add a `cloudsql.googleapis.com/database/up` alert there for the
database itself if you want paging on the instance.

## 6. Getting a psql prompt (there is no public IP, and that's correct)

```sh
# 1. IAP-tunnelled SSH to an ops VM tagged iap-ssh in the mgmt subnet
gcloud compute ssh ops-vm-01 --project "$PROJECT" --zone "${REGION}-a" --tunnel-through-iap

# 2. On the VM (needs roles/cloudsql.client via its SA):
export CONN=$(gcloud sql instances describe "$INSTANCE" --project "$PROJECT" --format 'value(connectionName)')
cloud-sql-proxy --private-ip --port 5432 "$CONN" &
PGPASSWORD=$(gcloud secrets versions access latest --secret n8n-db-password-prod --project "$PROJECT") \
  psql -h 127.0.0.1 -U n8n -d n8n
```

No ops VM? Run the proxy locally through an IAP port-forward to any VM in the
VPC (`gcloud compute start-iap-tunnel`), or use a Cloud Run job with the same
sidecar. Never add a public IP or an authorized network "just for a minute".

## 7. Restore drill (quarterly)

Run sections 2.1–2.4 against **prod**, into a throwaway clone, verify counts,
delete the clone. Record the elapsed time; that number is your real RTO. A
backup nobody has restored is a hypothesis.
