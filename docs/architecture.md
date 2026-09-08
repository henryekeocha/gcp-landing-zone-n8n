# Architecture

## Resource hierarchy

```mermaid
flowchart TB
    ORG["organizations/ORG_ID"]
    LZ["folder: landing-zone<br/><i>org policies applied here</i>"]
    FS["folder: shared"]
    FD["folder: dev"]
    FP["folder: prod"]
    PS["project: lz-n8n-shared-a1<br/>Artifact Registry · KMS · Cloud Build"]
    PD["project: lz-n8n-dev-a1<br/>VPC · Cloud SQL · Cloud Run · secrets"]
    PP["project: lz-n8n-prod-a1<br/>VPC · Cloud SQL (HA) · Cloud Run · secrets"]

    ORG --> LZ
    LZ --> FS --> PS
    LZ --> FD --> PD
    LZ --> FP --> PP
```

Terraform: `terraform/projects`. Each workload project then gets one instance
each of `networking`, `iam`, `database`, `n8n`, `monitoring`.

## Runtime data flow (one workload project)

```mermaid
flowchart LR
    subgraph internet["Internet"]
        USER["Operator browser<br/>(n8n editor)"]
        WH["External systems<br/>(webhooks in / APIs out)"]
        GH["GitHub Actions"]
    end

    subgraph gcp["project: lz-n8n-prod-a1"]
        direction TB

        subgraph run["Cloud Run service n8n-prod (1 instance, CPU always on)"]
            direction LR
            N8N["container: n8n<br/>:5678<br/>DB_TYPE=postgresdb<br/>DB_POSTGRESDB_HOST=127.0.0.1"]
            PROXY["sidecar: cloud-sql-proxy<br/>--private-ip --port=5432<br/>health :9090"]
            N8N -- "localhost:5432<br/>(plaintext inside sandbox)" --> PROXY
        end

        SM["Secret Manager<br/>n8n-encryption-key-prod<br/>n8n-db-password-prod<br/>n8n-db-user-prod"]
        SA_RT["SA: n8n-runtime-prod<br/>cloudsql.client · secretAccessor (3 secrets)"]
        SA_CI["SA: cicd-deployer-prod<br/>run.developer · artifactregistry.writer<br/>actAs n8n-runtime only"]
        WIF["Workload Identity Pool<br/>github-prod · repo + main-branch pinned"]

        subgraph vpc["VPC prod-n8n-vpc"]
            direction TB
            APP["subnet prod-n8n-app<br/>10.10.0.0/22 · PGA on"]
            MGMT["subnet prod-n8n-mgmt<br/>10.10.4.0/24"]
            OPS["ops VM (optional)<br/>tag: iap-ssh · no external IP"]
            NAT["Cloud NAT"]
            PSA["reserved /20<br/>Service Networking peering"]
            MGMT --- OPS
            MGMT --> NAT
        end

        SQL[("Cloud SQL Postgres 16<br/>prod-n8n-pg-01<br/>private IP only · REGIONAL HA<br/>daily backup · PITR 7 d<br/>deletion protection")]

        UPT["Uptime check<br/>GET /healthz/readiness × 3 regions"]
        ALERT["Alert policies<br/>n8n down · Cloud SQL down"]
    end

    IAP["Identity-Aware Proxy<br/>TCP forwarding 35.235.240.0/20"]

    USER -- "HTTPS" --> N8N
    WH <-- "HTTPS webhooks / API calls" --> N8N
    run -- "direct VPC egress<br/>PRIVATE_RANGES_ONLY" --> APP
    PROXY -- "TLS via peering" --> PSA --> SQL
    SM -. "env at revision start" .-> N8N
    SA_RT -. "runs as" .-> run
    SA_RT -. "reads" .-> SM
    GH -- "OIDC" --> WIF --> SA_CI
    SA_CI -- "gcloud run deploy" --> run
    USER -- "gcloud compute ssh --tunnel-through-iap" --> IAP --> OPS
    OPS -. "cloud-sql-proxy + psql<br/>(runbook only)" .-> SQL
    UPT --> N8N
    UPT --> ALERT
    SQL -. "database/up metric" .-> ALERT
```

## What sits where, and why

| Concern | Where | Reasoning |
|---|---|---|
| Workflow definitions, credentials (encrypted), execution history | Cloud SQL Postgres | survives revisions; backed up; PITR. SQLite on Cloud Run's ephemeral FS would lose everything on deploy |
| Encryption key for stored credentials | Secret Manager, runtime SA only | the DB backup is useless without it; the deployer must not be able to read it |
| DB password | Secret Manager, written by `terraform/database` | Terraform generates it; n8n reads it; humans never see it |
| DB network path | Auth Proxy sidecar → private IP over VPC peering | TLS + IAM-authenticated connection; no public IP on the instance, ever |
| Cloud Run → VPC | direct VPC egress into `app` subnet | no Serverless VPC connector to size and pay for |
| Human SSH | IAP TCP forwarding only | no `0.0.0.0/0:22` anywhere; identity + 2SV enforced by IAP |
| CI identity | Workload Identity Federation | no service account keys exist to leak |
| Deploy vs run | two service accounts | CI compromise ≠ data compromise |
| Cloud Run scaling | `min = max = 1`, `cpu_idle = false` | n8n regular mode runs triggers in-process; more instances need queue mode |
| Alerting | readiness endpoint, not liveness | readiness includes the DB path |

## Trust boundaries

1. **Internet → Cloud Run**: TLS at Google's front end; n8n's own auth for the editor, per-workflow auth for webhooks. Optional: HTTPS LB + Cloud Armor + IAP when `iam.allowedPolicyMemberDomains` forbids `allUsers` invoker.
2. **Cloud Run → Cloud SQL**: IAM (`cloudsql.client`) + TLS via the proxy; network path is private peering, unreachable from outside the VPC.
3. **Cloud Run → Secret Manager**: per-secret IAM to the runtime SA; resolved once per revision.
4. **GitHub → GCP**: OIDC token exchange, pinned to repository (and `main` for prod); can deploy, cannot read secrets or data.
5. **Human → VMs**: IAP only; `roles/iap.tunnelResourceAccessor` + OS Login.

## Module dependency order

```
projects → networking → iam → database → n8n → monitoring
```

`database` needs `networking` (peering) and `iam` (secret to write the
password into). `n8n` needs all three. `monitoring` needs `n8n`'s hostname and
`database`'s instance name. In a real root module these are `module` blocks
with outputs wired together; here each directory validates standalone with
explicit variables so CI can check every module without credentials.
