# Phase 2: least privilege for workload identity

Closes the AC-6 row of the evidence-gap table, and the registration-entry
lifecycle item from the practicum's future work section.

## The problem being fixed

The practicum's only workload artifact was:

```
spiffe://example.org/ns/default/sa/default
```

That is the least-scoped identity Kubernetes can produce: the default service
account in the default namespace. The report offered it as evidence that SPIRE
binds an exact identity to a specific workload, and then had to note in the same
paragraph that it undercut the claim.

The cause was visible in the chart all along. Its built-in `default`
ClusterSPIFFEID ships with empty selectors:

```yaml
podSelector: {}
namespaceSelector: {}
```

Empty selectors match everything. Every pod in every namespace gets an identity
automatically. So the practicum was not just missing a purpose-built namespace,
it was running a configuration that granted identity indiscriminately.

## What Phase 2 does

1. Disables the chart's catch-all identity
   (`controllerManager.identities.clusterSPIFFEIDs.default.enabled: false`).
2. Creates a `payments` namespace with two distinct service accounts, `api` and
   `db-client`.
3. Declares two `ClusterSPIFFEID` resources, each scoped by namespace label and
   pod label, so an identity is issued only to a workload that matches both.
4. Runs a third workload in an `unauthorized` namespace, configured identically
   but selected by nothing, to show that an unmatched workload receives nothing.

## Apply

```bash
helm upgrade spire spiffe/spire -n spire-server \
  --version 0.30.3 --values helm/spire-values.yaml

kubectl apply -f manifests/phase-2/01-namespaces.yaml
kubectl apply -f manifests/phase-2/02-clusterspiffeids.yaml
kubectl apply -f manifests/phase-2/03-workloads.yaml
kubectl apply -f manifests/phase-2/04-negative-test.yaml
```

Check `className` matches the controller manager before applying the
ClusterSPIFFEIDs. The chart derives it from the release:

```bash
kubectl -n spire-server get configmap spire-controller-manager -o yaml | grep -i classname
```

If it differs from `spire-server-spire`, update both resources in
`02-clusterspiffeids.yaml`. A mismatched class name means the controller manager
ignores the resource entirely, and nothing errors.

## Verification

Registration entries should exist for the two authorised workloads and nothing
else:

```bash
kubectl -n spire-server exec spire-server-0 -c spire-server -- \
  /opt/spire/bin/spire-server entry show -socketPath /tmp/spire-server/private/api.sock
```

The authorised workloads should each report a scoped SVID:

```bash
kubectl -n payments logs deploy/payments-api --tail=20
kubectl -n payments logs deploy/payments-db-client --tail=20
```

Expected IDs:

```
spiffe://spire-rmf.lab/ns/payments/sa/api
spiffe://spire-rmf.lab/ns/payments/sa/db-client
```

The unauthorised workload should fail:

```bash
kubectl -n unauthorized logs deploy/rogue --tail=20
```

Expected: the fetch fails and the pod prints the DENIED line. No entry exists,
so the agent has nothing to issue.

## Why the negative test matters

A successful fetch proves the system issues identities. It does not prove the
scoping constrains anything. The two results together are what support an AC-6
claim: authorised workloads get precisely the identity their namespace and
service account imply, and an identically configured workload outside the
selectors gets nothing.

An assessor evaluating least privilege is asking what is denied, not what is
allowed. The practicum had no answer to that question. This phase does.

## Registration entry lifecycle

The entries here are not created by hand. The SPIRE Controller Manager watches
`ClusterSPIFFEID` resources and reconciles registration entries to match, so the
identity policy lives in version-controlled YAML rather than in operator
commands run against a server socket.

That addresses the practicum's future-work item directly. It also changes who
can grant identity: creating a `ClusterSPIFFEID` is now the privileged action,
and it is governed by Kubernetes RBAC on a cluster-scoped custom resource.
Restricting who may create them is the natural next control, and the chart's
`className` mechanism allows several controller managers with separate scopes
in a multi-tenant cluster.

## Evidence to capture (evidence/phase-2/)

| File | Shows |
|---|---|
| `clusterspiffeids.yaml` | the applied identity policy |
| `registration-entries.txt` | `spire-server entry show`, only the scoped entries |
| `svid-payments-api.txt` | the api workload's SVID, scoped to its service account |
| `svid-payments-db-client.txt` | the db-client workload's SVID, a distinct identity |
| `negative-test-denied.txt` | the unauthorised workload failing to obtain any SVID |
| `namespaces-and-sa.txt` | the namespaces and service accounts in use |

## Deviations and notes

- **The workload image is the SPIRE agent binary**, used only for its
  `api fetch` client. A production workload would use go-spiffe or a service
  mesh. This keeps the testbench to images already mirrored into ECR.
- **Identity is still coarse at the pod level.** The selectors match namespace
  and pod labels. Labels are mutable by anyone who can update the pod spec, so
  in a real deployment the RBAC governing pod creation is part of the identity
  boundary and should be assessed alongside it.
- **No mTLS yet.** These workloads fetch an SVID and stop. Using it for an
  authenticated connection is Phase 3, which is what SC-8 actually needs.
