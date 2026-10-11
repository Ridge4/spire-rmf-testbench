# Phase 1 evidence

Closes IA-5 and SC-12, replaces the SQLite single point of failure, and
establishes the air-gapped image supply chain. See docs/phase-1-notes.md,
docs/phase-1-kms.md and docs/phase-1-images.md.

## Current

| File | Shows |
|---|---|
| `helm-values-applied.yaml` | the exact values Helm used, including the KMS key policy |
| `server-startup.log` | Postgres connected, tag-based KMS discovery, CA prepared, agents attested |
| `kms-key-policy.json` | the explicit key policy: root retains administration, role gets ten scoped actions |
| `kms-aliases.json` | the SPIRE-managed keys, including the orphaned generations |
| `rds-datastore.json` | encrypted, not publicly accessible, single-AZ |
| `volumes-emptydir.txt` | `spire-data` is an emptyDir; no persistent volume |
| `no-pvc.txt` | no PVCs in the namespace |
| `pod-identity.txt` | Pod Identity credentials, no static AWS keys |
| `ecr-repositories.json` | the mirrored repositories, immutable tags, scan-on-push |
| `image-inventory.txt` | what is running: 10 mirrored, 6 AWS-managed, 0 external |
| `ca-subject-rotation.txt` | the CA subject before and after rotation, and the leaf subject that did not change |

## Re-captured 2026-10-11

All files above were refreshed against the clean-room rebuild and the caSubject
change. They agree with the deployed system:

- `server-config.yaml` shows `audit_log_enabled: true`,
  `key_identifier_value: spire-cluster-v3`, `enable_tag_based_key_discovery:
  true`, and the new `ca_subject`
- `helm-chart-version.txt` shows revision 2, status `deployed`
- `pods-running.txt` shows all five pods healthy, no restarts

Two files were removed rather than replaced. `no-keys-json.txt` was empty
because the server image is distroless and has no shell; the absence of disk key
material is better shown by `keymanager-config.txt`, which configures no disk
KeyManager, and `volumes-emptydir.txt`, which shows no durable volume to write
one to. `pods-running-after-mirror.txt` duplicated `pods-running.txt`.

Two remain slightly behind and are worth refreshing on the next run:

- `kms-aliases.json` was captured before the CA rotation, so it shows only the
  `-A` slots. The rotation should have created a `x509-CA-B` key; re-capturing
  would show the rotation reflected in KMS as well as in the certificate.
- `image-mirror-map.txt` still holds one line from the last mirror run. The
  script now appends and de-duplicates, so it will rebuild over time.
  `image-inventory.txt` is authoritative in the meantime because it reads the
  running pods rather than the mirror history.

## Finding: identity provenance has three layers, not one

The practicum argued in §3.3 that structuring the trust domain around an
agency's real DNS topology gives assessors recognisable identity provenance.
Testing that produced a more complicated answer. Three distinct things name the
organisation on an issued credential, each configured differently:

| Layer | Observed value | Set by | Takes effect |
|---|---|---|---|
| Trust domain | `spire-rmf.lab` | `global.spire.trustDomain` | immediately |
| CA subject DN | `C=US, O=spire-rmf-testbench, CN=spire-rmf.lab` | `caSubject` | only at CA rotation |
| Leaf subject DN | `O=SPIRE, C=US` | SPIRE internally | not reachable via `caSubject` |

`ca-subject-rotation.txt` records the sequence. The chart defaults are
`commonName: example.org`, `organization: Example`, `country: ARPA`, and those
persist in every issued certificate until changed. Setting `caSubject` and
restarting the server was not sufficient: the CA lives in the datastore and in
KMS, so a restart reuses it. The new subject appeared only after the local
authority was explicitly rotated:

```
ca-1  C = ARPA, O = Example,             CN = example.org     notBefore 14:34:13
ca-2  C = US,   O = spire-rmf-testbench, CN = spire-rmf.lab   notBefore 15:21:56
```

Both were present in the trust bundle during the overlap.

The leaf subject did not change. After rotation, workload SVIDs are issued by
the new CA and still carry `O=SPIRE,C=US`, which is the DN visible in the Phase
3 handshake record. `caSubject` sets the issuer DN only. Changing what appears
on a workload certificate requires the credential composer
(`credentialComposer.cel` in the chart).

For the paper: changing the trust domain is the obvious configuration step and
the only one most deployments will take. It does not change the issuer DN, which
needs a rotation many operators will not realise is required, and it does not
change the subject DN an assessor reads off a workload certificate at all. Three
layers, three mechanisms, and the one that is easiest to check is the one the
configuration does not reach.

## What the artifacts establish

**IA-5.** `server-config.yaml` carries `default_x509_svid_ttl: 1h` and
`ca_ttl: 24h`, set deliberately rather than left at the chart's 4h default. Pair
it with an issued SVID from Phase 2 and the rotation capture from Phase 3.

**SC-12.** `kms-key-policy.json` is the important one. The signing key lives in
KMS, and the policy keeps the account root able to administer it while granting
the SPIRE role only the operations the plugin needs. KMS exposes no API that
exports private key material, so the key is used but never retrievable. Compare
with the practicum, where the equivalent key was a file on an EBS volume with
`reclaimPolicy: Delete`.

**The datastore.** `rds-datastore.json` shows `StorageEncrypted: true` and
`PubliclyAccessible: false`, with `MultiAZ: false`. The SQLite single-writer
ceiling is gone, but single-AZ is not high availability and the paper should not
claim it is. `rds_multi_az` is the one variable to change for an HA evidence run.

**Supply chain.** `ecr-repositories.json` shows every mirrored repository with
`imageTagMutability: IMMUTABLE` and `scanOnPush: true`. That is the mitigation
for the digest-pinning problem described in docs/phase-1-images.md: upstream
pins by digest, mirroring necessarily changes the digest, and immutable tags
plus scan results are what replace the lost guarantee.

## The orphaned keys

`kms-aliases.json` lists three generations: `spire-cluster`, `-v2` and `-v3`.
That is not untidiness, it is the evidence for the finding in
docs/phase-1-kms.md. The first generation was created under the plugin's default
key policy, which granted administration only to an IAM role that a later
`terraform destroy` removed. Those keys cannot now be managed by anyone,
including the account root. The second generation was recoverable only because
its role still existed at the time. The third carries the explicit policy and
survives rebuilds.

Three generations of the same key, three different outcomes, determined entirely
by what the key policy said at creation.
