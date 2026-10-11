# CMVP references

Certificate status must be confirmed at csrc.nist.gov and recorded with the date
checked. Status changes; a note here without a date is not evidence.

| Module | Certificate | Standard | Status | Checked |
|---|---|---|---|---|
| Go Cryptographic Module v1.0.0 | CMVP #5247 (CAVP A6650) | FIPS 140-3 Level 1 | Active, validated 2026-04-27 | 2026-10-11 |
| Go Cryptographic Module v1.26.0 | CAVP A8028 | FIPS 140-3 | Pending Review on the MIP list as of 2026-04-28 | 2026-10-11 |
| BoringSSL-FIPS (Envoy compile-time path) | see BoringSSL FIPS.md | FIPS 140-2 | Historical since 2026-09-21 | 2026-10-11 |
| AWS KMS HSM module | TO BE CONFIRMED | | | |

Notes:

- All FIPS 140-2 certificates moved to Historical status on 2026-09-21. They
  remain in the database but are not valid for new federal procurement or
  current compliance reliance.
- The deployed version must match the version named on the certificate. A
  certificate for v1.0.0 says nothing about v1.1.0.
