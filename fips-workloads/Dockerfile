# Build the go-spiffe workloads against the FIPS 140-3 validated Go
# Cryptographic Module.
#
# GOFIPS140=v1.0.0 selects the module covered by CMVP certificate #5247 and
# sets the binary's default runtime mode to fips140=on. The build fails loudly
# rather than silently producing a non-FIPS binary: the assertion below checks
# that the module version is actually recorded in the binary.
#
# Go 1.24 or newer is required; the module is frozen from 1.24.

ARG GO_VERSION=1.25
ARG GO_FIPS_MODULE=v1.0.0

FROM golang:${GO_VERSION} AS build
ARG GO_FIPS_MODULE
ARG TARGET

WORKDIR /src
COPY go.mod go.sum* ./
RUN go mod download

COPY . .

ENV GOFIPS140=${GO_FIPS_MODULE}
ENV CGO_ENABLED=0

RUN go build -trimpath -o /out/app ./${TARGET}

# Verify rather than assume. The binary must record the module version, and
# must contain no BoringCrypto symbols: GOFIPS140 and GOEXPERIMENT=boringcrypto
# are mutually exclusive, and a build that silently fell back would be worse
# than a build that failed.
RUN go version -m /out/app | tee /out/build-settings.txt | grep -q "GOFIPS140=${GO_FIPS_MODULE}" \
      || (echo "ERROR: GOFIPS140=${GO_FIPS_MODULE} not recorded in the binary" >&2; exit 1) \
 && [ "$(go tool nm /out/app | grep -ci goboringcrypto || true)" = "0" ] \
      || (echo "ERROR: BoringCrypto symbols present; this is not a native FIPS build" >&2; exit 1)

FROM gcr.io/distroless/static-debian12:nonroot
COPY --from=build /out/app /app
COPY --from=build /out/build-settings.txt /build-settings.txt
USER nonroot:nonroot
ENTRYPOINT ["/app"]
