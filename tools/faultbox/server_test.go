package main

import (
	"context"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

const testToken = "faultbox-test-token-0123456789"

func newTestServer(t *testing.T, l Limits, tokenContent *string) (*Server, *Box, *lockedBuffer) {
	t.Helper()
	b, out, _ := newTestBox(t, l)
	tokenFile := ""
	if tokenContent != nil {
		tokenFile = filepath.Join(t.TempDir(), "token")
		if err := os.WriteFile(tokenFile, []byte(*tokenContent), 0o600); err != nil {
			t.Fatal(err)
		}
	}
	return NewServer(b, tokenFile, "start-seed"), b, out
}

func call(s *Server, method, target, auth string) *httptest.ResponseRecorder {
	r := httptest.NewRequest(method, target, nil)
	if auth != "" {
		r.Header.Set("Authorization", auth)
	}
	w := httptest.NewRecorder()
	s.ServeHTTP(w, r)
	return w
}

var controlCalls = []string{
	"/memory?mb=1", "/disk?mb=1", "/cpu?millicores=10&seconds=1", "/crash?code=1", "/ready?state=false",
	"/errors?rate=1", "/latency?ms=5", "/log?pattern=noise", "/reset",
}

func TestControlRefusedWithoutToken(t *testing.T) {
	t.Parallel()
	ptr := func(s string) *string { return &s }
	cases := []struct {
		name  string
		token *string // token file content; nil: no --token-file
		auth  string
	}{
		{"no token file configured", nil, "Bearer " + testToken},
		{"empty token file", ptr(""), "Bearer "},
		{"empty token file, any bearer", ptr("\n"), "Bearer x"},
		{"token shorter than the minimum", ptr("short"), "Bearer short"},
		{"no Authorization header", ptr(testToken), ""},
		{"wrong scheme", ptr(testToken), "Basic " + testToken},
		{"wrong token", ptr(testToken), "Bearer " + testToken + "x"},
		{"token prefix", ptr(testToken), "Bearer " + testToken[:20]},
	}
	for _, c := range cases {
		s, b, out := newTestServer(t, Limits{MemoryMB: 64, DiskMB: 64, CPUMillicores: 100}, c.token)
		for _, target := range controlCalls {
			for _, method := range []string{http.MethodPost, http.MethodGet} {
				if w := call(s, method, target, c.auth); w.Code != http.StatusUnauthorized {
					t.Errorf("%s: %s %s: got %d, want 401", c.name, method, target, w.Code)
				}
			}
		}
		if n := len(records(t, out.String(), "fault")); n != 0 {
			t.Errorf("%s: %d faults applied without a token", c.name, n)
		}
		if !b.ready.Load() || b.heldMB() != 0 || b.latency.Load() != 0 {
			t.Errorf("%s: state changed without a token", c.name)
		}
		if strings.Contains(out.String(), testToken) {
			t.Errorf("%s: the token reached the log", c.name)
		}
	}
}

func TestMissingTokenFileRefuses(t *testing.T) {
	t.Parallel()
	b, out, _ := newTestBox(t, Limits{})
	s := NewServer(b, filepath.Join(t.TempDir(), "absent"), "start-seed")
	if w := call(s, http.MethodPost, "/ready?state=false", "Bearer "+testToken); w.Code != http.StatusUnauthorized {
		t.Fatalf("got %d, want 401", w.Code)
	}
	if len(records(t, out.String(), "fault")) != 0 || !b.ready.Load() {
		t.Fatal("a call was applied with no token file")
	}
}

func TestControlWithToken(t *testing.T) {
	t.Parallel()
	tok := testToken + "\n" // a Secret file often ends in a newline
	s, b, out := newTestServer(t, Limits{MemoryMB: 64, DiskMB: 64, CPUMillicores: 100}, &tok)
	auth := "Bearer " + testToken
	if w := call(s, http.MethodGet, "/ready?state=false", auth); w.Code != http.StatusMethodNotAllowed {
		t.Fatalf("GET: got %d, want 405", w.Code)
	}
	if w := call(s, http.MethodPost, "/ready?state=false&seed=call-seed", auth); w.Code != http.StatusOK {
		t.Fatalf("ready: got %d %s", w.Code, w.Body)
	}
	if w := call(s, http.MethodGet, "/readyz", ""); w.Code != http.StatusServiceUnavailable {
		t.Fatalf("readyz after ready=false: got %d, want 503", w.Code)
	}
	recs := records(t, out.String(), "fault")
	if len(recs) != 1 || recs[0]["seed"] != "call-seed" || recs[0]["source"] != "endpoint" {
		t.Fatalf("records %v", recs)
	}
	if w := call(s, http.MethodPost, "/memory?mb=60", auth); w.Code != http.StatusUnprocessableEntity {
		t.Fatalf("memory over the cap: got %d, want 422", w.Code)
	}
	if w := call(s, http.MethodPost, "/memory?mb=60&cross=true", auth); w.Code != http.StatusUnprocessableEntity {
		t.Fatalf("memory with cross on a box started without --cross-limits: got %d, want 422", w.Code)
	}
	b.crossLimits = true
	if w := call(s, http.MethodPost, "/memory?mb=60&cross=true", auth); w.Code != http.StatusOK {
		t.Fatalf("memory over the cap with cross: got %d %s", w.Code, w.Body)
	}
	if b.heldMB() != 60 {
		t.Fatalf("held %d MiB, want 60", b.heldMB())
	}
	if w := call(s, http.MethodPost, "/memory?mb=lots", auth); w.Code != http.StatusBadRequest {
		t.Fatalf("bad parameter: got %d, want 400", w.Code)
	}
	if w := call(s, http.MethodPost, "/log?pattern=nope", auth); w.Code != http.StatusBadRequest {
		t.Fatalf("unknown pattern: got %d, want 400", w.Code)
	}
	if w := call(s, http.MethodPost, "/reset", auth); w.Code != http.StatusOK {
		t.Fatalf("reset: got %d", w.Code)
	}
	if w := call(s, http.MethodGet, "/readyz", ""); w.Code != http.StatusOK {
		t.Fatalf("readyz after reset: got %d, want 200", w.Code)
	}
	recs = records(t, out.String(), "fault")
	if last := recs[len(recs)-1]; last["fault"] != "reset" || last["seed"] != "start-seed" {
		t.Fatalf("last record %v, want a reset with the start seed", last)
	}
}

func TestTokenIsReadAtEachCall(t *testing.T) {
	t.Parallel()
	tok := testToken
	s, _, _ := newTestServer(t, Limits{}, &tok)
	if w := call(s, http.MethodPost, "/latency?ms=0", "Bearer "+testToken); w.Code != http.StatusOK {
		t.Fatalf("got %d", w.Code)
	}
	rotated := "rotated-token-abcdefghijklmnop"
	if err := os.WriteFile(s.tokenFile, []byte(rotated), 0o600); err != nil {
		t.Fatal(err)
	}
	if w := call(s, http.MethodPost, "/latency?ms=0", "Bearer "+testToken); w.Code != http.StatusUnauthorized {
		t.Fatalf("old token after rotation: got %d, want 401", w.Code)
	}
	if w := call(s, http.MethodPost, "/latency?ms=0", "Bearer "+rotated); w.Code != http.StatusOK {
		t.Fatalf("new token after rotation: got %d", w.Code)
	}
	if err := os.Remove(s.tokenFile); err != nil {
		t.Fatal(err)
	}
	if w := call(s, http.MethodPost, "/latency?ms=0", "Bearer "+rotated); w.Code != http.StatusUnauthorized {
		t.Fatalf("token file removed: got %d, want 401", w.Code)
	}
}

func TestAppEndpointErrorsAndLatency(t *testing.T) {
	t.Parallel()
	tok := testToken
	s, _, _ := newTestServer(t, Limits{}, &tok)
	var slept time.Duration
	s.sleep = func(_ context.Context, d time.Duration) { slept += d }
	auth := "Bearer " + testToken
	if w := call(s, http.MethodGet, "/", ""); w.Code != http.StatusOK || slept != 0 {
		t.Fatalf("no fault: got %d, slept %v", w.Code, slept)
	}
	if w := call(s, http.MethodPost, "/latency?ms=800", auth); w.Code != http.StatusOK {
		t.Fatalf("latency: got %d", w.Code)
	}
	if w := call(s, http.MethodPost, "/errors?rate=1", auth); w.Code != http.StatusOK {
		t.Fatalf("errors: got %d", w.Code)
	}
	if w := call(s, http.MethodGet, "/", ""); w.Code != http.StatusInternalServerError || slept != 800*time.Millisecond {
		t.Fatalf("with faults: got %d, slept %v; want 500 after 800ms", w.Code, slept)
	}
	if w := call(s, http.MethodGet, "/healthz", ""); w.Code != http.StatusOK {
		t.Fatalf("healthz: got %d", w.Code)
	}
	if w := call(s, http.MethodGet, "/nope", ""); w.Code != http.StatusNotFound {
		t.Fatalf("unknown path: got %d", w.Code)
	}
}

func TestLatencyEndsWithTheRequest(t *testing.T) {
	t.Parallel()
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	start := time.Now()
	sleepCtx(ctx, time.Minute)
	if time.Since(start) > time.Second {
		t.Fatal("sleep did not end with the request")
	}
}
