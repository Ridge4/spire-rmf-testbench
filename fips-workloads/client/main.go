// A mutually authenticated TLS client whose identity comes from the SPIFFE
// Workload API and whose cryptography comes from the Go Cryptographic Module.
//
// Replaces the Envoy client and its curl sidecar from Phase 3. Here the
// application itself holds the identity and performs the handshake, so there is
// no proxy inside the cryptographic boundary.
package main

import (
	"context"
	"crypto/fips140"
	"crypto/tls"
	"fmt"
	"io"
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
	target := envOr("TARGET_URL", "https://fips-echo-server.payments.svc.cluster.local:8443/")
	interval := envDuration("REQUEST_INTERVAL", 60*time.Second)

	peerID := os.Getenv("AUTHORIZED_SERVER_ID")
	if peerID == "" {
		log.Fatal("AUTHORIZED_SERVER_ID must be set: the client authorises the server's SPIFFE ID too")
	}

	log.Printf("FIPS 140-3 mode: %v", fips140.Enabled())

	ctx, cancel := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer cancel()

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
	log.Printf("expecting server: %s", authorized)

	// Authentication is mutual in both directions: the client verifies the
	// server's SPIFFE ID as well as presenting its own.
	tlsConfig := tlsconfig.MTLSClientConfig(source, source, tlsconfig.AuthorizeID(authorized))

	client := &http.Client{
		Timeout:   10 * time.Second,
		Transport: &http.Transport{TLSClientConfig: tlsConfig},
	}

	// The X509Source keeps the certificate current in the background, so the
	// same client survives rotation without restarting. That is the property
	// Phase 3 demonstrated with Envoy; this loop demonstrates it here.
	for {
		request(ctx, client, target)

		select {
		case <-ctx.Done():
			log.Print("shutting down")
			return
		case <-time.After(interval):
		}
	}
}

func request(ctx context.Context, client *http.Client, target string) {
	reqCtx, cancel := context.WithTimeout(ctx, 10*time.Second)
	defer cancel()

	req, err := http.NewRequestWithContext(reqCtx, http.MethodGet, target, nil)
	if err != nil {
		log.Printf("request build failed: %v", err)
		return
	}

	resp, err := client.Do(req)
	if err != nil {
		// Expected for an unauthorised client: the handshake is refused.
		log.Printf("DENIED or unreachable: %v", err)
		return
	}
	defer resp.Body.Close()

	body, _ := io.ReadAll(resp.Body)

	var version, cipher string
	if resp.TLS != nil {
		version = tls.VersionName(resp.TLS.Version)
		cipher = tls.CipherSuiteName(resp.TLS.CipherSuite)
	}

	log.Printf("CLIENT status=%d tls_version=%s cipher=%s fips=%v",
		resp.StatusCode, version, cipher, fips140.Enabled())
	fmt.Print(string(body))
}

func envOr(key, def string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return def
}

func envDuration(key string, def time.Duration) time.Duration {
	if v := os.Getenv(key); v != "" {
		if d, err := time.ParseDuration(v); err == nil {
			return d
		}
	}
	return def
}
