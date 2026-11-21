package main

import (
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"syscall"
	"testing"
	"time"
)

// one checks that the output holds exactly one fault record, of kind k with the seed.
func one(t *testing.T, out string, k Kind, seed string) map[string]any {
	t.Helper()
	recs := records(t, out, "fault")
	if len(recs) != 1 {
		t.Fatalf("got %d fault records, want 1:\n%s", len(recs), out)
	}
	r := recs[0]
	if r["fault"] != string(k) || r["seed"] != seed || r["scenario"] != "test-scenario" {
		t.Fatalf("record %v, want fault %s seed %s", r, k, seed)
	}
	return r
}

func TestMemoryFault(t *testing.T) {
	t.Parallel()
	b, out, _ := newTestBox(t, Limits{MemoryMB: 64})
	if err := b.Apply(Fault{Kind: KindMemory, MB: 8}, SourceEndpoint, "s1"); err != nil {
		t.Fatal(err)
	}
	r := one(t, out.String(), KindMemory, "s1")
	if p := r["params"].(map[string]any); p["mb"] != float64(8) || p["cross"] != false {
		t.Fatalf("params %v", p)
	}
	if got := b.heldMB(); got != 8 {
		t.Fatalf("held %d MiB, want 8", got)
	}
	if err := b.Apply(Fault{Kind: KindMemory, MB: 2}, SourceEndpoint, "s1"); err != nil {
		t.Fatal(err)
	}
	if got := b.heldMB(); got != 2 {
		t.Fatalf("held %d MiB after shrinking, want 2", got)
	}
	if err := b.Apply(Fault{Kind: KindReset}, SourceEndpoint, "s1"); err != nil {
		t.Fatal(err)
	}
	if got := b.heldMB(); got != 0 {
		t.Fatalf("held %d MiB after reset, want 0", got)
	}
}

func TestRefusedFaultChangesNothing(t *testing.T) {
	t.Parallel()
	b, out, _ := newTestBox(t, Limits{MemoryMB: 64})
	err := b.Apply(Fault{Kind: KindMemory, MB: 49}, SourceEndpoint, "s1")
	if !errors.Is(err, errOverCap) {
		t.Fatalf("got %v, want a refusal over the cap", err)
	}
	if b.heldMB() != 0 {
		t.Fatal("a refused fault allocated memory")
	}
	if n := len(records(t, out.String(), "fault")); n != 0 {
		t.Fatalf("a refused fault wrote %d fault records", n)
	}
	if n := len(records(t, out.String(), "fault_refused")); n != 1 {
		t.Fatalf("got %d refusal records, want 1", n)
	}
}

func TestSeedRequired(t *testing.T) {
	t.Parallel()
	b, out, _ := newTestBox(t, Limits{})
	for _, seed := range []string{"", "has space", strings.Repeat("a", 65), `x"y`} {
		if err := b.Apply(Fault{Kind: KindReady}, SourceEndpoint, seed); !errors.Is(err, errInvalid) {
			t.Errorf("seed %q: got %v, want a refusal", seed, err)
		}
	}
	if n := len(records(t, out.String(), "fault")); n != 0 {
		t.Fatalf("faults without a valid seed wrote %d records", n)
	}
	if !b.ready.Load() {
		t.Fatal("a refused ready fault changed readiness")
	}
}

func TestDiskFault(t *testing.T) {
	t.Parallel()
	b, out, _ := newTestBox(t, Limits{DiskMB: 16})
	path := filepath.Join(b.diskDir, diskFileName)
	if err := b.Apply(Fault{Kind: KindDisk, MB: 3}, SourceStart, "s2"); err != nil {
		t.Fatal(err)
	}
	one(t, out.String(), KindDisk, "s2")
	st, err := os.Stat(path)
	if err != nil || st.Size() != 3<<20 {
		t.Fatalf("file %v size, err %v; want %d bytes", st, err, 3<<20)
	}
	if err := b.Apply(Fault{Kind: KindDisk, MB: 0}, SourceStart, "s2"); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(path); !os.IsNotExist(err) {
		t.Fatalf("disk 0 kept the file: %v", err)
	}
	if err := b.Apply(Fault{Kind: KindDisk, MB: 1}, SourceStart, "s2"); err != nil {
		t.Fatal(err)
	}
	if err := b.Apply(Fault{Kind: KindReset}, SourceStart, "s2"); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(path); !os.IsNotExist(err) {
		t.Fatalf("reset kept the file: %v", err)
	}
}

func TestDiskFaultFailureIsRecorded(t *testing.T) {
	t.Parallel()
	b, out, _ := newTestBox(t, Limits{DiskMB: 16})
	b.diskDir = filepath.Join(b.diskDir, "missing")
	if err := b.Apply(Fault{Kind: KindDisk, MB: 1}, SourceStart, "s2"); err == nil {
		t.Fatal("writing into a missing directory succeeded")
	}
	if n := len(records(t, out.String(), "fault_failed")); n != 1 {
		t.Fatalf("got %d fault_failed records, want 1:\n%s", n, out.String())
	}
}

