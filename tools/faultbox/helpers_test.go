package main

import (
	"bufio"
	"bytes"
	"encoding/json"
	"sync"
	"testing"
)

// lockedBuffer is a bytes.Buffer safe to read while the box's goroutines write to it.
type lockedBuffer struct {
	mu sync.Mutex
	b  bytes.Buffer
}

func (l *lockedBuffer) Write(p []byte) (int, error) {
	l.mu.Lock()
	defer l.mu.Unlock()
	return l.b.Write(p)
}

func (l *lockedBuffer) String() string {
	l.mu.Lock()
	defer l.mu.Unlock()
	return l.b.String()
}

// records returns the JSON lines of the output whose event is ev, in order.
func records(t *testing.T, out string, ev string) []map[string]any {
	t.Helper()
	var recs []map[string]any
	sc := bufio.NewScanner(bytes.NewBufferString(out))
	for sc.Scan() {
		var m map[string]any
		if json.Unmarshal(sc.Bytes(), &m) != nil {
			continue
		}
		if m["event"] == ev {
			recs = append(recs, m)
		}
	}
	return recs
}

// newTestBox returns a box writing into a buffer, with a disk directory and an exit that records its code.
func newTestBox(t *testing.T, l Limits) (*Box, *lockedBuffer, *exitRecorder) {
	t.Helper()
	buf := &lockedBuffer{}
	ex := &exitRecorder{}
	b := NewBox(buf, l, t.TempDir(), "test-scenario", false, ex.exit)
	t.Cleanup(b.Close)
	return b, buf, ex
}

type exitRecorder struct {
	mu    sync.Mutex
	codes []int
	// atExit, if set, runs when exit is called (to look at the log at that moment).
	atExit func()
}

func (e *exitRecorder) exit(code int) {
	if e.atExit != nil {
		e.atExit()
	}
	e.mu.Lock()
	defer e.mu.Unlock()
	e.codes = append(e.codes, code)
}

func (e *exitRecorder) got() []int {
	e.mu.Lock()
	defer e.mu.Unlock()
	return append([]int(nil), e.codes...)
}
