module github.com/Ridge4/spire-rmf-testbench/fips-workloads

// Go 1.24 or newer is required: the Go Cryptographic Module v1.0.0 (CMVP
// certificate #5247) is frozen from 1.24 and selected with GOFIPS140=v1.0.0.
go 1.24

require github.com/spiffe/go-spiffe/v2 v2.5.0

require (
	github.com/Microsoft/go-winio v0.6.2 // indirect
	github.com/go-jose/go-jose/v4 v4.0.4 // indirect
	github.com/zeebo/errs v1.4.0 // indirect
	golang.org/x/crypto v0.31.0 // indirect
	golang.org/x/net v0.33.0 // indirect
	golang.org/x/sys v0.28.0 // indirect
	golang.org/x/text v0.21.0 // indirect
	google.golang.org/genproto/googleapis/rpc v0.0.0-20241202173237-19429a94021a // indirect
	google.golang.org/grpc v1.70.0 // indirect
	google.golang.org/protobuf v1.36.1 // indirect
)
