# terraform/networking — VPC, subnets, firewall, Cloud NAT

One instance of this module per workload project (dev, prod). It builds:

| Resource | Purpose |
|---|---|
| Custom-mode VPC | no auto subnets, no default firewall rules |
| `app` subnet (`10.10.0.0/22`) | Cloud Run **direct VPC egress** target; Private Google Access on; flow logs |
| `mgmt` subnet (`10.10.4.0/24`) | optional ops VMs, reachable only via IAP |
| Reserved `/20` + Service Networking peering | Cloud SQL private IP (consumed by `terraform/database`) |
| Cloud Router + Cloud NAT | egress for anything without an external IP; `ERRORS_ONLY` logging |
| Firewall (see below) | IAP-only SSH, explicit logged default deny |

## Firewall posture

```
priority  rule                        source                 target        ports
 1000     allow-iap-ssh               35.235.240.0/20 (IAP)  tag:iap-ssh   tcp/22
 1000     allow-health-checks         35.191.0.0/16, 130.211.0.0/22  tag:lb-backend  tcp/*
 1100     allow-internal              our subnet CIDRs       all           tcp,udp,icmp
65534     deny-all-ingress (logged)   0.0.0.0/0              all           all
```

**There is no `0.0.0.0/0` → 22 rule and never will be.** SSH goes through Identity-Aware Proxy TCP forwarding:

```sh
# needs roles/iap.tunnelResourceAccessor on the instance (see terraform/iam)
gcloud compute ssh ops-vm-01 --project lz-n8n-prod-a1 --zone us-central1-a --tunnel-through-iap

# or forward an arbitrary port (e.g. psql through an ops VM)
gcloud compute start-iap-tunnel ops-vm-01 5432 --local-host-port=localhost:5432 --zone us-central1-a
```

The VM only needs the `iap-ssh` network tag and no external IP. IAP authenticates the caller with their Google identity (and therefore their MFA), then opens a tunnel from Google's `35.235.240.0/20` range, which is the one and only source the rule permits.

## Why direct VPC egress for Cloud Run

Cloud Run's [direct VPC egress](https://cloud.google.com/run/docs/configuring/vpc-direct-vpc) attaches the service to the `app` subnet without a Serverless VPC Access connector: cheaper, lower latency, no connector instances to manage. The n8n module references `subnet_names["app"]`.

## Validate

```sh
terraform init -backend=false && terraform validate
```
