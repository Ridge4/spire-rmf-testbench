# Phase 5: FIPS 140-3

Addresses the SC-13 row of the evidence-gap table. The outcome is not a clean
pass. It is a documented split: the identity plane can be built on a validated
module today, and the transport plane cannot.

## What changed since the practicum was written

The original report listed "FIPS 140-2/3 Cryptography" as future work, treating
the two as interchangeable. They no longer are.

**FIPS 140-2 is finished for new work.** On 21 September 2026 every remaining
FIPS 140-2 certificate moved to Historical status in the CMVP database.
Historical does not mean the certificate vanishes; it means it is no longer
valid for new federal procurement or current compliance reliance. Deployed
hardware keeps running, but a new authorization package cannot rest on a 140-2
certificate.

So "FIPS 140-2/3" is no longer a meaningful phrase in a control claim. Only an
Active FIPS 140-3 certificate counts, and the certificate has to name the exact
module version in use.

**Go now has a validated native module.** The Go Cryptographic Module v1.0.0
holds CMVP Certificate #5247, a FIPS 140-3 Level 1 software module validated on
27 April 2026, covered by CAVP Certificate A6650. It is frozen from Go 1.24 and
selected at build time with `GOFIPS140=v1.0.0`, which also sets the binary's
default runtime mode to `fips140=on`.

This matters because it removes what used to be the main obstacle. Before, a Go
project wanting FIPS had to use the golang-fips/OpenSSL fork or Go+BoringCrypto,
both unsupported detours. Now it is a build-time environment variable on the
upstream toolchain.

## The finding: the two planes are not in the same position

### SPIRE, the identity plane: validated module available

SPIRE is Go. A SPIRE server and agent built with Go 1.24+ and
`GOFIPS140=v1.0.0` link the module covered by certificate #5247.

This is not hypothetical within the SPIFFE project itself. SPIKE, a SPIFFE
project, has already moved to exactly this: FIPS enabled at build time with
`GOFIPS140=v1.0.0`, explicitly retiring its older BoringCrypto implementation.

What this phase did **not** do is produce a validated SPIRE build. The images in
this testbench are upstream `ghcr.io/spiffe/spire-server:1.15.3` and friends,
which are not built with `GOFIPS140`. Producing one means building SPIRE from
source with the flag set and mirroring the result, which is a packaging exercise
rather than a research one. The relevant point for the paper is that the path
exists and is supported, which was not true when the practicum was written.

### Envoy, the transport plane: no FIPS 140-3 path upstream

Envoy is C++ and its compile-time FIPS option is BoringSSL-FIPS, built with
`--define boringssl=fips`. That module is validated against **FIPS 140-2**.

With FIPS 140-2 now Historical, upstream Envoy has no compile-time FIPS 140-3
option in tree. This is an open question in the project rather than a settled
one: an issue raised in the Envoy repository asks the maintainers directly
whether BoringSSL's FIPS 140-3 validated module will be adopted as the
compile-time path, and what users should do for a FIPS 140-3 build in the
meantime. The removal of AWS-LC, previously the other compile-time option,
narrowed the choices further.

Commercial and third-party builds do claim FIPS 140-3. Chainguard, for example,
publishes a FIPS 140-3 Envoy variant using a validated OpenSSL provider for
system and Go binaries and a validated BoringCrypto module for the Envoy binary
itself. Those are purchasable answers, not upstream ones.

### Why the asymmetry matters

The mTLS handshake captured in Phase 3 is performed by Envoy, not by SPIRE.
SPIRE issues the credential; Envoy negotiates the session and does the
encryption. So for SC-8 and SC-13:

- The **issuance** path can be built on a validated module today.
- The **transmission** path, which is what SC-8 is actually about, cannot be,
  using upstream open-source components alone.

A federal deployment of SPIFFE plus Envoy therefore has three options, and the
choice is procurement as much as engineering:

1. Buy a vendor build of Envoy or a service mesh with an Active FIPS 140-3
   certificate, and verify the certificate rather than the marketing claim.
2. Terminate TLS somewhere already validated and keep Envoy out of the
   cryptographic boundary.
3. Use a Go-based proxy or a go-spiffe application built with `GOFIPS140`, so
   the handshake happens in the Go module rather than in BoringSSL. This
   narrows the component choice considerably but keeps the whole path on one
   validated module.

Option 3 is the one that follows from this testbench's architecture and is
worth saying out loud, because it is not the obvious choice and it inverts the
usual advice to put a service mesh in front of everything.

## AWS-side cryptography

Two parts of the stack sit outside both planes:

**KMS.** The CA signing keys live in KMS, which uses validated hardware security
modules. Confirm the certificate and its status for the exact module rather than
relying on a product page; a vendor's "FIPS compliant" language is not evidence
of an Active certificate.

**Service endpoints.** AWS publishes FIPS-specific endpoints
(`kms-fips.us-east-1.amazonaws.com` and equivalents). Commercial endpoints are
not the FIPS ones. For a private-only VPC this is also an endpoint question: the
interface endpoint service names differ, so switching to FIPS endpoints means
changing what `terraform/endpoints.tf` creates. GovCloud differs again. This
testbench uses commercial endpoints and is therefore not FIPS-configured on the
AWS side either.

## Verification

`scripts/fips-check.sh` reports what the running binaries actually link, rather
than what the documentation claims:

```bash
./scripts/fips-check.sh > evidence/phase-5/fips-status.txt
```

It checks the Go build settings recorded in the SPIRE binaries, the Envoy
version banner for a `BoringSSL-FIPS` suffix, and whether the AWS endpoints in
use are the FIPS variants.

The general rule, and the one worth repeating in the paper: a module is
validated only if CMVP lists an **Active FIPS 140-3 certificate for the exact
version deployed**. Check it at csrc.nist.gov. A datasheet, a press release, or
the words "FIPS compliant" are not evidence, and an assessor should not accept
them.

## Honest position for the paper

This phase does not close SC-13. It replaces a vague future-work item with a
precise statement:

> The SPIRE control plane can be built against the Go Cryptographic Module
> v1.0.0 (CMVP #5247), which is FIPS 140-3 validated. The Envoy data plane that
> performs the mTLS handshake has no upstream FIPS 140-3 option following the
> FIPS 140-2 sunset in September 2026, so a federal deployment must either
> procure a validated proxy build or move TLS termination into a component built
> on a validated module. The testbench itself uses unvalidated upstream builds
> and commercial AWS endpoints, and makes no FIPS claim.

That is a more useful result than a pass would have been. Most published
material on SPIFFE in regulated environments either ignores FIPS or asserts it
without naming a certificate. Naming the gap, with a certificate number on one
side and an open upstream issue on the other, is the contribution.

## Follow-up work

- Build SPIRE from source with `GOFIPS140=v1.0.0`, mirror it, and verify with
  `go version -m` that the binary records the module. That converts the identity
  plane from "can be" to "is".
- Confirm current CMVP status for the KMS HSM module and record the certificate
  number.
- Evaluate whether the Phase 3 topology can be re-done with a go-spiffe
  application doing its own TLS, removing Envoy from the cryptographic boundary.
- Re-check the Envoy issue periodically; if BoringSSL obtains a FIPS 140-3
  certificate the position changes.

## Evidence to capture (evidence/phase-5/)

| File | Shows |
|---|---|
| `fips-status.txt` | what the running binaries actually link |
| `go-build-settings.txt` | `go version -m` output for the SPIRE binaries |
| `envoy-version.txt` | the Envoy version banner and its SSL variant |
| `cmvp-references.md` | certificate numbers and status, with the date checked |
