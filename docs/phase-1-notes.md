# Phase 1: HA datastore, KMS-backed keys, enforced TTL

Closes the IA-5 / SC-12 and datastore rows of the evidence-gap table.

| Practicum posture | Phase 1 posture |
|---|---|
| Bundled SQLite on one 1Gi EBS volume, `reclaimPolicy: Delete` | RDS PostgreSQL, encrypted, optional Multi-AZ |
| Disk-resident self-signed root CA (`keys.json`) | KMS-managed keys; private material never leaves KMS |
| ~4h TTL observed from one issued certificate | TTL set in server configuration and exported as evidence |

## Order of operations

1. `terraform apply` the Phase 1 additions (`rds.tf`, `kms.tf`). RDS takes
   5–10 minutes.
2. Create the namespace and the datastore secret.
3. Verify chart value names (see the header of `helm/phase-1/spire-values.yaml`).
4. Install SPIRE.
5. Capture evidence.

## Create the namespace and datastore secret

The database password is in Secrets Manager, never in the repository. From your
workstation, with the SSM tunnel running:

```bash
cd terraform
SECRET_ARN=$(terraform output -raw spire_datastore_secret_arn)
DB_PASS=$(aws secretsmanager get-secret-value --secret-id "$SECRET_ARN" \
  --query SecretString --output text | python3 -c 'import json,sys;print(json.load(sys.stdin)["password"])')

kubectl create namespace spire-server
kubectl create namespace spire-system 2>/dev/null || true

kubectl -n spire-server create secret generic spire-datastore \
  --from-literal=password="$DB_PASS"
```

Then put the RDS endpoint into the values file:

```bash
terraform output -raw spire_datastore_endpoint
# paste into helm/phase-1/spire-values.yaml -> dataStore.sql.host
```

## Install

```bash
helm repo add spiffe https://spiffe.github.io/helm-charts-hardened/
helm repo update

helm upgrade --install spire-crds spiffe/spire-crds \
  --namespace spire-server --create-namespace

helm upgrade --install spire spiffe/spire \
  --namespace spire-server \
  --values helm/phase-1/spire-values.yaml \
  --version <PIN_A_VERSION>
```

Pin the chart version and record it. "Latest" is not reproducible, and
reproducibility is the main thing this repository offers a reviewer.

## Verifying each claim

**Datastore is PostgreSQL, not SQLite.** The server log should open a Postgres
connection, and no SQLite file should exist:

```bash
kubectl -n spire-server logs statefulset/spire-server | grep -i "db_type\|postgres"
kubectl -n spire-server exec statefulset/spire-server -- ls /run/spire/data
```

**Keys are in KMS, not on disk.** Confirm the plugin loaded, then confirm keys
exist in KMS and that `keys.json` does not exist locally:

```bash
kubectl -n spire-server logs statefulset/spire-server | grep -i "kms\|KeyManager"
aws kms list-aliases --query "Aliases[?contains(AliasName,'SPIRE')]"
```

The important property for SC-12: KMS has no API that exports private key
material. SPIRE calls `kms:Sign`; the key never comes out. Say exactly that in
the paper rather than "keys are protected."

**TTL is enforced by configuration.** Export the rendered server config and pair
it with an issued SVID:

```bash
kubectl -n spire-server get configmap spire-server -o yaml
```

The config shows `default_x509_svid_ttl`; the SVID shows a validity window that
matches. One without the other is the weak evidence the practicum had.

**Pod Identity is supplying credentials.** No static AWS keys anywhere:

```bash
kubectl -n spire-server describe pod -l app.kubernetes.io/name=spire-server | grep -i aws
```

You should see the Pod Identity environment, not `AWS_ACCESS_KEY_ID`.

## Evidence to capture (evidence/phase-1/)

- `rds-datastore.json` — `aws rds describe-db-instances`, showing encryption,
  Multi-AZ state, and `publicly_accessible: false`
- `server-config.yaml` — the rendered ConfigMap with the TTL settings
- `svid-ttl-match.txt` — an issued SVID's validity window beside the configured
  value
- `kms-aliases.json` — `aws kms list-aliases` showing SPIRE-created keys
- `no-keys-json.txt` — directory listing showing no `keys.json` on disk
- `server-startup.log` — Postgres and KMS plugin load lines
- `pod-identity.txt` — proof that no static credentials are mounted
- `helm-chart-version.txt` — chart and SPIRE versions used

## Known deviations to state in the paper

- **Multi-AZ defaults to false** for cost. Run the evidence capture with
  `rds_multi_az = true` or describe the datastore as external-but-single-AZ.
  Do not claim high availability from a single-AZ instance.
- **KMS IAM policy uses `Resource: "*"`** because `kms:CreateKey` does not
  support resource-level constraints. Narrow the second statement to the created
  key ARNs after the first run, and cite that narrowing as AC-6 evidence.
- **Still one SPIRE server replica** by default. The external datastore makes
  multiple replicas possible; actually running them is a separate claim, so
  raise `replicaCount` before claiming it.
- **This is not FIPS.** KMS does use validated HSMs, but SPIRE's own TLS stack
  is a separate question handled in Phase 5. Do not let the KMS result blur into
  an SC-13 claim.
