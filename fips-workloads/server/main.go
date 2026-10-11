// A mutually authenticated TLS server whose identity comes from the SPIFFE
// Workload API and whose cryptography comes from the Go Cryptographic Module.
//
// This replaces the Envoy server used in Phase 3. The point is not that Envoy
// is unsuitable, it is that Envoy's compile-time FIPS path is BoringSSL-FIPS,
// validated against FIPS 140-2, which moved to Historical status on
// 2026-09-21. Performing the handshake in Go instead puts the transport on the
// same validated module as the identity plane. See docs/phase-5-fips.md.
package main

import (
	"context"
	"crypto/fips140"
	"crypto/tls"
	"fmt"
	"log"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"

	"github.com/spiffe/go-spiffe/v2/spiffeid"
	"github.com/spiffe/go-spiffe/v2/spiffetls/tlsconfig"
	"github.com/spiffe/go-spiffe/v2/workloadapi"
)

func main() {
	socket := envOr("SPIFFE_ENDPOINT_SOCKET", "unix:///spiffe-workload-api/spire-agent.sock")
	listen := envOr("LISTEN_ADDR", ":8443")

	peerID := os.Getenv("AUTHORIZED_CLIENT_ID")
	if peerID == "" {
		log.Fatal("AUTHORIZED_CLIENT_ID must be set: this server authorises exactly one SPIFFE ID")
	}

	// Report the cryptographic posture at startup. This is what makes the FIPS
	// claim checkable at runtime rather than inferred from the build flags.
	log.Printf("FIPS 140-3 mode: %v", fips140.Enabled())

	ctx, cancel := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer cancel()

	// One X509Source serves both roles: it supplies this server's own SVID and
	// the trust bundle used to verify the peer. No key material is read from
	// disk; it arrives over the Workload API socket and rotates automatically.
	source, err := workloadapi.NewX509Source(ctx,
		workloadapi.WithClientOptions(workloadapi.WithAddr(socket)))
	if err != nil {
		log.Fatalf("workload API: %v", err)
	}
	defer source.Close()

	svid, err := source.GetX509SVID()
	if err != nil {
		log.Fatalf("no SVID: %v", err)
	}
	log.Printf("own identity: %s", svid.ID)

	authorized := spiffeid.RequireFromString(peerID)
	log.Printf("authorising only: %s", authorized)

	// MTLSServerConfig requires a client certificate and authorises on the
	// peer's SPIFFE ID. That is the AC-3 decision: holding any certificate from
	// the trust domain is not sufficient, it has to be this identity.
	tlsConfig := tlsconfig.MTLSServerConfig(source, source, tlsconfig.AuthorizeID(authorized))

	mux := http.NewServeMux()
	mux.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		state := r.TLS
		peer := "unknown"
		if state != nil && len(state.PeerCertificates) > 0 {
			if uris := state.PeerCertificates[0].URIs; len(uris) > 0 {
				peer = uris[0].String()
			}
		}

		// The equivalent of Phase 3's Envoy access log line, emitted by the
		// application itself rather than by a proxy.
		log.Printf("MTLS peer=%s tls_version=%s cipher=%s fips=%v",
			peer,
			tls.VersionName(state.Version),
			tls.CipherSuiteName(state.CipherSuite),
			fips140.Enabled(),
		)

		fmt.Fprintf(w, "hello over mTLS from the go-spiffe server\n")
		fmt.Fprintf(w, "peer:        %s\n", peer)
		fmt.Fprintf(w, "tls version: %s\n", tls.VersionName(state.Version))
		fmt.Fprintf(w, "cipher:      %s\n", tls.CipherSuiteName(state.CipherSuite))
		fmt.Fprintf(w, "fips mode:   %v\n", fips140.Enabled())
	})

	srv := &http.Server{
		Addr:              listen,
		Handler:           mux,
		TLSConfig:         tlsConfig,
		ReadHeaderTimeout: 10 * time.Second,
	}

	go func() {
		<-ctx.Done()
		shutdownCtx, done := context.WithTimeout(context.Background(), 5*time.Second)
		defer done()
		_ = srv.Shutdown(shutdownCtx)
	}()

	log.Printf("listening on %s", listen)
	// Certificates come from TLSConfig, so both arguments are empty.
	if err := srv.ListenAndServeTLS("", ""); err != nil && err != http.ErrServerClosed {
		log.Fatalf("serve: %v", err)
	}
}

func envOr(key, def string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return def
}
