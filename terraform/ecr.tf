# Container registries for the air-gapped cluster.
#
# The cluster has no route to ghcr.io, registry.k8s.io, docker.io or cgr.dev,
# so every image it runs is served from this account. See
# docs/phase-1-images.md for how that constraint was discovered and what it
# costs.
#
# These repositories were originally created imperatively by
# scripts/mirror-images.sh and scripts/build-fips-workloads.sh. Declaring them
# here instead does three things:
#
#   1. A fresh `terraform apply` produces the registries, rather than them
#      appearing as a side effect the first time someone runs a script.
#   2. The scan and immutability settings become reviewable configuration
#      instead of command-line arguments. Those settings are the RA-5 and
#      supply-chain evidence described in docs/phase-1-images.md, so they
#      belong somewhere an assessor can read them.
#   3. Lifecycle policies bound how long untagged layers accumulate.
#
# The scripts still create a repository if one is missing, so they keep working
# for images added mid-session. Terraform is the source of truth for the known
# set.

locals {
  # Images mirrored from upstream registries. Paths are flattened because ECR
  # repository names cannot contain a registry host: for example
  # registry.k8s.io/sig-storage/csi-node-driver-registrar becomes
  # sig-storage/csi-node-driver-registrar, and bare Docker Hub official images
  # land under library/.
  mirrored_repositories = [
    "spiffe/spire-server",
    "spiffe/spire-agent",
    "spiffe/spire-controller-manager",
    "spiffe/spiffe-csi-driver",
    "spiffe/spiffe-helper",
    "spiffe/oidc-discovery-provider",
    "sig-storage/csi-node-driver-registrar",
    "kubectl",
    "library/busybox",
    "chainguard/bash",
    "chainguard/min-toolkit-debug",
    "smallstep/step-cli",
    "envoyproxy/envoy",
    "curlimages/curl",
    "aws-observability/aws-for-fluent-bit",
  ]

  # Built in this repository, not mirrored: the Phase 6 workloads, compiled
  # against the FIPS 140-3 validated Go Cryptographic Module.
  built_repositories = [
    "fips/echo-server",
    "fips/echo-client",
  ]

  all_repositories = concat(local.mirrored_repositories, local.built_repositories)
}

resource "aws_ecr_repository" "images" {
  for_each = toset(local.all_repositories)

  name = each.value

  # Mirroring breaks upstream digest pinning: re-pushing an image produces a
  # new manifest digest, so the upstream digest never resolves here. Immutable
  # tags are the compensating control, since a tag cannot be moved after push.
  # docs/phase-1-images.md sets out that trade-off.
  image_tag_mutability = "IMMUTABLE"

  image_scanning_configuration {
    scan_on_push = true
  }

  encryption_configuration {
    encryption_type = "AES256"
  }

  # The testbench is rebuilt often and the images are reproducible from
  # scripts/mirror-images.sh, so repositories are not retained on destroy.
  # A production registry would set this false and keep the images.
  force_delete = true

  tags = {
    Name    = each.value
    Purpose = contains(local.built_repositories, each.value) ? "FIPS workload build" : "Upstream image mirror"
  }
}

# Untagged layers accumulate when a tag is rebuilt. Nothing depends on them
# once a new manifest is pushed.
resource "aws_ecr_lifecycle_policy" "expire_untagged" {
  for_each = aws_ecr_repository.images

  repository = each.value.name

  policy = jsonencode({
    rules = [{
      rulePriority = 1
      description  = "Expire untagged images after 14 days"
      selection = {
        tagStatus   = "untagged"
        countType   = "sinceImagePushed"
        countUnit   = "days"
        countNumber = 14
      }
      action = { type = "expire" }
    }]
  })
}
