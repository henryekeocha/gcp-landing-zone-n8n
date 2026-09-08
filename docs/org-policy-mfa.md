# Enforcing MFA in a GCP landing zone

> **Not applied by this repo.** Organization policies need a real organization
> resource and `roles/orgpolicy.policyAdmin`; Cloud Identity settings need a
> Workspace/Cloud Identity super-admin. Everything below is written to be
> copied into a real org, and the Terraform in it is `validate`-clean.

## The thing people get wrong first

There is **no Organization Policy constraint that enforces MFA**. Org Policy
constrains *resources* (can a VM have a public IP, can a Cloud SQL instance be
reachable from the internet). MFA is a property of *identities*, and identities
live in Cloud Identity / Google Workspace, not in the GCP resource hierarchy.

So "enforce MFA" on GCP is three layers working together:

| Layer | Mechanism | What it guarantees |
|---|---|---|
| 1. Identity | Cloud Identity **2-Step Verification enforcement** (Admin console → Security → 2-Step Verification → *Enforcement: On*, ideally *Only security keys*) | every human in your domain must complete 2SV to sign in at all |
| 2. Resource hierarchy | Org Policy **`iam.allowedPolicyMemberDomains`** (domain-restricted sharing) | only identities from *your* domain (where 2SV is enforced) can ever be granted an IAM role, so a `user:someone@gmail.com` binding is rejected at write time |
| 3. Context | **Context-Aware Access** access levels bound to the GCP console/API | even a valid 2SV session must come from a managed device / allowed region, and can require a *recent* 2SV re-auth for sensitive apps |

Layer 1 makes MFA mandatory. Layer 2 stops anyone from routing around it by
granting access to an identity you don't control. Layer 3 is optional
hardening. Service accounts are not humans; they are governed separately
(see the last section).

## Layer 1 — Cloud Identity 2SV enforcement

Admin console path: **Security → Authentication → 2-Step Verification**

Recommended settings:

- *Allow users to turn on 2-Step Verification*: **On**
- *Enforcement*: **On** (new users get a grace period you define, 1 week is typical)
- *Methods*: **Only security key** for the org unit containing admins and anyone with `roles/owner` / `roles/orgpolicy.policyAdmin`; *Any except verification codes via text/phone* for everyone else
- *Trusted devices*: **Don't allow user to trust device** for the admin OU

This is settable via the Admin SDK (`Directory API` is not enough; it's the
[Cloud Identity / Admin console settings](https://support.google.com/a/answer/9176657)),
and there is currently no first-class Terraform resource for it, which is
why it's documented rather than coded.

Verification: `gcloud` cannot query it. Use the Admin console report
**Reporting → Users → 2-Step Verification enrollment / enforcement**, or the
Admin SDK Reports API `usage/users` with parameter `accounts:is_2sv_enrolled`.

## Layer 2 — Org Policy: domain-restricted sharing

Applied at the `landing-zone` folder created by `terraform/projects`, inherited
by `shared`, `dev`, `prod`. Once in place, `gcloud projects add-iam-policy-binding
--member=user:x@gmail.com` fails with `FAILED_PRECONDITION: ... constraints/iam.allowedPolicyMemberDomains`.

```hcl
# Needs: roles/orgpolicy.policyAdmin on the org.
# Find your customer ID: gcloud organizations list  (DIRECTORY_CUSTOMER_ID column)

resource "google_org_policy_policy" "domain_restricted_sharing" {
  name   = "${google_folder.landing_zone.name}/policies/iam.allowedPolicyMemberDomains"
  parent = google_folder.landing_zone.name

  spec {
    inherit_from_parent = false
    rules {
      values {
        allowed_values = [
          "C0xxxxxxx", # your Cloud Identity customer ID
        ]
      }
    }
  }
}
```

Gotcha worth knowing before applying it: this also blocks `allUsers` and
`allAuthenticatedUsers`, so a public Cloud Run service (`roles/run.invoker`
for `allUsers`) needs a **tag-conditioned exception** or a Cloud Load Balancer
+ IAP in front. For the n8n service in this repo that is the *desired*
behaviour: webhooks come through a load balancer, the editor UI sits behind IAP.

## Layer 2b — companion constraints for this landing zone

These do not enforce MFA but close the doors an MFA-less identity would use.
Same folder, same `google_org_policy_policy` shape (boolean form shown once):

```hcl
locals {
  boolean_constraints = [
    "iam.disableServiceAccountKeyCreation",         # no downloadable SA keys; WIF only
    "iam.disableServiceAccountKeyUpload",
    "iam.automaticIamGrantsForDefaultServiceAccounts", # default SAs don't get Editor
    "compute.requireOsLogin",                       # SSH tied to Google identity (+2SV)
    "compute.vmExternalIpAccess",                   # list constraint; deny all (see docs)
    "sql.restrictPublicIp",                         # Cloud SQL private IP only
    "sql.restrictAuthorizedNetworks",
    "compute.skipDefaultNetworkCreation",
    "storage.uniformBucketLevelAccess",
  ]
}

resource "google_org_policy_policy" "boolean" {
  for_each = toset(local.boolean_constraints)

  name   = "${google_folder.landing_zone.name}/policies/${each.value}"
  parent = google_folder.landing_zone.name

  spec {
    rules {
      enforce = "TRUE"
    }
  }
}
```

(`compute.vmExternalIpAccess` is a list constraint; use `rules { deny_all = "TRUE" }`
instead of `enforce`.)

## Layer 3 — Context-Aware Access (optional)

Access levels are Terraform-able
(`google_access_context_manager_access_level`) and can be bound to the
"Google Cloud Platform" app in the Admin console so that reaching the console
or `gcloud` requires, for example, a company-managed device with screen lock
and an approved OS version:

```hcl
resource "google_access_context_manager_access_level" "managed_device" {
  parent = "accessPolicies/${var.access_policy_id}"
  name   = "accessPolicies/${var.access_policy_id}/accessLevels/managed_device"
  title  = "Managed device, corp regions"

  basic {
    conditions {
      device_policy {
        require_screen_lock    = true
        require_corp_owned     = true
        allowed_encryption_statuses = ["ENCRYPTED"]
      }
      regions = ["US", "CA", "GB"]
    }
  }
}
```

Binding the level to the GCP app is an Admin console step (Security → Access
and data control → Context-Aware Access); it cannot yet be done from
Terraform.

## Service accounts are the exception, deliberately

Service accounts cannot do MFA. The landing zone compensates:

- `iam.disableServiceAccountKeyCreation` means there is nothing to steal.
- GitHub Actions authenticates with **Workload Identity Federation**, pinned to
  one repository (and `refs/heads/main` for prod) in `terraform/iam`.
- The runtime and deployer accounts are separate and narrowly scoped, so a
  compromised CI run cannot read the n8n encryption key.

## Checklist for the person applying this for real

1. Enforce 2SV in the Admin console (Layer 1). Do this **first**; Layer 2 is pointless otherwise.
2. `gcloud organizations list` → note the customer ID.
3. Apply the domain-restricted-sharing policy at the `landing-zone` folder.
4. Apply the companion boolean constraints.
5. Try to grant `roles/viewer` to a personal Gmail on the dev project. It must fail.
6. Try to create a service account key on the dev project. It must fail.
