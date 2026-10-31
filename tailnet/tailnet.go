// Package hermesnet runs a userspace Tailscale node inside the Hermes macOS app and serves a local
// proxy onto the tailnet. It joins a Tailscale or a Headscale control server, needs no VPN
// entitlement and no tunnel device, so the app works next to the Tailscale app and next to another
// VPN, and reaches a dashboard that only the tailnet can see.
//
// The functions use only strings and errors, the types gomobile can bind. They mirror
// github.com/juev/hermes/tailnet, the node of the Android client; the proxy differs, because
// URLSession cannot send the credentials tsnet's SOCKS5 server asks for (see proxy.go).
package hermesnet

import (
	"context"
	"encoding/json"
	"fmt"
	"log"
	"net"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"

	"tailscale.com/envknob"
	"tailscale.com/logtail"
	"tailscale.com/tsnet"
)

var (
	mu       sync.Mutex
	srv      *tsnet.Server
	proxy    net.Listener
	proxyErr error
	logs     = newRing(200)
	authURL  string
)

func init() {
	// The node belongs to the person's own control server: its logs stay on this Mac.
	envknob.SetNoLogsNoSupport()
	logtail.Disable()
}

// Start brings the node up and returns "host:port" of its proxy, which listens before the node is
// running. An empty authKey makes the node wait for an interactive login; Status then carries the
// link to open. An empty controlURL means Tailscale's own control server; a Headscale instance is
// its base URL, e.g. "https://headscale.example.org".
func Start(dir, controlURL, authKey, hostname string) (string, error) {
	mu.Lock()
	defer mu.Unlock()
	stopLocked()
	authURL = ""
	// The app has no home or cache directory, where Tailscale looks for its log state.
	logDir := filepath.Join(dir, "logs")
	if err := os.MkdirAll(logDir, 0o700); err != nil {
		return "", err
	}
	os.Setenv("TS_LOGS_DIR", logDir)
	s := &tsnet.Server{
		Dir:        dir,
		Hostname:   hostname,
		ControlURL: strings.TrimSuffix(strings.TrimSpace(controlURL), "/"),
		AuthKey:    strings.TrimSpace(authKey),
		Logf:       func(format string, args ...any) { logs.add(fmt.Sprintf(format, args...)) },
		UserLogf: func(format string, args ...any) {
			line := fmt.Sprintf(format, args...)
			logs.add(line)
			if i := strings.Index(line, "https://"); i >= 0 && strings.Contains(line, "authenticate") {
				authURL = strings.Fields(line[i:])[0]
			}
		},
	}
	if err := s.Start(); err != nil {
		s.Close()
		return "", err
	}
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		s.Close()
		return "", err
	}
	srv = s
	proxy = ln
	go serve(ln, s, logs)
	return ln.Addr().String(), nil
}

// Stop shuts the node and its proxy down; the state stays in the directory for the next Start.
func Stop() {
	mu.Lock()
	defer mu.Unlock()
	stopLocked()
}

func stopLocked() {
	if proxy != nil {
		proxy.Close()
		proxy = nil
	}
	if srv != nil {
		srv.Close()
		srv = nil
	}
}

// Status returns JSON: {"state", "authUrl", "ips", "name", "error"}.
func Status() string {
	mu.Lock()
	s := srv
	mu.Unlock()
	out := map[string]any{"state": "Stopped"}
	if s == nil {
		return encode(out)
	}
	lc, err := s.LocalClient()
	if err != nil {
		out["error"] = err.Error()
		return encode(out)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()
	st, err := lc.StatusWithoutPeers(ctx)
	if err != nil {
		out["error"] = err.Error()
		return encode(out)
	}
	out["state"] = st.BackendState
	url := st.AuthURL
	if url == "" {
		url = authURL
	}
	out["authUrl"] = url
	if st.Self != nil {
		ips := make([]string, 0, len(st.Self.TailscaleIPs))
		for _, ip := range st.Self.TailscaleIPs {
			ips = append(ips, ip.String())
		}
		out["ips"] = ips
		out["name"] = st.Self.DNSName
	}
	return encode(out)
}

// Logs returns the last lines the node logged, oldest first.
func Logs() string {
	return strings.Join(logs.lines(), "\n")
}

func encode(v any) string {
	b, err := json.Marshal(v)
	if err != nil {
		return `{"state":"Error"}`
	}
	return string(b)
}

type ring struct {
	mu   sync.Mutex
	buf  []string
	size int
}

func newRing(size int) *ring { return &ring{size: size} }

func (r *ring) add(line string) {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.buf = append(r.buf, line)
	if len(r.buf) > r.size {
		r.buf = r.buf[len(r.buf)-r.size:]
	}
	log.Print(line)
}

func (r *ring) lines() []string {
	r.mu.Lock()
	defer r.mu.Unlock()
	return append([]string(nil), r.buf...)
}
