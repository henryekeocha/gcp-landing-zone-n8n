# terraform/projects — multi-project structure

Creates the folder tree and the three projects that every other module targets.

```
organizations/ORG_ID
└── landing-zone/
    ├── shared/   → lz-n8n-shared-a1   (Artifact Registry, KMS, Cloud Build, shared secrets)
    ├── dev/      → lz-n8n-dev-a1      (dev VPC, dev Cloud SQL, dev n8n)
    └── prod/     → lz-n8n-prod-a1     (prod VPC, prod Cloud SQL, prod n8n)
```

## Design choice: folders, not flat projects

Flat projects would validate just the same, but the folder layer is where a landing zone earns its name:

| Concern | With folders | Flat projects |
|---|---|---|
| Org policies (public IP bans, domain restriction) | set once on `landing-zone`, inherited | repeated per project, drift-prone |
| Human IAM ("prod read-only") | one folder binding | N project bindings |
| Adding an environment (`staging`) | add one entry to `environments` | copy-paste a block |
| Blast radius | shared-services isolated from workloads | same, but nothing enforces it |

## Other decisions

- **`auto_create_network = false`** on every project. The default VPC's `default-allow-ssh` rule is exactly the `0.0.0.0/0:22` ingress this landing zone forbids.
- **`deletion_policy = "PREVENT"`** so `terraform destroy` can't remove a project holding a production database.
- **APIs are enabled here, once**, split into base / workload / shared sets, with `disable_on_destroy = false` so removing a module never disables an API another module depends on.
- **`project_suffix`** exists because deleted project IDs are reserved for 30 days; bumping the suffix is the escape hatch.

## Validate

```sh
terraform init -backend=false
terraform validate
```

No credentials required. `terraform apply` needs an org admin with `resourcemanager.folders.create` and `billing.user`; see `docs/handoff-runbook.md`.
