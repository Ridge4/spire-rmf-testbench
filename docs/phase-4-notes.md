# Phase 4: audit logging and continuous monitoring

Closes AU-2, AU-3 and AU-9, and gives the continuous-monitoring story something
to point at.

## What was missing

The practicum's audit evidence was a log snippet pulled from the SPIRE server
pod, showing node attestation events only. Three gaps:

1. **No workload issuance events.** Node attestation shows agents joining. It
   does not show which workload received which identity, which is the event an
   assessor actually cares about.
2. **No failed attestations.** A log that only records successes cannot support
   an audit control. AU-2 asks for event types including unsuccessful ones.
3. **No retention and no durability.** The log lived in a pod's stdout. Deleting
   the pod deleted the evidence, so AU-9 was unmet by construction.

The report acknowledged this ("the current logs are a point-in-time snapshot")
and listed SIEM streaming as future work. This phase does it.

## What Phase 4 builds

- A CloudWatch log group, `/spire/spire-cluster/identity`, with a retention
  policy set in Terraform.
- A Fluent Bit DaemonSet that tails the SPIRE control plane and the Phase 2/3
  workloads and writes to that group, using Pod Identity for credentials.
- Two metric filters turning log lines into CloudWatch metrics: `SvidIssued`
  and `IdentityDenied`.
- An alarm on sustained denials.

The metric filters are the part that matters for continuous monitoring. A log
group satisfies retention. A metric and an alarm are what make the evidence
*continuous* rather than a snapshot someone exports when an assessor asks.

## Apply

```bash
./scripts/mirror-images.sh manifests/phase-4/00-images.txt
cd terraform && terraform apply && cd ..
kubectl apply -f manifests/phase-4/01-fluent-bit.yaml
kubectl -n observability get pods
```

## Generating the three event types

**Successful workload issuance.** Already happening. The Phase 2 and 3
workloads receive SVIDs on start and on each rotation.

**Failed attestation / denial.** Also already happening, from the rogue
workloads in the `unauthorized` namespace, which request an identity on a loop
and are refused every time.

**Rotation.** Leave the Phase 3 Envoy pods running past the one hour TTL. The
SVIDs are replaced with no restart and no operator action.

A deliberate failure is worth adding too, because an assessor will ask what a
real failure looks like rather than a policy denial:

```bash
kubectl -n payments delete clusterspiffeid echo-client
# watch the client lose its identity on next rotation, then restore it
kubectl apply -f manifests/phase-3/01-identities.yaml
```

## Verification

```bash
aws logs describe-log-groups --log-group-name-prefix /spire/spire-cluster
aws logs describe-log-streams --log-group-name /spire/spire-cluster/identity \
  --order-by LastEventTime --descending --max-items 5
```

Query the identity events:

```
fields @timestamp, kubernetes.pod_name, log
| filter log like /Signed X509 SVID|no identity issued|AttestAgent/
| sort @timestamp desc
| limit 50
```

Check the metrics are populating:

```bash
aws cloudwatch get-metric-statistics \
  --namespace SPIRE/spire-cluster --metric-name SvidIssued \
  --start-time $(date -u -d '2 hours ago' +%Y-%m-%dT%H:%M:%SZ) \
  --end-time $(date -u +%Y-%m-%dT%H:%M:%SZ) \
  --period 300 --statistics Sum
```

## The SPIRE audit log

SPIRE has a dedicated audit log that records API calls to the server with the
caller's identity, separate from the operational log. If the chart exposes it,
enable it: an audit control is better served by a purpose-built audit stream
than by parsing operational logs for keywords.

```bash
grep -n -iE "audit" /tmp/spire/charts/spire-server/values.yaml
```

If `auditLogEnabled` or similar exists, set it and re-run the queries against
the structured events instead of the text patterns used above. Parsing log
prose with a metric filter works, but it is brittle; a log format change
upstream silently breaks the metric, and nothing alerts you that your audit
evidence stopped being collected. Worth stating as a limitation either way.

## Control mapping

**AU-2 (event logging).** The identity events now recorded are: agent
attestation, workload SVID issuance, SVID rotation, and identity denial. The
denial events are what make this an audit capability rather than an activity
log.

**AU-3 (content of audit records).** Each record carries timestamp, the SPIFFE
ID involved, the requesting pod and namespace from the Kubernetes metadata
filter, and the outcome. The Phase 3 Envoy access log adds the peer identity,
TLS version and cipher for connection events.

**AU-9 (protection of audit information).** Records leave the cluster to a
CloudWatch log group the workloads cannot write to arbitrarily: Fluent Bit's
role is scoped to this one log group, and nothing in `payments` or
`unauthorized` has any CloudWatch permission at all. Deleting a pod no longer
deletes its audit trail.

**AU-6 (review and analysis), partially.** The metric filters and alarm give
automated review of one condition. A full AU-6 implementation needs a real
SIEM, correlation rules and a documented review cadence, none of which is in
scope here.

## Deviations to state

- **Retention is 30 days.** Moderate-baseline federal systems typically require
  at least a year online. The variable `audit_retention_days` is the single
  place to change it; the testbench value is a cost decision, not a
  recommendation.
- **CloudWatch is not a SIEM.** Real deployments forward to Splunk, Elastic or
  the agency SOC platform. CloudWatch demonstrates the pipeline exists and is
  durable; it does not demonstrate correlation or incident workflow.
- **Metric filters match log text.** Brittle, as noted above. The SPIRE audit
  log is the more defensible source if available.
- **No log integrity protection.** AU-9 also covers protecting records from
  modification. CloudWatch Logs is append-only for the writer and the IAM role
  cannot delete streams, but a full implementation would add a dedicated
  archive account, object-lock on an S3 export, or log-file validation.

## Evidence to capture (evidence/phase-4/)

| File | Shows |
|---|---|
| `log-group.json` | the group, its retention setting, and its ARN |
| `workload-issuance.txt` | SVID issuance events with SPIFFE IDs, from CloudWatch |
| `denial-events.txt` | identity denials for the unauthorised workloads |
| `rotation-events.txt` | SVIDs replaced across a TTL boundary with no restart |
| `metric-svid-issued.json` | the CloudWatch metric time series |
| `metric-identity-denied.json` | the denial metric time series |
| `alarm-config.json` | the alarm definition and its state |
| `fluent-bit-pods.txt` | the shipper running, with no static AWS credentials |
