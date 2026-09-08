# terraform/monitoring — uptime check + alerting

| Resource | What it does |
|---|---|
| `google_monitoring_uptime_check_config.n8n` | `GET https://<host>/healthz/readiness` every 60 s from USA / EUROPE / ASIA_PACIFIC |
| `google_monitoring_alert_policy.n8n_down` | CRITICAL when ≥ 2 regions fail for 5 min; documentation block links the runbooks |
| `google_monitoring_alert_policy.cloud_sql_down` | CRITICAL when `cloudsql.googleapis.com/database/up` is 0 for 2 min |
| `google_monitoring_notification_channel.email` | one channel per address in `alert_email_addresses` |

`/healthz/readiness` is checked, not `/healthz`, because readiness includes
the Postgres connection through the proxy sidecar. That is the failure you
want to be paged for.

The 5-minute window is deliberate: a Cloud Run revision rollout with n8n's
startup migrations can take 1-2 minutes of non-ready time; paging on that is
noise.

## Validate

```sh
terraform init -backend=false && terraform validate
```
