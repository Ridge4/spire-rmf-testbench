# Phase 5 evidence

Addresses SC-13. See docs/phase-5-fips.md. The result is a documented gap
rather than a pass: the identity plane has a validated module available, the
transport plane does not.

| File | Shows |
|---|---|
| `fips-status.txt` | baseline posture: SPIRE images, Envoy SSL variant, AWS endpoint types |
| `cmvp-references.md` | certificate numbers and status, with the date checked |

## Baseline result, 2026-10-11

Nothing in the testbench is FIPS-configured, and the document says so:

- SPIRE images are upstream builds, not built with `GOFIPS140`
- Envoy reports `RELEASE/BoringSSL`, a standard build rather than `BoringSSL-FIPS`
- 0 of 15 VPC endpoints use `-fips` service names

This is the correct starting point. The finding is not that FIPS was achieved,
it is that a FIPS 140-3 path exists for the Go identity plane (CMVP #5247) and
does not exist upstream for the Envoy transport plane following the FIPS 140-2
sunset on 2026-09-21.

Regenerate with:

```bash
./scripts/fips-check.sh > evidence/phase-5/fips-status.txt
```
