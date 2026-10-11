# Phase 3 evidence

Closes SC-8 apart from FIPS, and contributes to AC-3. See docs/phase-3-notes.md
for the design and docs/phase-5-fips.md for why FIPS is a separate question.

| File | Shows |
|---|---|
| `mtls-handshake.txt` | the completed session: peer SPIFFE ID, TLS version, cipher |
| `client-success.txt` | the client side of the same exchange |
| `negative-no-identity.txt` | an unauthorised workload refused, at two layers |
| `sds-certificate-rotation.txt` | three rotations, one pod, no restarts, no outage |
| `envoy-config-server.yaml` | the applied server TLS configuration |
| `envoy-config-client.yaml` | the applied client TLS configuration |

## The handshake record

```
MTLS peer=spiffe://spire-rmf.lab/ns/payments/sa/echo-client
     tls_version=TLSv1.2 cipher=ECDHE-ECDSA-AES128-GCM-SHA256
     subject=O=SPIRE,C=US response=200
```

One line carrying what SC-8 asks for: a completed mutually authenticated
session, the negotiated protocol version, the negotiated cipher suite, and the
cryptographically authenticated identity of the peer. The `ECDHE-ECDSA` key
exchange confirms the elliptic-curve SVID key performed the authentication, so
the chain runs from the KMS-held CA through to this connection.

Note the negotiated version is TLS 1.2. The configuration sets
`tls_minimum_protocol_version: TLSv1_2` with no maximum, so 1.2 was selected.
Federal baselines increasingly expect 1.3; raising the minimum, or setting a
maximum, is a worthwhile follow-up. The general point is worth stating in the
paper: "mTLS is enabled" says nothing about which version is actually
negotiated, and only the handshake record answers that.

## The denial, at two layers

`negative-no-identity.txt` shows the refusal happening twice, independently:

```
StreamSecrets gRPC config stream to spire_agent closed: 3,
  workload is not authorized for the requested identities ["default"]
...
TLS error: Secret is not supplied by SDS
ROGUE upstream=172.20.205.94:8443 response=503 flags=UF
```

First SPIRE declines to issue a certificate to a workload no ClusterSPIFFEID
selects. Then Envoy, having no certificate, cannot present one, and the
connection fails before a handshake is attempted. The `UF` response flag is
Envoy recording an upstream connection failure.

That is defence in depth visible in evidence rather than claimed in prose: the
identity plane refuses first, and the transport plane fails closed.

## Rotation under load

`sds-certificate-rotation.txt` captures three successive SVID validity windows
from a single pod with `RESTARTS 0`:

```
23:28:05 → 00:28:15
23:56:04 → 00:56:14
00:23:56 → 01:24:06
```

Renewal occurs at roughly half the one-hour TTL rather than at expiry, so a
fresh credential is always in hand before the old one dies. mTLS traffic
continues through the whole window, including past 00:28 when the first
credential expired.

This is the answer to the standard objection that short-lived credentials are
operationally fragile. Three replacements, continuous traffic, no restarts, no
operator action. The practicum argued short TTLs were viable; this demonstrates
it.

The trust bundle stayed constant across all three rotations, which is the
separation between CA lifecycle and workload credential lifecycle that IA-5
cares about.

## Outstanding: the wrong-identity test

`negative-no-identity.txt` proves that a workload with **no** credential is
refused. It does not prove that a workload holding a **valid** credential from
the same trust domain is refused when its SPIFFE ID is not on the server's allow
list.

That second case is the stronger AC-3 result, because it shows the authorisation
decision turning on identity rather than on mere possession of a certificate
issued by the trust domain. An assessor reviewing access enforcement will ask
for it.

To run it, give an already-authorised workload a label that makes it match a
ClusterSPIFFEID while keeping its own service account, then point it at the
echo-server. It will hold a valid SVID with the wrong SPIFFE ID, and the
server's `match_typed_subject_alt_names` should reject the connection during the
handshake rather than before it. The expected distinction is that the handshake
is attempted and fails on certificate validation, rather than failing because no
certificate exists.

Capture as `negative-wrong-identity.txt`.
