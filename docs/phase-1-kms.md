# Finding: KMS-backed SPIRE keys outlive the infrastructure that creates them

Moving the SPIRE signing keys from disk into KMS closes SC-12, but it adds a
lifecycle dependency the practicum build did not have. A disk key dies with the
volume. A KMS key does not die with the cluster, and whether anyone can still
manage it afterwards depends entirely on the key policy written at creation
time.

Getting this working took four separate failures. None of them are covered in
SPIRE's documentation and all of them would hit a federal deployment.

## 1. The default key policy can orphan the key permanently

The `aws_kms` plugin creates keys with a default policy that grants `kms:*` to
the IAM role that created them, and read-only access to the account root:

```json
{
  "Sid": "Allow full access to the SPIRE Server role",
  "Principal": { "AWS": "arn:aws:iam::<acct>:role/spire-cluster-spire-server" },
  "Action": "kms:*"
},
{
  "Sid": "Allow KMS console to display the key and policy",
  "Principal": { "AWS": "arn:aws:iam::<acct>:root" },
  "Action": [ "kms:Describe*", "kms:List*", "kms:Get*" ]
}
```

Root gets no `DeleteAlias`, no `ScheduleKeyDeletion`, no `PutKeyPolicy`.

This matters because AWS resolves IAM principals in a key policy to internal
unique IDs, not to the ARN string. A `terraform destroy` followed by
`terraform apply` recreates the SPIRE server role with an identical ARN but a
new internal ID, so the key policy no longer matches it. The role that had
`kms:*` effectively no longer exists.

Observed after a rebuild:

```
AccessDeniedException: User: arn:aws:iam::<acct>:root is not authorized to
perform: kms:DisableKey on resource: arn:aws:kms:...:key/928e84df-...
because no resource-based policy allows the kms:DisableKey action
```

Root denied on its own key. AWS's usual guarantee that the account root retains
control only holds if the key policy grants it, and here it did not. Two keys
from the first build are permanently unmanageable and can only be resolved
through AWS Support.

A second pair of keys survived the same rebuild only because the role that
owned them still existed at the time; they were cleaned up by assuming that
role temporarily. The contrast is the whole point: **manageability of the CA key
depended on infrastructure that Terraform can delete in thirty seconds.**

### Fix

Set the key policy explicitly rather than accepting the plugin default. The
policy must grant the account root full administrative access, which is the
recovery path, and grant the SPIRE role only the operations it needs. Both are
granted by ARN, which re-resolves correctly after a role is recreated. See
`keyManager.awsKMS.keyPolicy.policy` in `helm/phase-1/spire-values.yaml`.

## 2. The lockout safety check requires kms:PutKeyPolicy

A first attempt at a custom policy failed at key creation:

```
MalformedPolicyDocumentException: The new key policy will not allow you to
update the key policy in the future.
```

KMS refuses to create a key whose policy would prevent the *calling* principal
from running `PutKeyPolicy` later. The caller is the SPIRE server role, not the
account root, so granting root `kms:*` does not satisfy the check. `PutKeyPolicy`
has to appear in the role's own statement, and in the role's identity policy.

## 3. Alias-based key discovery is deprecated, and its replacement needs a VPC endpoint

The server logs this on every start:

```
Alias-based key discovery will be deprecated in a future version and removed in
a later one. Enable 'enable_tag_based_key_discovery' to switch to tag-based
discovery...
```

Enabling it then failed in the Private Only VPC:

```
failed to fetch keys by tags: Resource Groups Tagging API: GetResources,
Post "https://tagging.us-east-1.amazonaws.com/": dial tcp 52.73.18.144:443:
i/o timeout
```

Tag-based discovery calls a different AWS service, the Resource Groups Tagging
API, which needs its own interface endpoint (`com.amazonaws.us-east-1.tagging`)
and the `tag:GetResources` identity permission. Neither is mentioned anywhere in
the SPIRE configuration documentation.

This is the general air-gapped lesson in miniature: enabling a feature can pull
in a new AWS service dependency, and in a disconnected enclave every such
dependency needs an endpoint before the feature works at all.

## 4. DNS caching hides the fix

After adding the endpoint, the server still timed out. The endpoint was
`available` with private DNS enabled, and the jump host resolved the hostname to
a private address correctly, but CoreDNS was still serving the cached public
answer. A `kubectl -n kube-system rollout restart deployment coredns` cleared it.

Worth remembering when verifying any endpoint fix: test resolution from inside
the cluster, not just from a VM in the same VPC.

## Control implications

**SC-12 (cryptographic key establishment and management).** The control is about
more than where the key sits. A KMS-backed CA key introduces a management
lifecycle that outlives the platform, so the key policy, the recovery path, and
the key rotation and destruction procedure all become part of the control
implementation. A deployment that accepts whatever policy its tooling writes has
not actually implemented SC-12; it has delegated it.

**CP-10 (system recovery and reconstitution).** Rebuilding the platform from
code is supposed to be a recovery capability. If rebuilding orphans the CA keys,
the recovery procedure destroys the trust anchor instead of restoring it. The
key policy has to be written so that reconstitution works.

**AC-6 (least privilege).** The policy here grants the SPIRE role ten specific
actions rather than `kms:*`. The identity policy still uses `Resource: "*"` on
the creation statement, because `kms:CreateKey` does not support resource-level
constraints; narrowing the use statement to the created key ARNs after first run
is a worthwhile follow-up and is itself AC-6 evidence.

**Assessment note.** A Helm value that does not match the chart's schema is
silently ignored. A first attempt used `keyPolicy.content` instead of
`keyPolicy.policy`; nothing errored, the server started normally, and the key
was created with the default policy anyway. The misconfiguration was only
visible by inspecting the live AWS resource. Configuration evidence should be
collected from the deployed resource, not from the intended configuration file.

## Evidence

- `kms-key-policy.json` - the applied policy, showing both statements
- `kms-aliases.json` - current SPIRE-managed keys
- `server-startup.log` - tag-based discovery enabled, CA prepared, agents attested
