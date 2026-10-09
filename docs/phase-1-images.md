# Finding: SPIRE cannot be installed in an air-gapped cluster without a registry mirror

## What happened

With the cluster in its Private Only configuration, every SPIRE pod failed to
start with `ImagePullBackOff`. The kubelet could not reach the registries the
chart points at:

```
Failed to pull image "ghcr.io/spiffe/spiffe-csi-driver:0.2.7":
  dial tcp 140.82.112.33:443: i/o timeout
Failed to pull image "registry.k8s.io/sig-storage/csi-node-driver-registrar:v2.15.0":
  dial tcp 34.96.108.209:443: i/o timeout
```

The timeouts are the boundary working. 140.82.x is GitHub. The VPC has no
internet gateway, no NAT gateway, and no route to it.

The practicum build never hit this. That cluster had a private API endpoint but
could still reach the public internet for image pulls. The control plane was
private, the supply chain was not. That gap is worth stating plainly in the
paper, because it shows how much of "Private Only" the original emulation
actually exercised.

## The images

Chart 0.30.3 pulls from five registries:

| Registry | Images |
|---|---|
| ghcr.io | spire-server, spire-agent, spire-controller-manager, spiffe-csi-driver, spiffe-helper, oidc-discovery-provider |
| registry.k8s.io | kubectl, sig-storage/csi-node-driver-registrar |
| docker.io | busybox, smallstep/step-cli |
| cgr.dev | chainguard/bash, chainguard/min-toolkit-debug |

An ATO package has to account for all of them: origin, signing, update path, and
how each one reaches the enclave. That is CM-7 and SR-3/SR-4 territory and none
of it appeared in the original control mapping.

## Resolution

Images are mirrored into the account's own ECR registry, which the cluster
already reaches over the interface endpoints built in Phase 0. No egress is
opened. `scripts/mirror-images.sh` does the copy with `crane` and writes the
mapping to `evidence/phase-1/image-mirror-map.txt`.

This is the normal approach for disconnected environments, not a workaround. It
also improves the compliance position in three ways:

1. Images are pinned in a registry the organisation owns instead of pulled from
   a public registry at pod start.
2. ECR scan-on-push produces a vulnerability record per image, which is RA-5
   evidence the original build had nothing to offer for.
3. Pod starts no longer depend on a third party registry being up, which matters
   for a tier-0 identity service.

ECR repository names cannot contain a registry host, so paths are flattened.
`registry.k8s.io/sig-storage/csi-node-driver-registrar` becomes
`sig-storage/csi-node-driver-registrar`, and bare Docker Hub images land under
`library/`.

## Finding the images is harder than it looks

The obvious check does not work:

```bash
helm template spire spiffe/spire --version 0.30.3 --values values.yaml \
  | grep -oE 'image: .*' | sort -u
```

That misses init containers and tool images, and it misses components that only
render under certain conditions. Six separate value overrides were needed, found
one crash at a time:

| Image | Values key | Found by |
|---|---|---|
| spire-server | `spire-server.image` | template output |
| spire-agent | `spire-agent.image` | template output |
| spire-controller-manager | `spire-server.controllerManager.image` | template output |
| spiffe-csi-driver | `spiffe-csi-driver.image` | template output |
| csi-node-driver-registrar | `spiffe-csi-driver.nodeDriverRegistrar.image` | template output |
| kubectl | `spire-server.tools.kubectl.image` | hook job failure |
| busybox | `spire-server.chown.image` and `.tools.busybox.image` | server init container crash |
| chainguard/bash | `spire-agent.fsGroupFix.image` and `.socketAlternate.image` | agent init container crash |

The reliable method is to install, then read `kubectl describe pod` for every
workload and collect the image list from there. For the paper: an air-gapped
deployment cannot work out its image dependencies from the chart alone. Plan for
several install-and-fail cycles, or mirror every image the chart references
whether or not it appears to be used.

## Digest pinning conflicts with mirroring

The chainguard images are pinned by digest in the chart:

```yaml
tag: latest@sha256:90041f375e30f41aa7e0390075d8a69dc61900771d52fa98d63ee5d03d866a58
```

Pinning by digest is good supply chain practice. It also cannot survive a
mirror. Pushing the image into ECR produces a new manifest digest, so the
upstream digest never resolves there. The override has to drop the digest and
use a tag.

That is a real conflict between two things a federal deployment wants at the
same time. Integrity controls want immutable digest references. Disconnected
operation requires a local mirror, which changes the digest. The options are:

- re-pin to the mirrored digest in your own values, which keeps immutability but
  means updating the pin on every mirror refresh, or
- use tags against the mirror and rely on ECR tag immutability plus scan results
  instead.

This repository takes the second option and sets ECR repositories to
`IMAGE_TAG_MUTABILITY=IMMUTABLE` so a tag cannot be moved after push. The first
option is stronger and is the right choice for a production enclave.

## Limitation

`busybox` and `cgr.dev/chainguard/min-toolkit-debug` still render with upstream
references in the `tests:` blocks of some subcharts. `helm install` never pulls
them, only `helm test` would. In a fully disconnected deployment `helm test`
would fail unless those are mirrored and overridden too.

## Evidence

- `image-pull-failure.txt` - kubelet timeouts before mirroring
- `image-mirror-map.txt` - source to ECR mapping
- `ecr-repositories.json` - the mirrored repositories
- `pods-running-after-mirror.txt` - all pods running from ECR
