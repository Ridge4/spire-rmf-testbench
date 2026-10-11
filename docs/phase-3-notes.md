# Phase 3: live mTLS

Closes the SC-8 / SC-13 row of the evidence-gap table, apart from FIPS.

## What the practicum claimed and what it showed

The original report said:

> By leveraging X.509 SVIDs, the framework naturally satisfies SC-8 through the
> automated establishment of mutual TLS (mTLS) tunnels.

The evidence behind that sentence was a single SVID being fetched. No workload
consumed it, no handshake happened, and no TLS session existed anywhere in the
testbench. The revised report corrected the claim to "identity foundation" and
listed handshake validation as future work. This phase does the work.

## Design

Two Envoy proxies, one acting as server and one as client, each fetching its
SVID over the SPIFFE Workload API using SDS. Nothing is mounted into either pod
except the agent socket: no certificate, no key, no secret.

```
echo-client pod                         echo-server pod
┌───────────────────────┐               ┌────────────────────────┐
│ curl → 127.0.0.1:8080 │               │                        │
│        ↓              │   mTLS 8443   │                        │
│ Envoy (SVID via SDS) ─┼──────────────►│ Envoy (SVID via SDS)   │
└───────────┬───────────┘               └────────────┬───────────┘
            │ SDS over unix socket                   │
            ▼                                        ▼
      SPIRE agent                              SPIRE agent
```

The server sets `require_client_certificate: true` and restricts acceptable
peers with `match_typed_subject_alt_names` to exactly one SPIFFE ID. The client
does the same in reverse. So the connection is authenticated in both directions
and authorised by identity, not merely encrypted.

## Apply

Mirror the two new images first; the cluster still cannot reach Docker Hub.

```bash
./scripts/mirror-images.sh manifests/phase-3/00-images.txt

kubectl apply -f manifests/phase-3/01-identities.yaml
kubectl apply -f manifests/phase-3/02-echo-server.yaml
kubectl apply -f manifests/phase-3/03-echo-client.yaml
kubectl apply -f manifests/phase-3/04-negative-test.yaml
```

Allow a minute: the client waits 20 seconds before its first request so SDS has
time to deliver certificates.

## Verification

The handshake, from the server's access log:

```bash
kubectl -n payments logs deploy/echo-server -c envoy | grep MTLS
```

Expected form:

```
MTLS peer=spiffe://spire-rmf.lab/ns/payments/sa/echo-client tls_version=TLSv1.3 cipher=TLS_AES_256_GCM_SHA384 subject=... response=200
```

That one line carries most of what SC-8 needs: a completed mutually
authenticated session, the negotiated protocol version, the negotiated cipher
suite, and the authenticated identity of the peer.

The client side:

```bash
kubectl -n payments logs deploy/echo-client -c curl
kubectl -n payments logs deploy/echo-client -c envoy | grep CLIENT
```

The negative test:

```bash
kubectl -n unauthorized logs deploy/rogue-client -c curl
kubectl -n unauthorized logs deploy/rogue-client -c envoy | tail -20
```

Expected: the client Envoy has no certificate to present because SDS never
delivers one, and the connection fails. Envoy reports an upstream connection
failure rather than a 200.

## A second negative test worth running

The rogue client fails because it has no identity at all. A sharper test is a
workload that holds a **valid** SVID from the same trust domain but is not on
the server's allow list. Re-point one of the Phase 2 workloads at the server, or
temporarily add a pod label so `payments-db-client` matches, and confirm the
server still rejects it.

That distinguishes two different claims:

- possession of any certificate from the trust domain is not sufficient, and
- the authorisation decision is made on the specific SPIFFE ID.

An assessor reviewing AC-3 will ask for the second one.

## What this still does not prove

**FIPS 140.** The handshake uses whatever cryptographic module Envoy was built
against. SC-13 in a federal boundary requires a validated module, and the
upstream Envoy image is not FIPS-validated. The negotiated cipher being strong
is not the same thing as the module being validated. That remains Phase 5.

**Application-layer identity.** Envoy terminates TLS, so the application behind
it sees plain HTTP on localhost. That is the normal service-mesh pattern and is
fine within a pod boundary, but an assessor may ask what prevents another
process in the same pod from reaching port 8080. Pod-level isolation and the
answer to that question belong in the system security plan.

**Revocation.** Unchanged from Phase 1. A compromised workload's SVID stays
valid until it expires, now at most one hour.

## Evidence to capture (evidence/phase-3/)

| File | Shows |
|---|---|
| `mtls-handshake.txt` | server access log: peer SPIFFE ID, TLS version, cipher |
| `client-success.txt` | client curl output and Envoy upstream log |
| `negative-no-identity.txt` | rogue client rejected, no certificate available |
| `negative-wrong-identity.txt` | valid SVID, non-allowed SPIFFE ID, still rejected |
| `envoy-config-server.yaml` | the applied server TLS configuration |
| `envoy-config-client.yaml` | the applied client TLS configuration |
| `sds-certificate-rotation.txt` | Envoy picking up a rotated SVID without restart |

That last one is worth capturing deliberately. Leave the pods running past the
one hour TTL and confirm the session survives rotation with no restart and no
operator action. It is the strongest available evidence for the IA-5 claim that
short lifetimes are operationally sustainable rather than merely configured.
