# Phase 6: a FIPS 140-3 path for the whole flow

Phase 5 established that the identity plane can be built on a validated module
and the Envoy transport plane cannot. This phase acts on that: it removes the
proxy from the cryptographic boundary and performs the handshake in Go, so
issuance and transmission run on the same validated module.

It also runs the wrong-identity negative test that Phase 3 left outstanding.

## The argument

Phase 3 put Envoy between the application and the network. Envoy held the SVID,
terminated TLS, and the application spoke plain HTTP to localhost. That is the
normal service-mesh pattern and it works well, but it places a C++ proxy inside
the cryptographic boundary, and Envoy's only compile-time FIPS option is
BoringSSL-FIPS, validated against FIPS 140-2. Those certificates moved to
Historical status on 2026-09-21 and are not valid for a new authorization.

The alternative is to let the application do its own TLS. SPIRE is Go, the
go-spiffe library is Go, and the Go Cryptographic Module v1.0.0 holds CMVP
certificate #5247 under FIPS 140-3. Build the workload with
`GOFIPS140=v1.0.0` and the handshake happens inside the validated module.

This inverts the usual advice. The common recommendation for workload identity
is to front everything with a service mesh so applications need no crypto
awareness. In a federal boundary that recommendation currently costs you the
ability to make an SC-13 claim with open-source components, because the mesh
data plane has no FIPS 140-3 path and the Go application does.

## What is built

`fips-workloads/` holds a client and server of about a hundred lines each:

- identity from the SPIFFE Workload API over the CSI-mounted socket, no key
  material on disk
- `tlsconfig.MTLSServerConfig` / `MTLSClientConfig` with `AuthorizeID`, so each
  side verifies the other's SPIFFE ID rather than merely accepting any
  certificate from the trust domain
- `crypto/fips140.Enabled()` reported at startup and on every request, so the
  FIPS claim is observable at runtime
- the `X509Source` refreshes the SVID in the background, so rotation needs no
  restart

The Dockerfile asserts the build rather than trusting it. It fails if
`GOFIPS140=v1.0.0` is not recorded in the binary, and fails if any
BoringCrypto symbol is present. A build that silently fell back to the standard
library would be worse than one that stopped.

## Build and deploy

```bash
cd fips-workloads && go mod tidy && cd ..
./scripts/build-fips-workloads.sh

sed -i "s/<ACCOUNT_ID>/$(aws sts get-caller-identity --query Account --output text)/g" \
  manifests/phase-6/*.yaml

kubectl apply -f manifests/phase-6/01-identities.yaml
kubectl apply -f manifests/phase-6/02-fips-workloads.yaml
kubectl apply -f manifests/phase-6/03-negative-test.yaml
```

The Phase 3 Envoy pair can stay running. Both use the same SPIRE, the same
trust domain and the same issuance path, so the two handshakes are directly
comparable and differ only in which module performs the TLS.

## Verification

```bash
kubectl -n payments logs deploy/fips-echo-server | grep -E "FIPS|MTLS"
kubectl -n payments logs deploy/fips-echo-client | grep -E "FIPS|CLIENT"
```

Expected on the server:

```
FIPS 140-3 mode: true
MTLS peer=spiffe://spire-rmf.lab/ns/payments/sa/fips-echo-client
     tls_version=TLS 1.3 cipher=TLS_AES_128_GCM_SHA256 fips=true
```

Three things in one line that Phase 3 could not produce together: a completed
mutually authenticated session, the negotiated parameters, and a runtime
assertion that the module performing it is the validated one.

Expect TLS 1.3 here. Phase 3 negotiated TLS 1.2 because the Envoy config set a
minimum and no maximum; Go's defaults prefer 1.3. State this explicitly in the
paper: the version difference follows from configuration and library defaults,
not from the cryptographic module, and a reader comparing the two log lines
will otherwise attribute it to FIPS.

## The wrong-identity test

`03-negative-test.yaml` is the test Phase 3 left outstanding, and it is the
sharper of the two negative cases.

The Phase 3 rogue client failed because SDS never issued it a certificate, so
no handshake was attempted. That proves credentials are required. It does not
prove the authorisation decision turns on identity.

This workload holds a **valid** SVID from the same trust domain. It is selected
by a ClusterSPIFFEID through its pod label, so SPIRE issues to it normally, but
it runs under a different service account, so its SPIFFE ID is
`.../sa/fips-wrong-identity`. The server's `AuthorizeID` expects
`.../sa/fips-echo-client`.

```bash
kubectl -n payments logs deploy/fips-wrong-identity | tail -10
kubectl -n payments logs deploy/fips-echo-server | grep -i "unexpected ID\|bad certificate" | tail -5
```

Expected: the client obtains its own SVID successfully, attempts the handshake,
and the connection is refused on peer verification. The distinction from the
Phase 3 failure is the point: there the connection failed for lack of a
certificate, here it fails despite having one.

That pair is what an AC-3 claim needs. Possession of a credential from the
trust domain is not sufficient; the specific identity has to be authorised.

## What this still does not establish

**The rest of the stack is not FIPS-configured.** The AWS endpoints in use are
commercial, not the `-fips` variants, and the deployment is in a commercial
region rather than GovCloud. SPIRE itself is still an upstream build, not one
compiled with `GOFIPS140`. This phase makes the *transport* claim defensible,
not the whole system.

**Building SPIRE with GOFIPS140 is the obvious next step** and is a packaging
exercise rather than a research one: clone the repository, build with the flag,
mirror the image, point the values at it. Doing so would put the issuance path
on the same certificate as the transport path, at which case the only remaining
gaps are the AWS endpoints and the region.

**The certificate covers a specific module version.** CMVP #5247 names the Go
Cryptographic Module v1.0.0. A later Go release moves to a later module, which
needs its own validation. `GOFIPS140=v1.0.0` pins to the validated one, which
is why the build asserts on that string.

Note that the binary records `GOFIPS140=v1.0.0-c2097c7c`, with a suffix
identifying the module source the toolchain embedded, alongside the build tag
`fips140v1.0`. The assertion matches on the `v1.0.0` prefix. Anyone comparing
the build record against the CMVP listing should expect that form rather than a
bare version string.

**`fips140.Enabled()` reports the runtime mode, not the certificate.** It says
the binary was built against the module and is running in FIPS mode. It does
not and cannot tell you the certificate's current status, which is a CMVP
lookup. Both are needed; neither substitutes for the other.

## Evidence to capture (evidence/phase-6/)

| File | Shows |
|---|---|
| `build-settings.txt` | `go version -m` output recording `GOFIPS140=v1.0.0` |
| `fips-mtls-handshake.txt` | the handshake with runtime FIPS assertion |
| `fips-client-success.txt` | the client side, including the response body |
| `negative-wrong-identity.txt` | a valid SVID with the wrong SPIFFE ID, refused |
| `envoy-vs-go-comparison.txt` | the two handshake records side by side |
