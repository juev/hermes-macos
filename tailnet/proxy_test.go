package hermesnet

import (
	"bufio"
	"context"
	"crypto/tls"
	"errors"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"net/url"
	"strings"
	"testing"
	"time"
)

// localDial stands in for the node: the proxy is what is under test, so the addresses it is given
// are the test's own servers.
func localDial(ctx context.Context, network, addr string) (net.Conn, error) {
	var d net.Dialer
	return d.DialContext(ctx, network, addr)
}

func startProxy(t *testing.T, dial func(context.Context, string, string) (net.Conn, error)) *url.URL {
	t.Helper()
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("listen: %v", err)
	}
	go serve(ln, dial, newRing(20))
	t.Cleanup(func() { ln.Close() })
	return &url.URL{Scheme: "http", Host: ln.Addr().String()}
}

// A dashboard on the tailnet is often plain HTTP, which URLSession sends to the proxy in absolute
// form rather than as a CONNECT.
func TestPlainHTTPGoesThroughTheProxy(t *testing.T) {
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		io.WriteString(w, "hello "+r.URL.Path)
	}))
	defer upstream.Close()

	client := &http.Client{Transport: &http.Transport{Proxy: http.ProxyURL(startProxy(t, localDial))}}
	resp, err := client.Get(upstream.URL + "/api/status")
	if err != nil {
		t.Fatalf("get: %v", err)
	}
	defer resp.Body.Close()
	body, err := io.ReadAll(resp.Body)
	if err != nil {
		t.Fatalf("read: %v", err)
	}
	if string(body) != "hello /api/status" {
		t.Fatalf("body = %q, want the upstream's answer", body)
	}
}

// The socket of the dashboard is `wss`, and the session reaches it the way it reaches an https
// request: a CONNECT, then TLS inside the tunnel.
func TestConnectCarriesTLS(t *testing.T) {
	upstream := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		io.WriteString(w, "over tls")
	}))
	defer upstream.Close()

	client := &http.Client{Transport: &http.Transport{
		Proxy:           http.ProxyURL(startProxy(t, localDial)),
		TLSClientConfig: &tls.Config{InsecureSkipVerify: true},
	}}
	resp, err := client.Get(upstream.URL)
	if err != nil {
		t.Fatalf("get over connect: %v", err)
	}
	defer resp.Body.Close()
	body, _ := io.ReadAll(resp.Body)
	if string(body) != "over tls" {
		t.Fatalf("body = %q, want the upstream's answer", body)
	}
}

// A name the node cannot reach ends the tunnel with an answer, not with a wait that looks like a
// slow dashboard.
func TestAFailedDialIsAnswered(t *testing.T) {
	proxy := startProxy(t, func(context.Context, string, string) (net.Conn, error) {
		return nil, errors.New("no route to that name")
	})
	conn, err := net.Dial("tcp", proxy.Host)
	if err != nil {
		t.Fatalf("dial the proxy: %v", err)
	}
	defer conn.Close()
	io.WriteString(conn, "CONNECT nowhere.mesh.internal:443 HTTP/1.1\r\nHost: nowhere.mesh.internal:443\r\n\r\n")
	buf := make([]byte, 128)
	n, err := conn.Read(buf)
	if err != nil {
		t.Fatalf("read: %v", err)
	}
	if !strings.Contains(string(buf[:n]), "502") {
		t.Fatalf("answer = %q, want a 502", buf[:n])
	}
}

// A client may write its first bytes in the same segment as the CONNECT head. net/http reads them
// into the reader it hands over on hijack, so a tunnel that copies the raw connection drops them
// and the handshake inside the tunnel hangs. The bytes must reach the node.
func TestConnectCarriesBytesWrittenWithTheHead(t *testing.T) {
	upstream, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("listen: %v", err)
	}
	defer upstream.Close()
	// An echo: whatever the tunnel carried comes back to the client.
	go func() {
		for {
			conn, err := upstream.Accept()
			if err != nil {
				return
			}
			go func() {
				io.Copy(conn, conn)
				conn.Close()
			}()
		}
	}()

	proxy := startProxy(t, localDial)
	conn, err := net.Dial("tcp", proxy.Host)
	if err != nil {
		t.Fatalf("dial the proxy: %v", err)
	}
	defer conn.Close()
	// A tunnel that loses the bytes never answers, so the read must fail rather than wait.
	if err := conn.SetDeadline(time.Now().Add(2 * time.Second)); err != nil {
		t.Fatalf("deadline: %v", err)
	}

	head := "CONNECT " + upstream.Addr().String() + " HTTP/1.1\r\nHost: " + upstream.Addr().String() + "\r\n\r\n"
	if _, err := io.WriteString(conn, head+"PING"); err != nil {
		t.Fatalf("write the head and the first bytes together: %v", err)
	}

	reader := bufio.NewReader(conn)
	status, err := reader.ReadString('\n')
	if err != nil {
		t.Fatalf("read the answer to CONNECT: %v", err)
	}
	if !strings.Contains(status, "200") {
		t.Fatalf("answer = %q, want a 200", status)
	}
	if _, err := reader.ReadString('\n'); err != nil {
		t.Fatalf("read the end of the answer: %v", err)
	}
	echo := make([]byte, len("PING"))
	if _, err := io.ReadFull(reader, echo); err != nil {
		t.Fatalf("read the echo: %v (the bytes written with the CONNECT head were dropped)", err)
	}
	if string(echo) != "PING" {
		t.Fatalf("echo = %q, want %q", echo, "PING")
	}
}
