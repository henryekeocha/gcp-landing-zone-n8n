# terraform/n8n — n8n on Cloud Run with a Cloud SQL Auth Proxy sidecar

```
Cloud Run service n8n-<env>  (min = max = 1 instance, CPU always on)
├── cloud-sql-proxy   gcr.io/cloud-sql-connectors/cloud-sql-proxy  --private-ip --port=5432 --health-check
│                     startup probe /startup:9090 · liveness /liveness:9090
└── n8n               depends_on = [cloud-sql-proxy]
                      DB_TYPE=postgresdb · DB_POSTGRESDB_HOST=127.0.0.1
                      N8N_ENCRYPTION_KEY / DB user + password ← Secret Manager (latest)
                      startup probe /healthz:5678 · liveness /healthz/readiness:5678
    vpc_access: direct VPC egress → `app` subnet, PRIVATE_RANGES_ONLY
```

## Things in here that are n8n-specific

| Setting | Why |
|---|---|
| `DB_TYPE=postgresdb` + `EXECUTIONS_DATA_*` | execution history persists in Postgres and is pruned (14 d / 50 k); default SQLite would sit on the container's ephemeral FS |
| `min = max = 1`, `cpu_idle = false` | schedule/polling triggers run in-process in regular mode; >1 instance double-fires, throttled CPU stalls them |
| `DB_POSTGRESDB_SSL_ENABLED=false` | n8n talks plaintext to the proxy on localhost; the proxy does TLS to Cloud SQL, which enforces `ENCRYPTED_ONLY` |
| `N8N_PROXY_HOPS=1` | Cloud Run terminates TLS in front; n8n needs to trust `X-Forwarded-*` for correct webhook URLs and rate-limit keys |
| `N8N_RUNNERS_ENABLED=true` | Code nodes execute in an isolated task runner |
| `WEBHOOK_URL` / `N8N_EDITOR_BASE_URL` | generated webhook URLs must use the public hostname, not the `*.run.app` one |
| sidecar `--max-sigterm-delay=30s` | proxy keeps serving during n8n's graceful shutdown |

## Secrets

Three env vars are `value_source.secret_key_ref` to Secret Manager and nothing
secret is in Terraform variables. `version = "latest"` is resolved when a
revision is created, so **rotating a secret requires a new revision** (see
`docs/n8n-operations.md`).

## Image

`n8n/Dockerfile` at the repo root wraps the official image at a pinned version.
CI builds it (`.github/workflows/build.yml`); pushing to Artifact Registry and
`gcloud run deploy` are the documented manual step. Terraform ignores changes
to the n8n container image so CI and Terraform don't fight.

## Validate

```sh
terraform init -backend=false && terraform validate
```
