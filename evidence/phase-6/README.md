# Phase 6 evidence

Closes the transport half of SC-13, and the wrong-identity case Phase 3 left
open. See docs/phase-6-fips-build.md.

| File | Shows |
|---|---|
| `build-settings.txt` | both binaries record `GOFIPS140`, `fips140=on`, and the `fips140v1.0` build tag |
| `fips-mtls-handshake.txt` | completed mTLS with `fips=true` asserted at runtime |
| `fips-client-success.txt` | the client side, including the server's response body |
| `negative-wrong-identity.txt` | a valid SVID with an unauthorised ID, refused by both sides |
| `envoy-vs-go-comparison.txt` | the Phase 3 and Phase 6 handshakes side by side |

## The result

```
FIPS 140-3 mode: true
MTLS peer=spiffe://spire-rmf.lab/ns/payments/sa/fips-echo-client
     tls_version=TLS 1.3 cipher=TLS_AES_128_GCM_SHA256 fips=true
```

A mutually authenticated session where the identity came from the SPIFFE
Workload API and the handshake was performed by the Go Cryptographic Module.
Both peers assert `fips=true` at runtime, and the build record shows how the
binaries were produced. Runtime assertion and build provenance together; either
alone would be weaker.

## Reading the build record

Two details in `build-settings.txt` need stating before anyone compares it to
the CMVP listing.

**The recorded version carries a suffix.**

```
build  GOFIPS140=v1.0.0-c2097c7c
build  -tags=fips140v1.0
```

The certificate names the Go Cryptographic Module v1.0.0. The binary records
`v1.0.0-c2097c7c`, where the suffix identifies the specific module source the
toolchain embedded. The build tag `fips140v1.0` confirms the v1.0 module was
selected. A reviewer expecting an exact string match against the certificate
should know this is the expected form, not a different module.

**FIPS mode is the default, not merely available.**

```
build  DefaultGODEBUG=...,fips140=on,...
```

`GOFIPS140` at build time sets the binary's default runtime mode, so the
process runs in FIPS mode without an environment variable. `fips140.Enabled()`
returning true in the logs confirms it held at runtime.

**One flag worth checking.** The same `DefaultGODEBUG` string contains
`tlssha1=1`. That governs acceptance of SHA-1 signature algorithms in TLS. It
has no bearing on which module performs the cryptography, but "the module is
validated" and "the TLS configuration is maximally restricted" are different
claims, and only the first is evidenced here. Worth confirming what the flag
permits before asserting the second.

**No BoringCrypto.** The build asserts zero `goboringcrypto` symbols and fails
otherwise. `GOFIPS140` and `GOEXPERIMENT=boringcrypto` are mutually exclusive,
and a silent fallback would be worse than a failed build.

## The wrong-identity test

This is the Phase 3 gap closed, and both halves are recorded.

The client obtains a genuine SVID and is refused:

```
own identity: spiffe://spire-rmf.lab/ns/payments/sa/fips-wrong-identity
DENIED or unreachable: remote error: tls: bad certificate
```

The server names what it rejected:

```
http: TLS handshake error from 10.42.1.210:56042:
  unexpected ID "spiffe://spire-rmf.lab/ns/payments/sa/fips-wrong-identity"
```

Three outcomes are now distinguishable across Phases 3 and 6:

| Case | Credential | Result |
|---|---|---|
| Phase 3 rogue | none issued | no handshake attempted; SDS supplied no certificate |
| Phase 6 wrong identity | valid SVID, unauthorised ID | handshake attempted, refused on peer verification |
| Authorised client | valid SVID, authorised ID | session established |

The middle row is the AC-3 claim. Possession of a certificate from the trust
domain is not sufficient; the specific identity has to be on the allow list, and
the server records which identity it turned away.

## Reading the comparison file

`envoy-vs-go-comparison.txt` puts the two handshake records together. The log
formats differ, so read it carefully rather than at a glance.

Both use the same SPIRE deployment, trust domain, CA and issuance path. The one
deliberate variable is which module performs the TLS.

The TLS version difference, 1.2 in Phase 3 and 1.3 in Phase 6, is **not** a
consequence of FIPS. The Envoy configuration set a minimum of TLS 1.2 and no
maximum; Go's defaults prefer 1.3. Attributing that difference to the
cryptographic module would be wrong, and the paper should say so explicitly
rather than let a reader infer it.

What the comparison does show is the thing Phase 5 argued and this phase
demonstrates: the Envoy path produces a working mTLS session with no FIPS 140-3
claim available to it, and the Go path produces an equivalent session on a
module with an Active certificate.
