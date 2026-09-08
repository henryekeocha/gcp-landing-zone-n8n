# n8n operations — redeploy, health, credentials

Companion to `terraform/n8n`. Assumes:

```sh
export PROJECT=lz-n8n-prod-a1
export REGION=us-central1
export SERVICE=n8n-prod
export REGISTRY=us-central1-docker.pkg.dev/lz-n8n-shared-a1/images
```

## 1. How a deploy works (and the one manual step)

```
PR → ci.yml (fmt + validate, no creds)
merge → build.yml (docker build n8n/Dockerfile, no push)      ← automated, credential-free
        ↓
  MANUAL: push image + roll out                                ← needs a real GCP org
```

The manual step, run by someone with the `cicd-deployer` role (or from a
GitHub Actions job using Workload Identity Federation once a real org exists):

```sh
# 0. authenticate once per shell
gcloud auth login
gcloud auth configure-docker us-central1-docker.pkg.dev

# 1. build + push the pinned image
export N8N_VERSION=2.37.11
docker build --build-arg N8N_VERSION=$N8N_VERSION -t $REGISTRY/n8n:$N8N_VERSION n8n/
docker push $REGISTRY/n8n:$N8N_VERSION

# 2. first-ever deploy: Terraform creates the service with this image
cd terraform/n8n && terraform apply -var image=$REGISTRY/n8n:$N8N_VERSION

# 3. every later image bump: roll the n8n container only, Terraform ignores the tag
gcloud run deploy $SERVICE --project $PROJECT --region $REGION \
  --image $REGISTRY/n8n:$N8N_VERSION --container n8n
```

Why image bumps bypass Terraform: `lifecycle.ignore_changes` on the n8n
container image lets CI roll versions without a Terraform apply, while
Terraform still owns env vars, secrets, probes, scaling and the sidecar. Change
*those* in Terraform; change *the image tag* with `gcloud run deploy`.

### Rollback

Cloud Run keeps every revision. Rolling back is a traffic move, not a rebuild:

```sh
gcloud run revisions list --service $SERVICE --project $PROJECT --region $REGION
gcloud run services update-traffic $SERVICE --project $PROJECT --region $REGION \
  --to-revisions n8n-prod-00041-abc=100
```

Caveat: n8n runs DB migrations forward on boot. Rolling the *image* back
after a major-version upgrade that migrated the schema may not work; check
the n8n release notes for "irreversible migration" before upgrading, and
take an on-demand Cloud SQL backup first (`docs/postgres-runbook.md` §2.1).

## 2. Health

| Endpoint | Meaning | Used by |
|---|---|---|
| `GET /healthz` | process is up | Cloud Run startup probe |
| `GET /healthz/readiness` | process is up **and** DB reachable | Cloud Run liveness probe, uptime check |
| `GET /metrics` | Prometheus metrics (`N8N_METRICS=true`) | optional Managed Prometheus scrape |
| sidecar `:9090/readiness` | proxy has a live connection to Cloud SQL | proxy startup/liveness probes |

Quick triage from a laptop:

```sh
URL=$(gcloud run services describe $SERVICE --project $PROJECT --region $REGION --format 'value(status.url)')
curl -fsS $URL/healthz && echo " process ok"
curl -fsS $URL/healthz/readiness && echo " db ok"
```

Where the logs are, in order of usefulness during an incident:

```sh
# n8n container
gcloud logging read 'resource.type="cloud_run_revision" AND resource.labels.service_name="'$SERVICE'" AND labels.container_name="n8n"' \
  --project $PROJECT --limit 100 --format 'value(timestamp,textPayload,jsonPayload.message)'

# proxy sidecar (connection refused / IAM denied show up HERE, not in n8n)
gcloud logging read 'resource.type="cloud_run_revision" AND resource.labels.service_name="'$SERVICE'" AND labels.container_name="cloud-sql-proxy"' \
  --project $PROJECT --limit 50
```

