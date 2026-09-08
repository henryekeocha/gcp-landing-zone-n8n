# terraform/database — Cloud SQL for PostgreSQL

| Requirement | How it's met |
|---|---|
| Private IP only | `ipv4_enabled = false`, `private_network = <vpc>`, no `authorized_networks` |
| Automated backups | daily at `backup_start_time` (03:00 UTC), 30 retained |
| Point-in-time recovery | `point_in_time_recovery_enabled = true`, 7 days of WAL |
| Deletion protection | Terraform `deletion_protection` **and** API `deletion_protection_enabled` |
| Encryption in transit | `ssl_mode = ENCRYPTED_ONLY`; the Auth Proxy sidecar handles TLS |
| HA in prod | `availability_type` defaults to `REGIONAL` when `environment = "prod"` |
| Credentials | password generated here, delivered to n8n only via Secret Manager |

Sizing default is `db-custom-2-8192` (2 vCPU, 8 GiB); n8n's load is dominated
by the `execution_entity` / `execution_data` tables, and the pruning settings
in `terraform/n8n` matter more than the tier.

`edition = "ENTERPRISE"` is deliberate: Enterprise Plus buys 35-day PITR and a
data cache, neither of which a small n8n instance needs, at roughly double the
cost. Flip it and raise `transaction_log_retention_days` if compliance asks.

Operations, restore drills and the exact PITR command sequence live in
[`docs/postgres-runbook.md`](../../docs/postgres-runbook.md).

## Validate

```sh
terraform init -backend=false && terraform validate
```
