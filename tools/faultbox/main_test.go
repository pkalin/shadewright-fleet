package main

import (
	"context"
	"encoding/json"
	"io"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func writeFile(t *testing.T, content string) string {
	t.Helper()
	p := filepath.Join(t.TempDir(), "faults.conf")
	if err := os.WriteFile(p, []byte(content), 0o600); err != nil {
		t.Fatal(err)
	}
	return p
}

func TestParseOptionsFromConfigFile(t *testing.T) {
	t.Parallel()
	conf := writeFile(t, "# scenario oom-start\nseed = 42\nscenario=oom-start\nmemory-mb=200\ncross-limits=true\nlatency-ms=50\n\n")
	o, err := parseOptions([]string{"--config", conf, "--latency-ms", "70"}, io.Discard)
	if err != nil {
		t.Fatal(err)
	}
	if o.seed != "42" || o.scenario != "oom-start" {
		t.Fatalf("seed %q scenario %q", o.seed, o.scenario)
	}
	want := []Fault{{Kind: KindMemory, MB: 200, Cross: true}, {Kind: KindLatency, MS: 70}}
	if len(o.faults) != len(want) {
		t.Fatalf("faults %+v, want %+v", o.faults, want)
	}
	for i := range want {
		if o.faults[i] != want[i] {
			t.Fatalf("fault %d: %+v, want %+v (the command line wins)", i, o.faults[i], want[i])
		}
	}
}

func TestParseOptionsRefusals(t *testing.T) {
	t.Parallel()
	cases := []struct {
		name string
		args []string
		conf string
	}{
		{"fault without a seed", []string{"--memory-mb", "10"}, ""},
		{"invalid seed", []string{"--seed", "a b"}, ""},
		{"sub-flag without its fault", []string{"--seed", "1", "--cpu-seconds", "5"}, ""},
		{"cross without a sized fault", []string{"--seed", "1", "--cross-limits", "--latency-ms", "5"}, ""},
		{"stray argument", []string{"extra"}, ""},
		{"unknown config key", nil, "seed=1\nmemory=10\n"},
		{"config sets the token file", nil, "token-file=/tmp/x\n"},
		{"config sets a limit", nil, "limit-memory-mb=999999\n"},
		{"repeated config key", nil, "seed=1\nseed=2\n"},
		{"line without =", nil, "seed\n"},
		{"bad value", nil, "seed=1\nmemory-mb=many\n"},
	}
	for _, c := range cases {
		args := c.args
		if c.conf != "" {
			args = append(args, "--config", writeFile(t, c.conf))
		}
		if _, err := parseOptions(args, io.Discard); err == nil {
			t.Errorf("%s: accepted", c.name)
		}
	}
	if _, err := parseOptions([]string{"--config", filepath.Join(t.TempDir(), "absent")}, io.Discard); err == nil {
		t.Error("missing config file: accepted")
	}
}

// A start fault above its cap refuses the whole start: nothing is applied and nothing is served.
func TestRunRefusesOverCapAtStart(t *testing.T) {
	t.Parallel()
	out := &lockedBuffer{}
	ex := &exitRecorder{}
	cg := t.TempDir()
	if err := os.WriteFile(filepath.Join(cg, "memory.max"), []byte("67108864\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	code := run(context.Background(), []string{"--seed", "9", "--memory-mb", "4", "--cpu-millicores", "5000", "--cpu-seconds", "1"}, out, io.Discard, cg, ex.exit)
	if code != 2 {
		t.Fatalf("exit %d, want 2", code)
	}
	if n := len(records(t, out.String(), "fault")); n != 0 {
		t.Fatalf("%d faults applied from a refused start", n)
	}
	if n := len(records(t, out.String(), "start_refused")); n != 1 {
		t.Fatalf("got %d start_refused records", n)
	}
}

// The start faults are recorded, with the seed, before anything else is written, and the crash comes last.
func TestRunAppliesStartFaultsFirst(t *testing.T) {
	t.Parallel()
	out := &lockedBuffer{}
	ex := &exitRecorder{}
	cg := t.TempDir()
	if err := os.WriteFile(filepath.Join(cg, "memory.max"), []byte("134217728\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	conf := writeFile(t, "seed=1234\nscenario=start\nmemory-mb=4\ncrash-code=3\nready=false\n")
	ctx, cancel := context.WithCancel(context.Background())
	cancel() // serve, then stop at once
	code := run(ctx, []string{"--config", conf, "--listen", "127.0.0.1:0", "--disk-dir", t.TempDir()}, out, io.Discard, cg, ex.exit)
	if code != 0 {
		t.Fatalf("exit %d, want 0:\n%s", code, out.String())
	}
	lines := strings.Split(strings.TrimSpace(out.String()), "\n")
	var first map[string]any
	if err := json.Unmarshal([]byte(lines[0]), &first); err != nil || first["event"] != "fault" || first["fault"] != "memory" || first["seed"] != "1234" {
		t.Fatalf("first line %q, want the memory fault record with the seed", lines[0])
	}
	var kinds []string
	for _, r := range records(t, out.String(), "fault") {
		kinds = append(kinds, r["fault"].(string))
		if r["source"] != "start" {
			t.Fatalf("record %v, want source start", r)
		}
	}
	if strings.Join(kinds, ",") != "memory,ready,crash" {
		t.Fatalf("fault order %v", kinds)
	}
	if got := ex.got(); len(got) != 1 || got[0] != 3 {
		t.Fatalf("exit codes %v, want [3]", got)
	}
}
