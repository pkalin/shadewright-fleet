package main

import (
	"bytes"
	"context"
	"crypto/sha256"
	"crypto/subtle"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"os"
	"strconv"
	"strings"
	"time"
)

const (
	minTokenBytes = 16
	maxTokenBytes = 4096
)

// Server serves the probes, the application endpoint and the token-protected control endpoints.
type Server struct {
	box       *Box
	tokenFile string
	seed      string // the start seed, used when a call names none
	sleep     func(context.Context, time.Duration)
}

// NewServer returns the handler. tokenFile is read at each control call; with no usable token every control call
// is refused.
func NewServer(box *Box, tokenFile, seed string) *Server {
	return &Server{box: box, tokenFile: tokenFile, seed: seed, sleep: sleepCtx}
}

// sleepCtx waits for d or until the request ends.
func sleepCtx(ctx context.Context, d time.Duration) {
	t := time.NewTimer(d)
	defer t.Stop()
	select {
	case <-ctx.Done():
	case <-t.C:
	}
}

// controls maps each control path to the parser of its query.
var controls = map[string]func(url.Values) (Fault, error){
	"/memory": func(q url.Values) (Fault, error) {
		mb, err := intParam(q, "mb", -1)
		cross, err2 := boolParam(q, "cross", false)
		return Fault{Kind: KindMemory, MB: mb, Cross: cross}, errors.Join(err, err2)
	},
	"/disk": func(q url.Values) (Fault, error) {
		mb, err := intParam(q, "mb", -1)
		cross, err2 := boolParam(q, "cross", false)
		return Fault{Kind: KindDisk, MB: mb, Cross: cross}, errors.Join(err, err2)
	},
	"/cpu": func(q url.Values) (Fault, error) {
		m, err := intParam(q, "millicores", -1)
		s, err2 := intParam(q, "seconds", 300)
		cross, err3 := boolParam(q, "cross", false)
		return Fault{Kind: KindCPU, Millicores: m, Seconds: s, Cross: cross}, errors.Join(err, err2, err3)
	},
	"/crash": func(q url.Values) (Fault, error) {
		c, err := intParam(q, "code", 1)
		return Fault{Kind: KindCrash, Code: c}, err
	},
	"/ready": func(q url.Values) (Fault, error) {
		r, err := boolParam(q, "state", false)
		return Fault{Kind: KindReady, Ready: r}, err
	},
	"/errors": func(q url.Values) (Fault, error) {
		v := q.Get("rate")
		if v == "" {
			return Fault{}, errors.New("rate is required")
		}
		r, err := strconv.ParseFloat(v, 64)
		return Fault{Kind: KindErrors, Rate: r}, err
	},
	"/latency": func(q url.Values) (Fault, error) {
		ms, err := intParam(q, "ms", -1)
		return Fault{Kind: KindLatency, MS: ms}, err
	},
	"/log": func(q url.Values) (Fault, error) {
		n, err := intParam(q, "per_second", 1)
		s, err2 := intParam(q, "seconds", 60)
		return Fault{Kind: KindLog, Pattern: q.Get("pattern"), PerSecond: n, Seconds: s}, errors.Join(err, err2)
	},
	"/reset": func(url.Values) (Fault, error) { return Fault{Kind: KindReset}, nil },
}

// intParam reads an integer parameter; def < 0 means it is required.
func intParam(q url.Values, name string, def int) (int, error) {
	v := q.Get(name)
	if v == "" {
		if def < 0 {
			return 0, fmt.Errorf("%s is required", name)
		}
		return def, nil
	}
	n, err := strconv.Atoi(v)
	if err != nil {
		return 0, fmt.Errorf("%s: not an integer", name)
	}
	return n, nil
}

func boolParam(q url.Values, name string, def bool) (bool, error) {
	v := q.Get(name)
	if v == "" {
		return def, nil
	}
	b, err := strconv.ParseBool(v)
	if err != nil {
		return false, fmt.Errorf("%s: not a boolean", name)
	}
	return b, nil
}

