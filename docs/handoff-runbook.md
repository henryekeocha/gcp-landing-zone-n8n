# Hand-off runbook

You are the new owner of this stack. This page is the map; the per-topic
runbooks have the detail. Read this once end-to-end, then keep it open during
incidents.

| Topic | Detailed doc |
|---|---|
| What exists and why | [`architecture.md`](architecture.md) |
| Postgres: backups, PITR restore, password rotation, psql access | [`postgres-runbook.md`](postgres-runbook.md) |
| n8n: deploy, rollback, health, credential/encryption-key rotation, scaling | [`n8n-operations.md`](n8n-operations.md) |
| MFA and org policies | [`org-policy-mfa.md`](org-policy-mfa.md) |

## 0. First hour: access and orientation

```sh
gcloud auth login                       # your human identity; 2SV enforced by the org
gcloud config set project lz-n8n-prod-a1
gcloud config set run/region us-central1

# What is running?
gcloud run services list
gcloud sql instances list
gcloud secrets list
gcloud iam service-accounts list
gcloud monitoring uptime list-configs 2>/dev/null || echo "uptime checks: see console → Monitoring → Uptime"
```

Things you should **not** have and should not ask for:

- a service account key file (org policy blocks creating them; CI uses WIF)
- a public IP on the Cloud SQL instance
- SSH from your laptop's IP (use IAP)

## 1. From zero to a running environment (the only manual path)

This repo is validate-only. Standing it up for real, in order:

| Step | Command / doc | Needs |
|---|---|---|
| 1 | Enforce 2SV in Cloud Identity | Workspace super-admin, `org-policy-mfa.md` §Layer 1 |
| 2 | `terraform/projects`: `terraform apply` | org admin: `resourcemanager.folders.create`, `billing.user` |
| 3 | Apply org policies at the `landing-zone` folder | `orgpolicy.policyAdmin`, `org-policy-mfa.md` §Layer 2 |
| 4 | `terraform/networking` (per env) | project owner on the workload project |
| 5 | `terraform/iam` (per env) | same; note the WIF provider output |
| 6 | `terraform/database` (per env) | same; ~10 min for instance creation |
| 7 | Build + push the image | `n8n-operations.md` §1; Artifact Registry repo in the shared project |
| 8 | `terraform/n8n` (per env) | same; needs `image` var |
| 9 | Map DNS: `public_hostname` → Cloud Run domain mapping or HTTPS LB | DNS admin |
| 10 | `terraform/monitoring` (per env) | same |
| 11 | Open the editor, create the owner account, **immediately** back up the encryption key location in your password manager notes (the key itself stays in Secret Manager) | — |

Remote state: use a GCS bucket in the shared project with uniform bucket-level
access, versioning, and a CMEK key; the encryption key and DB password pass
through state. Do not run any of this with local state beyond a first
experiment.

Start with `dev`. Prod is the same modules with `environment = "prod"`, which
flips Cloud SQL to REGIONAL HA and pins the WIF condition to `main`.

## 2. Routine operations

| Task | How | Frequency |
|---|---|---|
| Bump n8n version | edit `ARG N8N_VERSION` in `n8n/Dockerfile` → PR → merge builds → push + `gcloud run deploy` (`n8n-operations.md` §1) | monthly; read release notes for irreversible migrations |
| Bump Auth Proxy | `cloud_sql_proxy_image` var in `terraform/n8n` → apply | quarterly |
| Check backups ran | `postgres-runbook.md` §1 | weekly, or alert on it |
| Restore drill | `postgres-runbook.md` §7 | quarterly; record the elapsed time |
| Rotate DB password | `postgres-runbook.md` §4 | 90 days or on staff change |
| Rotate `N8N_ENCRYPTION_KEY` | `n8n-operations.md` §3b | only on compromise; it is disruptive |
| Rotate a workflow credential (Slack token etc.) | in the n8n editor | as the third party requires |
| Review IAM | `gcloud projects get-iam-policy lz-n8n-prod-a1` — expect only the two SAs, the ops group, and Google-managed agents | quarterly |
| Prune execution history | automatic (`EXECUTIONS_DATA_MAX_AGE=336h`, max 50 k); tune in `terraform/n8n` if the DB grows | as needed |

## 3. Secret rotation, all of them in one place

| Secret | Lives in | Rotate by | Then |
|---|---|---|---|
| `n8n-db-password-<env>` | Secret Manager (version written by `terraform/database`) | bump `random_password.n8n.keepers.rotation`, apply | new Cloud Run revision (`n8n-operations.md` §4) |
| `n8n-encryption-key-<env>` | Secret Manager (version written by `terraform/iam` or by hand) | export creds → new version → truncate → new revision → import (`n8n-operations.md` §3b) | verify a credential decrypts in the editor |
| Workflow credentials | `credentials_entity` table, AES-encrypted | in the editor | nothing |
| GitHub → GCP | no secret; OIDC | nothing to rotate; revoke by removing the WIF binding | — |
| Human access | Google identity + 2SV | Workspace admin | — |

