package main

import (
	"errors"
	"math"
	"os"
	"path/filepath"
	"testing"
	"time"
)

func TestCaps(t *testing.T) {
	t.Parallel()
	cases := []struct {
		name   string
		f      Fault
		l      Limits
		overOK bool // true: accepted; false: refused as over a cap
	}{
		{"memory under the safe cap", Fault{Kind: KindMemory, MB: 96}, Limits{MemoryMB: 128}, true},
		{"memory above the safe cap", Fault{Kind: KindMemory, MB: 97}, Limits{MemoryMB: 128}, false},
		{"memory at the limit without cross", Fault{Kind: KindMemory, MB: 128}, Limits{MemoryMB: 128}, false},
		{"memory over the limit with cross", Fault{Kind: KindMemory, MB: 200, Cross: true}, Limits{MemoryMB: 128}, true},
		{"memory at twice the limit with cross", Fault{Kind: KindMemory, MB: 256, Cross: true}, Limits{MemoryMB: 128}, true},
		{"memory above twice the limit with cross", Fault{Kind: KindMemory, MB: 257, Cross: true}, Limits{MemoryMB: 128}, false},
		{"memory cross with no known limit", Fault{Kind: KindMemory, MB: 10, Cross: true}, Limits{}, false},
		{"memory default cap, no limit", Fault{Kind: KindMemory, MB: 64}, Limits{}, true},
		{"memory above the default cap, no limit", Fault{Kind: KindMemory, MB: 65}, Limits{}, false},
		{"memory cross above the hard ceiling", Fault{Kind: KindMemory, MB: 4097, Cross: true}, Limits{MemoryMB: 4000}, false},
		{"memory safe cap above the hard ceiling", Fault{Kind: KindMemory, MB: 4097}, Limits{MemoryMB: 8000}, false},
		{"disk under the safe cap", Fault{Kind: KindDisk, MB: 75}, Limits{DiskMB: 100}, true},
		{"disk above the safe cap", Fault{Kind: KindDisk, MB: 76}, Limits{DiskMB: 100}, false},
		{"disk over the limit with cross", Fault{Kind: KindDisk, MB: 150, Cross: true}, Limits{DiskMB: 100}, true},
		{"disk above twice the limit", Fault{Kind: KindDisk, MB: 201, Cross: true}, Limits{DiskMB: 100}, false},
		{"disk cross with no known limit", Fault{Kind: KindDisk, MB: 1, Cross: true}, Limits{}, false},
		{"disk default cap, no limit", Fault{Kind: KindDisk, MB: 65}, Limits{}, false},
		{"cpu at the limit", Fault{Kind: KindCPU, Millicores: 200, Seconds: 1}, Limits{CPUMillicores: 200}, true},
		{"cpu above the limit", Fault{Kind: KindCPU, Millicores: 201, Seconds: 1}, Limits{CPUMillicores: 200}, false},
		{"cpu above the limit with cross", Fault{Kind: KindCPU, Millicores: 400, Seconds: 1, Cross: true}, Limits{CPUMillicores: 200}, true},
		{"cpu above twice the limit", Fault{Kind: KindCPU, Millicores: 401, Seconds: 1, Cross: true}, Limits{CPUMillicores: 200}, false},
		{"cpu default cap, no limit", Fault{Kind: KindCPU, Millicores: 501, Seconds: 1}, Limits{}, false},
		{"cpu cross with no known limit", Fault{Kind: KindCPU, Millicores: 100, Seconds: 1, Cross: true}, Limits{}, false},
		{"cpu above the hard ceiling", Fault{Kind: KindCPU, Millicores: 4001, Seconds: 1, Cross: true}, Limits{CPUMillicores: 3000}, false},
	}
	for _, c := range cases {
		err := c.f.Validate(c.l)
		if c.overOK && err != nil {
			t.Errorf("%s: refused: %v", c.name, err)
		}
		if !c.overOK && !errors.Is(err, errOverCap) {
			t.Errorf("%s: got %v, want a refusal over a cap", c.name, err)
		}
	}
}

func TestValidateRanges(t *testing.T) {
	t.Parallel()
	bad := []Fault{
		{Kind: KindMemory, MB: -1},
		{Kind: KindCPU, Millicores: 0, Seconds: 1},
		{Kind: KindCPU, Millicores: 100, Seconds: 0},
		{Kind: KindCPU, Millicores: 100, Seconds: hardSeconds + 1},
		{Kind: KindCrash, Code: 0},
		{Kind: KindCrash, Code: 256},
		{Kind: KindCrash, Code: 1, After: -time.Second},
		{Kind: KindErrors, Rate: 1.01},
		{Kind: KindErrors, Rate: -0.1},
		{Kind: KindErrors, Rate: math.NaN()},
		{Kind: KindLatency, MS: -1},
		{Kind: KindLatency, MS: hardLatencyMS + 1},
		{Kind: KindLog, Pattern: "other", PerSecond: 1, Seconds: 1},
		{Kind: KindLog, Pattern: "noise", PerSecond: 0, Seconds: 1},
		{Kind: KindLog, Pattern: "noise", PerSecond: hardLogPerSecond + 1, Seconds: 1},
		{Kind: KindLog, Pattern: "noise", PerSecond: 1, Seconds: 0},
		{Kind: KindLatency, MS: 1, Cross: true},
		{Kind: "unknown"},
	}
	for _, f := range bad {
		if err := f.Validate(Limits{MemoryMB: 128, DiskMB: 128, CPUMillicores: 500}); err == nil {
			t.Errorf("%+v: accepted, want a refusal", f)
		}
	}
	good := []Fault{
		{Kind: KindCrash, Code: 255, After: time.Minute},
		{Kind: KindErrors, Rate: 0},
		{Kind: KindErrors, Rate: 1},
		{Kind: KindLatency, MS: hardLatencyMS},
		{Kind: KindLog, Pattern: "injection", PerSecond: hardLogPerSecond, Seconds: hardSeconds},
		{Kind: KindReady},
		{Kind: KindReset},
	}
	for _, f := range good {
		if err := f.Validate(Limits{}); err != nil {
			t.Errorf("%+v: refused: %v", f, err)
		}
	}
}

func TestCgroupMemoryLimit(t *testing.T) {
	t.Parallel()
	write := func(t *testing.T, root, name, content string) {
		t.Helper()
		p := filepath.Join(root, name)
		if err := os.MkdirAll(filepath.Dir(p), 0o700); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(p, []byte(content), 0o600); err != nil {
			t.Fatal(err)
		}
	}
	cases := []struct {
		name, file, content string
		want                int
	}{
		{"v2 limit", "memory.max", "134217728\n", 128},
		{"v2 no limit", "memory.max", "max\n", 0},
		{"v1 limit", "memory/memory.limit_in_bytes", "268435456\n", 256},
		{"v1 no limit", "memory/memory.limit_in_bytes", "9223372036854771712\n", 0},
		{"garbage", "memory.max", "lots\n", 0},
	}
	for _, c := range cases {
		root := t.TempDir()
		write(t, root, c.file, c.content)
		if got := cgroupMemoryLimitMB(root); got != c.want {
			t.Errorf("%s: got %d, want %d", c.name, got, c.want)
		}
	}
	if got := cgroupMemoryLimitMB(t.TempDir()); got != 0 {
		t.Errorf("no cgroup files: got %d, want 0", got)
	}
	if minKnown(0, 5) != 5 || minKnown(5, 0) != 5 || minKnown(3, 5) != 3 {
		t.Error("minKnown")
	}
}