Failure signatures:

| Symptom | Look at | Usual cause |
|---|---|---|
| revision never becomes ready, proxy logs `permission denied` | proxy log | runtime SA lost `roles/cloudsql.client` |
| proxy healthy, n8n logs `ECONNREFUSED 127.0.0.1:5432` | n8n log | `depends_on` missing or proxy `--port` changed |
| n8n logs `password authentication failed` | secret versions | DB password rotated without a new revision (§4) |
| n8n boots, credentials show "could not decrypt" | encryption key | `N8N_ENCRYPTION_KEY` changed; restore the previous secret version |
| schedule triggers fire twice | Cloud Run scaling | `max_instance_count` > 1 in regular mode |
| schedule triggers stop after idle | Cloud Run CPU | `cpu_idle` was set true |

## 3. How workflow credentials are stored

n8n stores every credential (API keys, OAuth tokens, DB passwords used by
nodes) in the `credentials_entity` table in Postgres, encrypted with
AES-256 using **`N8N_ENCRYPTION_KEY`**. The key is the only thing that turns
that table from ciphertext into secrets, which is why:

- it lives in Secret Manager (`n8n-encryption-key-<env>`), readable by the
  runtime SA and nobody else;
- the Postgres backup alone is *not* a usable backup of credentials — a
  restore into a fresh environment also needs the key version that was
  current at backup time. Keep old versions disabled, not destroyed;
- it must never be printed, logged, or put in a `.tfvars`.

Two different rotations, often confused:

### 3a. Rotating a credential *inside* n8n (e.g. a Slack token)

Editor → Credentials → edit → save. No infra change. n8n re-encrypts on save.

### 3b. Rotating `N8N_ENCRYPTION_KEY` itself

There is no online re-key. The procedure is export → new key → import:

```sh
# 0. announce a maintenance window; take a Cloud SQL on-demand backup
# 1. export with the OLD key still active (from the running container)
gcloud run jobs execute n8n-export ... # or exec locally against the DB via IAP:
n8n export:credentials --all --decrypted --output=/tmp/creds.json   # plaintext! handle accordingly
n8n export:workflow    --all --output=/tmp/workflows.json

# 2. add the NEW key version
openssl rand -hex 32 | gcloud secrets versions add n8n-encryption-key-prod --data-file=- --project $PROJECT

# 3. wipe encrypted rows (they are unreadable under the new key anyway), roll a revision
psql ... -c 'truncate credentials_entity cascade;'
gcloud run deploy $SERVICE --project $PROJECT --region $REGION --image $(current image) --container n8n

# 4. re-import under the new key, then shred the plaintext export
n8n import:credentials --input=/tmp/creds.json
n8n import:workflow    --input=/tmp/workflows.json
shred -u /tmp/creds.json
```

Do this rarely (key compromise, staff departure with DB access). Prefer 3a for
everything else.

## 4. Rotating the DB password

Owned by `terraform/database` (`random_password.n8n.keepers.rotation`). Full
sequence in `docs/postgres-runbook.md` §4. The n8n-side step is just:

```sh
gcloud run deploy $SERVICE --project $PROJECT --region $REGION \
  --image $(gcloud run services describe $SERVICE --project $PROJECT --region $REGION --format 'value(spec.template.spec.containers[1].image)') \
  --container n8n
```

because `secret_key_ref.version = "latest"` is resolved at revision creation.

## 5. Scaling out (when one instance isn't enough)

Regular mode is capped at one instance by design. The path to more is n8n
**queue mode**: a Redis (Memorystore) instance, `EXECUTIONS_MODE=queue`, one
"main" Cloud Run service (webhooks, UI, triggers, `max = 1`) and a separate
"worker" Cloud Run service running `n8n worker` with `min/max` set freely.
Both share the same Postgres and encryption key. That is a new Terraform
module, not a variable change; the seams for it are already here (secrets by
ID, SA by email, proxy sidecar block reusable as-is).
