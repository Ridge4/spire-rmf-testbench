# Phase 2 evidence

Closes AC-6, and the registration-entry lifecycle item from the practicum's
future work. See docs/phase-2-notes.md.

| File | Shows |
|---|---|
| `clusterspiffeids.yaml` | the applied identity policy, with the controller manager's own selection stats |
| `registration-entries.txt` | exactly two entries, each bound to one pod UID |
| `svid-payments-api.txt` | a scoped SVID, denied first, then issued |
| `svid-payments-db-client.txt` | a second, distinct identity |
| `negative-test-denied.txt` | an unmatched workload refused, continuously |
| `namespaces-and-sa.txt` | the namespace labels that drive selection |

## What replaced `ns/default/sa/default`

The practicum's only workload artifact was the default service account in the
default namespace, which it had to acknowledge undercut its own least-privilege
claim. Two purpose-built identities replace it:

```
spiffe://spire-rmf.lab/ns/payments/sa/api
spiffe://spire-rmf.lab/ns/payments/sa/db-client
```

Distinct identities from the same namespace, so the scoping follows the service
account rather than the namespace alone.

## The entries are bound to individual pods

`registration-entries.txt` shows the selector the controller manager actually
wrote:

```
SPIFFE ID  : spiffe://spire-rmf.lab/ns/payments/sa/api
Selector   : k8s:pod-uid:7f637a64-1335-4d27-a44f-24d057242e2b
X509-SVID TTL : 3600
```

This is tighter than the policy that produced it. The `ClusterSPIFFEID` selects
by namespace and pod label, but the entry it generates targets one specific pod
instance by UID. The credential therefore cannot outlive that pod: replacing the
pod produces a new UID and a new entry, and the old entry is reaped.

Worth stating in the paper, because it answers an obvious objection. Labels are
mutable by anyone who can edit a pod spec, so label-based selection alone would
be a weak boundary. The UID binding means a workload cannot inherit another
workload's credential by relabelling itself; it would have to be that pod.

`X509-SVID TTL: 3600` also confirms the one-hour TTL reached the entry, not just
the server configuration.

## The policy reports its own scope

`clusterspiffeids.yaml` includes the controller manager's status block:

```
namespacesSelected: 1
podsSelected: 1
entriesMasked: 0
entryFailures: 0
namespacesIgnored: 0
```

Each policy selected exactly one namespace and one pod. That is scope stated by
the enforcing component rather than inferred from configuration, and it is the
kind of artifact an assessor can read directly. If a policy were broader than
intended, `podsSelected` would say so.

Compare with the chart's built-in `default` ClusterSPIFFEID, which ships with an
empty `podSelector` and a `namespaceSelector` excluding only the SPIRE
namespaces. Running that, every pod in the cluster receives an identity. It is
disabled in `helm/spire-values.yaml`; the config-level origin of the practicum's
`default/default` artifact was that catch-all, not merely an under-configured
demo.

## The denial

`negative-test-denied.txt` is a workload in the `unauthorized` namespace,
configured identically to the two above — same image, same CSI socket mount,
same request — differing only in that its namespace carries no
`spiffe.io/spiffe-id` label and no policy selects it:

```
rpc error: code = PermissionDenied desc = no identity issued
```

Repeated continuously, never resolving.

The three denials at the top of each successful SVID file matter too. Those are
the same refusal, before the controller manager had reconciled the new policy.
The Workload API refuses by default and grants only on an explicit match, so the
denial is the resting state rather than an error condition.

Least privilege is a claim about what is denied. The practicum could show what
was allowed; this shows both.

## Note

`namespaces-and-sa.txt` lists service accounts for the `payments` namespace
only. The `unauthorized` namespace's `rogue` service account is visible in the
negative test's pod spec but is not in this capture. Minor, but worth adding on
the next run for completeness.