func cpuTime(t *testing.T) time.Duration {
	t.Helper()
	var ru syscall.Rusage
	if err := syscall.Getrusage(syscall.RUSAGE_SELF, &ru); err != nil {
		t.Fatal(err)
	}
	return time.Duration(ru.Utime.Nano() + ru.Stime.Nano())
}

// Not parallel: it measures the process's CPU time, so it runs alone.
func TestCPUFault(t *testing.T) {
	b, out, _ := newTestBox(t, Limits{CPUMillicores: 1000})
	before := cpuTime(t)
	start := time.Now()
	if err := b.Apply(Fault{Kind: KindCPU, Millicores: 1000, Seconds: 1}, SourceEndpoint, "s3"); err != nil {
		t.Fatal(err)
	}
	one(t, out.String(), KindCPU, "s3")
	done := make(chan struct{})
	go func() { b.wg.Wait(); close(done) }()
	select {
	case <-done:
	case <-time.After(5 * time.Second):
		t.Fatal("the cpu fault did not stop after its seconds")
	}
	used, wall := cpuTime(t)-before, time.Since(start)
	if wall < 900*time.Millisecond {
		t.Fatalf("the cpu fault stopped after %v, want about 1s", wall)
	}
	if used < 300*time.Millisecond {
		t.Fatalf("the cpu fault used %v of CPU in %v, want most of a core", used, wall)
	}
}

func TestCPUFaultStopsOnReset(t *testing.T) {
	t.Parallel()
	b, _, _ := newTestBox(t, Limits{CPUMillicores: 200})
	if err := b.Apply(Fault{Kind: KindCPU, Millicores: 200, Seconds: 60}, SourceEndpoint, "s3"); err != nil {
		t.Fatal(err)
	}
	if err := b.Apply(Fault{Kind: KindReset}, SourceEndpoint, "s3"); err != nil {
		t.Fatal(err)
	}
	done := make(chan struct{})
	go func() { b.wg.Wait(); close(done) }()
	select {
	case <-done:
	case <-time.After(2 * time.Second):
		t.Fatal("reset did not stop the cpu fault")
	}
}

func TestCrashFault(t *testing.T) {
	t.Parallel()
	b, out, ex := newTestBox(t, Limits{})
	// The record must be in the log when the process exits.
	ex.atExit = func() {
		if len(records(t, out.String(), "fault")) != 1 {
			t.Error("exit before the crash record was written")
		}
	}
	if err := b.Apply(Fault{Kind: KindCrash, Code: 3}, SourceStart, "s4"); err != nil {
		t.Fatal(err)
	}
	if got := ex.got(); len(got) != 1 || got[0] != 3 {
		t.Fatalf("exit codes %v, want [3]", got)
	}
	one(t, out.String(), KindCrash, "s4")
}

func TestCrashFromEndpointWaits(t *testing.T) {
	t.Parallel()
	b, _, ex := newTestBox(t, Limits{})
	if err := b.Apply(Fault{Kind: KindCrash, Code: 7}, SourceEndpoint, "s4"); err != nil {
		t.Fatal(err)
	}
	if len(ex.got()) != 0 {
		t.Fatal("an endpoint crash exited before the caller got its answer")
	}
	deadline := time.Now().Add(2 * time.Second)
	for len(ex.got()) == 0 && time.Now().Before(deadline) {
		time.Sleep(10 * time.Millisecond)
	}
	if got := ex.got(); len(got) != 1 || got[0] != 7 {
		t.Fatalf("exit codes %v, want [7]", got)
	}
}

func TestResetCancelsPendingCrash(t *testing.T) {
	t.Parallel()
	b, _, ex := newTestBox(t, Limits{})
	if err := b.Apply(Fault{Kind: KindCrash, Code: 1, After: 200 * time.Millisecond}, SourceStart, "s4"); err != nil {
		t.Fatal(err)
	}
	if err := b.Apply(Fault{Kind: KindReset}, SourceStart, "s4"); err != nil {
		t.Fatal(err)
	}
	time.Sleep(400 * time.Millisecond)
	if got := ex.got(); len(got) != 0 {
		t.Fatalf("crash ran after reset: %v", got)
	}
}

