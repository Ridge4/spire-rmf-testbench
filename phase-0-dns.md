# Phase 0: Resolving the Private Only DNS problem without a public resolver

## The original problem

In the practicum testbench, associating the EKS cluster with an IAM OIDC
provider failed from inside a Private Only VPC. VPC private DNS answered for the
EKS service domain but returned no record for the OIDC issuer hostname, and the
enclave had no route to a public resolver. The workaround was to point the jump
host's resolver at 8.8.8.8.

That workaround invalidated the premise it was meant to support. In the
environment being emulated, egress to a public resolver is a boundary violation,
not a fix, so the deployment as documented would not have been reproducible
under the stated constraints.

## Why the problem happens

Two different things are being conflated when this fails.

1. **AWS API calls from inside the VPC** (EC2, ECR, STS, EKS, SSM, KMS, Logs).
   These need a network path. Interface endpoints with `private_dns_enabled`
   provide it: the endpoint takes over DNS for its service name inside the VPC
   and resolves it to a private address. This is handled in `endpoints.tf`.

2. **Creating the IAM OIDC provider**, which is an IAM control-plane operation
   performed by whoever runs Terraform. It requires fetching the issuer's TLS
   certificate from the public OIDC endpoint. It is not something cluster
   workloads do, and it does not need to happen from inside the enclave at all.

The practicum conflated the two by running everything from the in-VPC jump host.

## The compliant approach used here

**Run Terraform from your workstation, not the jump host.** The OIDC provider is
created from outside the enclave, over the public internet, exactly as a
provisioning pipeline outside the boundary would do it. Nothing inside the VPC
needs public DNS.

**Give in-VPC traffic interface endpoints.** Everything the cluster and jump host
need at runtime resolves privately. `endpoints.tf` covers EC2, ECR (api and dkr),
STS, EKS, EKS Auth, SSM (three endpoints), CloudWatch Logs, KMS, ELB, and
Autoscaling, plus the S3 gateway endpoint that ECR layer pulls depend on.

**Prefer EKS Pod Identity over IRSA.** Pod Identity uses the `eks-auth` endpoint
and does not involve an OIDC provider at all. Where it suffices, the problem
disappears rather than being worked around. Set `create_oidc_provider = false`
if you do not need IRSA for anything.

**For a true air-gapped variant**, replace step one with a Route 53 Resolver
outbound endpoint and forwarding rules, or host the issuer metadata internally.
Note this in the paper as the fully disconnected option; it is more complex and
was not required here.

## Evidence to capture for the paper

- `terraform apply` output showing `endpoint_public_access = false`.
- The endpoint list from `aws ec2 describe-vpc-endpoints`.
- A successful image pull and node join with no NAT gateway and no internet
  gateway in the VPC (`aws ec2 describe-nat-gateways`, `describe-internet-gateways`
  both return empty).
- VPC flow logs showing no egress to public resolvers. Query the log group named
  in the `flow_log_group` output for destination port 53.
- `/etc/resolv.conf` on the jump host, showing only the VPC resolver (`.2` address).

That last pair is the direct replacement for the practicum's workaround, and the
artifact a reviewer will look for.

## Staging tooling on the jump host

The jump host has no internet route. Amazon Linux repositories are served from
regional S3 and remain reachable through the S3 gateway endpoint, so `dnf` works.
kubectl and helm are not in those repositories. Two options:

1. **Stage via S3 (in-region).** Download kubectl and helm on your workstation,
   upload them to a bucket in the same region, and pull them down with the AWS
   CLI on the jump host. Traffic stays on the gateway endpoint.

2. **Skip the jump host for kubectl.** Port-forward to the private API endpoint
   through SSM and run kubectl locally:

   ```
   aws ssm start-session \
     --target <jump-host-instance-id> \
     --document-name AWS-StartPortForwardingSessionToRemoteHost \
     --parameters host="<cluster-endpoint-hostname>",portNumber="443",localPortNumber="8443"
   ```

   Then point a kubeconfig at `https://localhost:8443`. You will need
   `tls-server-name` set to the cluster endpoint hostname for certificate
   validation to pass.

Option 1 is closer to how a real enclave operates and is the better one to
document in the paper.
