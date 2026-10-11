# Phase 0 evidence

Establishes the Private Only boundary and the compliant DNS approach that
replaces the practicum's public-resolver workaround. See docs/phase-0-dns.md.

| File | Shows |
|---|---|
| `terraform-output.txt` | the deployed stack, including the private cluster endpoint |
| `no-igw-no-nat.txt` | no internet gateway, no NAT gateway in the VPC |
| `vpc-endpoints.json` | the interface and gateway endpoints that replace them |
| `phase0-dns-evidence.txt` | resolver configuration, private name resolution, no egress |
| `nodes-ready.txt` | nodes joined with no public addresses |
| `system-pods.txt` | cluster add-ons running, images pulled over the endpoints |

## The core result

```
=== internet gateways ===
{ "InternetGateways": [] }
=== nat gateways ===
{ "NatGateways": [] }
```

Both empty, and the nodes reached `Ready` anyway. Every image pull, every
kubelet call and every AWS API call travelled over VPC endpoints. The practicum
emulated a Private Only enclave but retained internet access for image pulls;
this one does not.

`nodes-ready.txt` shows `EXTERNAL-IP <none>` on both nodes, and the EKS API
endpoint resolves to 10.42.x addresses, so `endpoint_public_access = false` is
observable rather than merely configured.

## What the DNS evidence does and does not show

`phase0-dns-evidence.txt` establishes three things:

1. The jump host uses only the VPC resolver (`nameserver 10.42.0.2`). No public
   resolver is configured anywhere, which is the direct replacement for the
   practicum's 8.8.8.8 workaround.
2. AWS service names resolve to private addresses in the VPC CIDR, two per
   service, one per availability zone. That is the interface endpoints
   answering.
3. Nothing outside AWS is reachable: `example.com`, `8.8.8.8` and
   `registry.k8s.io` all time out with curl exit 28.

**A correction to section 5 of that file.** Its label reads "External DNS
resolution fails", and the result line says `example.com` resolved via the VPC
resolver. The label is wrong and the result is right. The Amazon-provided
resolver answers public DNS queries normally; what the enclave lacks is a
*route*, not name resolution. Public names resolve and then cannot be reached.

This distinction matters for the paper. The claim is not that DNS is blocked. It
is that no traffic leaves the VPC, which the curl timeouts in section 4 and the
flow-log query both support. Section 5 should be read as redundant with section
4 rather than as an additional finding. `scripts/phase0-evidence.sh` reproduces
this capture with the claim stated correctly.

**An unexplained blank.** `eks-auth.us-east-1.amazonaws.com` returned no
address, although the endpoint exists and EKS Pod Identity demonstrably works
throughout Phases 1 to 4. Most likely the SDK reaches Pod Identity through the
node-local agent at 169.254.170.23 rather than by resolving that hostname. Worth
confirming rather than assuming; recorded here as an open question.

## Flow logs

VPC flow logs do not capture traffic to the Amazon-provided resolver, so a query
for DNS traffic to 10.42.0.2 returns nothing whether or not DNS is working. The
useful query is the inverse: DNS traffic to any destination *outside* the VPC
CIDR.

```
fields @timestamp, srcAddr, dstAddr, dstPort, action
| filter dstPort = 53 and not isIpv4InSubnet(dstAddr, "10.42.0.0/16")
| stats count() by dstAddr
```

That returned zero matches against 114 scanned records. Zero matches with a
non-zero scan count is the meaningful result; an empty log group would prove
nothing.

Do not extend this into a claim that no traffic reached public IP addresses. S3
gateway endpoint traffic shows public S3 addresses as the destination even
though it never leaves the AWS network, so the broader claim would be false.

## Note on capture date

These artifacts are from the first build (2026-10-09, cluster endpoint
`CFA165C7...`). The stack has since been destroyed and rebuilt twice from the
same Terraform with identical results, most recently on 2026-10-11. The
boundary configuration did not change between builds; only resource identifiers
did. Re-capturing against the current cluster would produce the same findings
with different IDs.