// readToken reads the token from its file at each use, so a rotated Secret needs no restart.
func readToken(path string) ([]byte, error) {
	if path == "" {
		return nil, errors.New("no token file configured")
	}
	f, err := os.Open(path)
	if err != nil {
		return nil, errors.New("token file unreadable")
	}
	defer func() { _ = f.Close() }()
	b, err := io.ReadAll(io.LimitReader(f, maxTokenBytes+1))
	if err != nil {
		return nil, errors.New("token file unreadable")
	}
	b = bytes.TrimSpace(b)
	if len(b) < minTokenBytes || len(b) > maxTokenBytes {
		return nil, fmt.Errorf("token must be %d to %d bytes", minTokenBytes, maxTokenBytes)
	}
	return b, nil
}

// authorized compares the bearer token with the file's in constant time (over digests, so the length does not
// leak either). The reason is for the server log only and never holds a token.
func (s *Server) authorized(r *http.Request) (bool, string) {
	want, err := readToken(s.tokenFile)
	if err != nil {
		return false, err.Error()
	}
	got, ok := strings.CutPrefix(r.Header.Get("Authorization"), "Bearer ")
	if !ok || got == "" {
		return false, "no bearer token"
	}
	w, g := sha256.Sum256(want), sha256.Sum256([]byte(got))
	if subtle.ConstantTimeCompare(w[:], g[:]) != 1 {
		return false, "wrong token"
	}
	return true, ""
}

func (s *Server) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	switch r.URL.Path {
	case "/healthz":
		writeText(w, http.StatusOK, "ok")
		return
	case "/readyz":
		if s.box.ready.Load() {
			writeText(w, http.StatusOK, "ready")
		} else {
			writeText(w, http.StatusServiceUnavailable, "not ready")
		}
		return
	case "/":
		s.serveApp(w, r)
		return
	}
	parse, ok := controls[r.URL.Path]
	if !ok {
		writeText(w, http.StatusNotFound, "not found")
		return
	}
	// The token comes first: without it nothing about the call is looked at.
	if ok, reason := s.authorized(r); !ok {
		s.box.log.Warn("request refused", "event", "request_refused", "path", r.URL.Path, "reason", reason)
		writeText(w, http.StatusUnauthorized, "unauthorized")
		return
	}
	if r.Method != http.MethodPost {
		w.Header().Set("Allow", http.MethodPost)
		writeText(w, http.StatusMethodNotAllowed, "use POST")
		return
	}
	q := r.URL.Query()
	f, err := parse(q)
	if err != nil {
		writeText(w, http.StatusBadRequest, err.Error())
		return
	}
	seed := q.Get("seed")
	if seed == "" {
		seed = s.seed
	}
	switch err := s.box.Apply(f, SourceEndpoint, seed); {
	case err == nil:
		writeText(w, http.StatusOK, "applied "+string(f.Kind))
	case errors.Is(err, errOverCap):
		writeText(w, http.StatusUnprocessableEntity, err.Error())
	case errors.Is(err, errInvalid):
		writeText(w, http.StatusBadRequest, err.Error())
	default:
		writeText(w, http.StatusInternalServerError, "fault failed")
	}
}

// serveApp is the workload's own endpoint: the latency and error faults act on it.
func (s *Server) serveApp(w http.ResponseWriter, r *http.Request) {
	if ms := s.box.latency.Load(); ms > 0 {
		s.sleep(r.Context(), time.Duration(ms)*time.Millisecond)
	}
	if s.box.injectError() {
		writeText(w, http.StatusInternalServerError, "injected error")
		return
	}
	writeText(w, http.StatusOK, "faultbox ok")
}

func writeText(w http.ResponseWriter, code int, msg string) {
	w.Header().Set("Content-Type", "text/plain; charset=utf-8")
	w.Header().Set("X-Content-Type-Options", "nosniff")
	w.WriteHeader(code)
	_, _ = io.WriteString(w, msg+"\n")
}
