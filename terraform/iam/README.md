# terraform/iam — service accounts, Workload Identity Federation, Secret Manager

## Identities

| Service account | Used by | Project roles | Resource-scoped grants |
|---|---|---|---|
| `n8n-runtime-<env>` | Cloud Run service | `cloudsql.client`, `logging.logWriter`, `monitoring.metricWriter` | `secretmanager.secretAccessor` on the three `n8n-*` secrets **only** |
| `cicd-deployer-<env>` | GitHub Actions via WIF | `run.developer`, `cloudsql.viewer`, `artifactregistry.writer`, `logging.viewer` | `iam.serviceAccountUser` on `n8n-runtime` only |
| humans in `ops_members` | `gcloud compute ssh --tunnel-through-iap` | `iap.tunnelResourceAccessor`, `compute.osLogin` | — |

What each **cannot** do is the point: the runtime SA cannot deploy or read anything outside its three secrets; the deployer cannot read secret payloads or Postgres data; no service account key files exist anywhere (GitHub authenticates with OIDC, pinned to this repository and, in prod, to `refs/heads/main`).

## Secrets

| Secret | Content | Version written by |
|---|---|---|
| `n8n-encryption-key-<env>` | `N8N_ENCRYPTION_KEY` | this module (`random_password`), or out-of-band if `manage_encryption_key_version = false` |
| `n8n-db-password-<env>` | Postgres password | `terraform/database` (which generates it) |
| `n8n-db-user-<env>` | Postgres username | this module |

Replication is user-managed, single region, so secret bytes never leave the region the database is in.

**State caveat, stated plainly:** with `manage_encryption_key_version = true` the key is in Terraform state. That is acceptable only with an encrypted, access-controlled remote backend. If that isn't in place yet, set the variable to `false` and add the version with:

```sh
openssl rand -hex 32 | gcloud secrets versions add n8n-encryption-key-prod --data-file=- --project lz-n8n-prod-a1
```

## MFA

There is no Organization Policy constraint that "turns on MFA"; it is enforced at the identity layer. See [`docs/org-policy-mfa.md`](../../docs/org-policy-mfa.md) for the mechanism and the complementary org policies that this landing zone expects to be applied at the `landing-zone` folder.

## Validate

```sh
terraform init -backend=false && terraform validate
```
