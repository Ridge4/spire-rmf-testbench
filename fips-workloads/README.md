# FIPS workloads

A mutually authenticated client and server that obtain their identities from
the SPIFFE Workload API and perform the TLS handshake in the Go Cryptographic
Module v1.0.0 (CMVP certificate #5247).

These replace the Envoy pair from Phase 3. The reason is in
`docs/phase-5-fips.md`: Envoy's compile-time FIPS path is BoringSSL-FIPS,
validated against FIPS 140-2, which moved to Historical status on 2026-09-21.
There is no upstream FIPS 140-3 option for Envoy. Moving the handshake into Go
puts issuance and transmission on the same validated module.

## What they demonstrate

- The application holds its own identity. There is no proxy in the
  cryptographic boundary.
- Authorisation is on the peer's SPIFFE ID in both directions, not merely on
  possession of a certificate from the trust domain.
- `crypto/fips140.Enabled()` is reported at startup and on every request, so
  the FIPS claim is checkable at runtime rather than inferred from build flags.
- The `X509Source` refreshes the SVID in the background, so rotation happens
  without restarting.

## Build

```bash
go mod tidy          # generates go.sum
../scripts/build-fips-workloads.sh
```

The Dockerfile asserts that `GOFIPS140=v1.0.0` is recorded in the binary and
that no BoringCrypto symbols are present. It fails the build rather than
producing something that looks FIPS-enabled and is not.

## Verify a built binary by hand

```bash
go version -m ./app | grep GOFIPS140      # expect GOFIPS140=v1.0.0
go tool nm ./app | grep -c goboringcrypto # expect 0
```

The container also carries `/build-settings.txt` with the full build record.
