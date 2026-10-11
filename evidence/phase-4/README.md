# Phase 4 evidence

Closes AU-2, AU-3 and AU-9. See docs/phase-4-notes.md.

| File | Shows |
|---|---|
| `log-group.json` | the CloudWatch group, 30-day retention, 2 metric filters attached |
| `audit-events.txt` | SPIRE structured audit records (`type=audit`) |
| `alarm-config.json` | the denial alarm, and its evaluation of real datapoints |
| `fluent-bit-pods.txt` | the shipper running, credentials from Pod Identity |

## What the alarm record proves

`alarm-config.json` is the most useful artifact here, for a reason that is easy
to miss. The `StateReasonData` field shows the alarm evaluating real data:

```
"recentDatapoints":[2.0], "sampleCount":22.0, "threshold":10.0
```

The metric filter matched actual identity denials from the unauthorised
workload, CloudWatch produced a datapoint, and the alarm assessed it against the
threshold. That is log to metric to alarm working end to end, not merely
configured. A continuous-monitoring claim needs the pipeline demonstrated, not
the configuration shown.

## What the audit records contain

385 records across seven API methods, each carrying caller, method, outcome and
request id:

| Method | Count | Relevance |
|---|---|---|
| `GetBundle` | 181 | trust bundle distribution |
| `SyncAuthorizedEntries` | 114 | agent entry synchronisation |
| `ListEntries` | 58 | controller manager reconciliation |
| `ListFederationRelationships` | 29 | federation state |
| `MintX509SVID` | 1 | credential issuance, with CSR hash and expiry |
| `BatchCreateEntry` | 1 | a registration entry created, with parent and SPIFFE ID |
| `BatchDeleteEntry` | 1 | a registration entry removed |

`BatchCreateEntry` and `BatchDeleteEntry` are the AC-6 records: who granted
identity to what, and when it was revoked.

## Known gap: no failed API calls in the audit stream

Every one of the 385 records is `status=success`. AU-2 asks for unsuccessful
events as well, and this capture has none.

That is not because failures went unrecorded. The identity denials are captured,
in the workload pod logs (`no identity issued`) and in the `IdentityDenied`
metric, rather than in the server's audit stream. The audit stream records calls
to the SPIRE server API; a workload being refused an SVID by the agent is a
different event at a different layer.

Worth stating plainly in the paper rather than leaving a reviewer to notice it:
the audit evidence for successful administrative actions and the audit evidence
for denied workload requests come from two different sources, and a complete
AU-2 implementation has to collect both.

A deliberate failed API call against the server would close this. Attempting an
unauthorised `BatchCreateEntry` and capturing the resulting `status=error`
record is the obvious test.

## Re-capturing

```bash
aws logs describe-log-groups --log-group-name-prefix /spire/spire-cluster \
  > evidence/phase-4/log-group.json
kubectl -n spire-server logs spire-server-0 -c spire-server | grep "type=audit" \
  > evidence/phase-4/audit-events.txt
aws cloudwatch describe-alarms --alarm-names spire-cluster-identity-denied \
  > evidence/phase-4/alarm-config.json
kubectl -n observability get pods -o wide > evidence/phase-4/fluent-bit-pods.txt
```

`storedBytes` reads 0 in a freshly created group because CloudWatch's size
statistics lag. Re-capture after the shipper has been running a while if a
non-zero figure matters.