Rule: rotating anything that Cloud Run reads at startup requires a **new
revision**. `gcloud run services update ... --update-env-vars` on an unrelated
var is a cheap way to force one.

## 4. Incident triage

### 4.1 "n8n is down" (uptime alert fired)

```
readiness check failing
├─ Cloud SQL down alert ALSO firing?
│    yes → §4.2
│    no  ↓
├─ gcloud run services describe n8n-prod --format 'value(status.conditions)'
│    latest revision not Ready?
│      → gcloud run revisions describe <rev> ; read cloud-sql-proxy logs FIRST
│         "permission denied"        → runtime SA lost cloudsql.client (IAM change?)
│         "dial tcp ... i/o timeout" → VPC egress / peering broken (networking change?)
│         proxy fine, n8n "ECONNREFUSED 127.0.0.1:5432" → sidecar args / depends_on changed
│         n8n "password authentication failed" → secret rotated without new revision (§3)
│         n8n "could not decrypt"    → N8N_ENCRYPTION_KEY changed; re-enable previous version, new revision
│    revision Ready but check failing?
│      → DNS / domain mapping / LB. curl the *.run.app URL directly:
│        gcloud run services describe n8n-prod --format 'value(status.url)'
│        works there → DNS/LB problem, not n8n
└─ Rolled out recently? → roll back traffic (n8n-operations.md §1 Rollback)
```

### 4.2 "Cloud SQL down"

```sh
gcloud sql operations list --instance prod-n8n-pg-01 --limit 5     # maintenance? failover in progress?
gcloud sql instances describe prod-n8n-pg-01 --format 'value(state,settings.activationPolicy)'
```

- `state: RUNNABLE`, ops show a failover: wait it out (REGIONAL HA, ~60 s), n8n's liveness probe restarts it.
- `activationPolicy: NEVER`: someone stopped it. `gcloud sql instances patch ... --activation-policy ALWAYS`.
- Disk full: `gcloud sql instances patch ... --storage-size` (autoresize is on; if it hit `disk_autoresize_limit`, raise it).
- Data corruption / bad deploy wiped tables: `postgres-runbook.md` §2 (PITR).

### 4.3 "Workflows didn't run on schedule"

Schedule and polling triggers run inside the single n8n instance.

1. Was there a revision rollout at that time? Triggers miss the window during restart; n8n does not backfill.
2. `max_instance_count` still 1 and `cpu_idle` still false? (`terraform/n8n`). If someone "scaled up" in the console, triggers fire twice or not at all.
3. `GENERIC_TIMEZONE` correct? Cron expressions are interpreted in it.

### 4.4 "A credential stopped working"

Rotate it in the editor (§3). If **all** credentials fail at once, the
encryption key changed: see 4.1's last branch.

### 4.5 "I need to look at the database"

`postgres-runbook.md` §6. Through an IAP-tunnelled VM with the proxy. If you
find yourself adding an authorized network or a public IP, stop.

### 4.6 Suspected compromise

1. Revoke: remove the WIF binding (`google_service_account_iam_member.github_impersonates_deployer`) and the ops group's IAP role; apply.
2. Rotate DB password (§3), then decide on the encryption key (§3; disruptive, do it if the DB or the key's secret could have been read).
3. Roll every workflow credential in the editor.
4. Audit: `gcloud logging read 'protoPayload.authenticationInfo.principalEmail="n8n-runtime-prod@..."' --freshness 7d`.
5. Only then investigate.

## 5. Change management

- Every change is a PR. CI runs `fmt`, `validate`, `tflint`, `hadolint`,
  `actionlint` and the public-SSH guard without credentials.
- `terraform plan` output is reviewed by a human before `apply`; there is no
  auto-apply and the deployer SA cannot change IAM, so a rogue plan cannot
  escalate.
- Two resources carry `deletion_protection`: the Cloud SQL instance and the
  Cloud Run service. Removing it is a separate PR with the word "destroy" in
  the title.
- Version pins: n8n (`n8n/Dockerfile`), Auth Proxy (`terraform/n8n`), Google
  provider (`versions.tf`, `>= 6, < 8`), Terraform (`>= 1.6`).

## 6. Known gaps, honestly

- No HTTPS load balancer / Cloud Armor / IAP in front of the editor yet;
  n8n's own login is the only gate. Add it before exposing to the internet
  in an org that forbids `allUsers` invoker.
- Single instance = single point of failure for scheduling; Cloud Run restarts
  it in seconds, but queue mode is the real answer at scale (`n8n-operations.md` §5).
- No log-based alert on the proxy sidecar; the readiness check catches the
  effect, not the cause.
- Org policies and Cloud Identity 2SV are documented, not applied; they need
  a real org.
