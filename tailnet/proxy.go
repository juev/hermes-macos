package hermesnet

import (
	"context"
	"io"
	"net"
	"net/http"
	"time"
)

// serve is the proxy the app talks to: URLSession opens HTTPS and WSS through CONNECT and sends a
// plain HTTP request in absolute form, and both reach the node here.
//
// tsnet's own Loopback() hands out a SOCKS5 server with a username and a password, which is what
// the Android client uses. URLSession takes a proxy dictionary with no place for credentials — its
// CFNetwork layer speaks SOCKS5, not SOCKS5 with an RFC 1929 login — so the app gets an HTTP proxy
// instead, bound to 127.0.0.1 and reachable by this user alone.
func serve(ln net.Listener, dial func(context.Context, string, string) (net.Conn, error), lg *ring) {
	tr := &http.Transport{
		DialContext: func(ctx context.Context, network, addr string) (net.Conn, error) {
			ctx, cancel := context.WithTimeout(ctx, 30*time.Second)
			defer cancel()
			return dial(ctx, network, addr)
		},
		IdleConnTimeout: 90 * time.Second,
		// A tailnet dashboard is often plain HTTP: the node carries it, nothing is upgraded.
		ForceAttemptHTTP2: false,
	}
	h := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method == http.MethodConnect {
			tunnel(w, r, dial, lg)
			return
		}
		out := r.Clone(r.Context())
		out.RequestURI = ""
		out.Header.Del("Proxy-Connection")
		resp, err := tr.RoundTrip(out)
		if err != nil {
			lg.add("proxy: " + r.Host + ": " + err.Error())
			http.Error(w, err.Error(), http.StatusBadGateway)
			return
		}
		defer resp.Body.Close()
		for name, values := range resp.Header {
			for _, value := range values {
				w.Header().Add(name, value)
			}
		}
		w.WriteHeader(resp.StatusCode)
		io.Copy(w, resp.Body)
	})
	srv := &http.Server{Handler: h, ReadHeaderTimeout: 15 * time.Second}
	if err := srv.Serve(ln); err != nil && err != http.ErrServerClosed {
		lg.add("proxy exited: " + err.Error())
	}
}

// tunnel answers a CONNECT: the node dials the address, the person's client gets a 200 and the two
// connections are spliced. A name the tailnet does not know fails here, with a sentence in the log.
func tunnel(w http.ResponseWriter, r *http.Request, dial func(context.Context, string, string) (net.Conn, error), lg *ring) {
	hijacker, ok := w.(http.Hijacker)
	if !ok {
		http.Error(w, "this server cannot hand the connection over", http.StatusInternalServerError)
		return
	}
	client, buffered, err := hijacker.Hijack()
	if err != nil {
		return
	}
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	upstream, err := dial(ctx, "tcp", r.Host)
	if err != nil {
		lg.add("proxy: " + r.Host + ": " + err.Error())
		client.Write([]byte("HTTP/1.1 502 Bad Gateway\r\n\r\n"))
		client.Close()
		return
	}
	if _, err := client.Write([]byte("HTTP/1.1 200 Connection Established\r\n\r\n")); err != nil {
		upstream.Close()
		client.Close()
		return
	}
	// The reader of the hijack may already hold bytes the client wrote behind the request head — a
	// request pipelined after the CONNECT, a `ClientHello` sent before the 200 arrived. Copying the
	// raw connection would drop them: the tunnel would be up and the handshake inside it would hang.
	// The buffered bytes go first, the connection the rest.
	go io.Copy(upstream, buffered)
	io.Copy(client, upstream)
	upstream.Close()
	client.Close()
}