func TestLogFault(t *testing.T) {
	t.Parallel()
	b, out, _ := newTestBox(t, Limits{})
	if err := b.Apply(Fault{Kind: KindLog, Pattern: "misleading", PerSecond: 100, Seconds: 1}, SourceEndpoint, "s5"); err != nil {
		t.Fatal(err)
	}
	b.wg.Wait() // the fault ends after its second
	one(t, out.String(), KindLog, "s5")
	allowed := map[string]bool{}
	for _, l := range logPatterns["misleading"] {
		allowed[l] = true
	}
	n := 0
	for _, line := range strings.Split(strings.TrimSpace(out.String()), "\n") {
		if strings.HasPrefix(line, "{") {
			continue // the fault record
		}
		if !allowed[line] {
			t.Fatalf("line %q is not of the misleading pattern", line)
		}
		n++
	}
	if n < 20 {
		t.Fatalf("got %d lines in one second at 100 per second", n)
	}
}

// No generated line may pass for a fault record: the scorer trusts only JSON lines with "event":"fault".
func TestPatternLinesAreNotRecords(t *testing.T) {
	t.Parallel()
	for name, lines := range logPatterns {
		if len(lines) == 0 {
			t.Errorf("pattern %s is empty", name)
		}
		for _, l := range lines {
			var m map[string]any
			if strings.HasPrefix(strings.TrimSpace(l), "{") || json.Unmarshal([]byte(l), &m) == nil || strings.Contains(l, "\n") {
				t.Errorf("pattern %s line %q could pass for a record", name, l)
			}
		}
	}
}

func TestErrorsAreDrawnFromTheSeed(t *testing.T) {
	t.Parallel()
	draw := func(seed string, rate float64) []bool {
		b, _, _ := newTestBox(t, Limits{})
		if err := b.Apply(Fault{Kind: KindErrors, Rate: rate}, SourceEndpoint, seed); err != nil {
			t.Fatal(err)
		}
		got := make([]bool, 1000)
		for i := range got {
			got[i] = b.injectError()
		}
		return got
	}
	count := func(v []bool) (n int) {
		for _, x := range v {
			if x {
				n++
			}
		}
		return n
	}
	a, b := draw("seed-a", 0.3), draw("seed-a", 0.3)
	for i := range a {
		if a[i] != b[i] {
			t.Fatalf("same seed, different draw at %d", i)
		}
	}
	if n := count(a); n < 230 || n > 370 {
		t.Fatalf("rate 0.3 gave %d of 1000", n)
	}
	if n := count(draw("seed-a", 1)); n != 1000 {
		t.Fatalf("rate 1 gave %d of 1000", n)
	}
	if n := count(draw("seed-a", 0)); n != 0 {
		t.Fatalf("rate 0 gave %d of 1000", n)
	}
}

// Of concurrent faults, the last record written is the one in force: the record and the change happen under one
// lock, so two calls cannot be recorded A, B and applied B, A.
func TestConcurrentFaultsLastRecordIsState(t *testing.T) {
	t.Parallel()
	b, out, _ := newTestBox(t, Limits{})
	const rounds, workers = 2000, 8
	for round := range rounds {
		var wg sync.WaitGroup
		for w := range workers {
			wg.Go(func() {
				if err := b.Apply(Fault{Kind: KindLatency, MS: round*workers + w + 1}, SourceEndpoint, "s1"); err != nil {
					t.Error(err)
				}
			})
		}
		wg.Wait()
		all := strings.TrimSpace(out.String()) // only fault records: latency writes no other line
		recs := records(t, all[strings.LastIndexByte(all, '\n')+1:], "fault")
		if len(recs) != 1 {
			t.Fatalf("round %d: last line is not a fault record:\n%s", round, all)
		}
		last := recs[0]["params"].(map[string]any)["ms"]
		if got := b.latency.Load(); float64(got) != last {
			t.Fatalf("round %d: latency in force %d, last record says %v", round, got, last)
		}
	}
}

// A call cannot cross the limit unless the box was started with --cross-limits; with it, it can.
func TestCrossNeedsCrossLimits(t *testing.T) {
	t.Parallel()
	l := Limits{MemoryMB: 64, DiskMB: 64, CPUMillicores: 100}
	for _, f := range []Fault{
		{Kind: KindMemory, MB: 60, Cross: true},
		{Kind: KindDisk, MB: 60, Cross: true},
		{Kind: KindCPU, Millicores: 150, Seconds: 1, Cross: true},
	} {
		b, out, _ := newTestBox(t, l)
		if err := b.Apply(f, SourceEndpoint, "s1"); !errors.Is(err, errOverCap) || !strings.Contains(err.Error(), "--cross-limits") {
			t.Errorf("%s: got %v, want a refusal naming --cross-limits", f.Kind, err)
		}
		if n := len(records(t, out.String(), "fault")); n != 0 {
			t.Errorf("%s: a refused cross wrote %d fault records", f.Kind, n)
		}
		if b.heldMB() != 0 {
			t.Errorf("%s: a refused cross allocated memory", f.Kind)
		}
		b.crossLimits = true
		if err := b.Apply(f, SourceEndpoint, "s1"); err != nil {
			t.Errorf("%s with --cross-limits: %v", f.Kind, err)
		}
	}
}
