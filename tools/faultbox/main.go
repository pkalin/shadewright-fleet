// Command faultbox is a workload that fails on request in exact, known ways: it holds memory, burns CPU, fills its
// emptyDir, crashes, stops being ready, answers with errors or latency, and writes noisy, misleading or injected log
// lines. Faults are set at start from flags or a config file (a mounted ConfigMap), or at run time through
// token-protected endpoints. Every applied fault is first written as one JSON log line with the scenario seed: the
// ground truth a scenario is scored against.
package main

import (
	"bufio"
	"bytes"
	"context"
	"errors"
	"flag"
	"fmt"
	"io"
	"log/slog"
	"net/http"
	"os"
	"os/signal"
	"strings"
	"syscall"
	"time"
)

// maxConfigBytes bounds the config file.
const maxConfigBytes = 64 << 10

// configKeys are the flags a config file may set: the faults and the scenario, never where the token, the disk or
// the limits come from (those belong to the pod spec).
var configKeys = map[string]bool{
	"seed": true, "scenario": true, "cross-limits": true,
	"memory-mb": true, "disk-mb": true, "cpu-millicores": true, "cpu-seconds": true,
	"crash-code": true, "crash-after": true, "ready": true, "error-rate": true, "latency-ms": true,
	"log-pattern": true, "log-per-second": true, "log-seconds": true,
}

// options are the parsed flags.
type options struct {
	listen, tokenFile, diskDir, config string
	limits                             Limits
	seed, scenario                     string
	crossLimits                        bool
	faults                             []Fault
}

// parseOptions reads the flags, then the config file for any key not given on the command line, and builds the
// start faults in a fixed order (crash last).
func parseOptions(args []string, stderr io.Writer) (options, error) {
	var o options
	fs := flag.NewFlagSet("faultbox", flag.ContinueOnError)
	fs.SetOutput(stderr)
	fs.StringVar(&o.listen, "listen", ":8080", "address to serve on")
	fs.StringVar(&o.tokenFile, "token-file", "", "file holding the bearer token of the control endpoints, read at each call (none: every control call is refused)")
	fs.StringVar(&o.diskDir, "disk-dir", "/scratch", "directory the disk fault writes into (an emptyDir)")
	fs.StringVar(&o.config, "config", "", "file of key=value lines setting the fault flags (a mounted ConfigMap); command-line flags win")
	fs.IntVar(&o.limits.MemoryMB, "limit-memory-mb", 0, "the container's memory limit in MiB (Downward API); the cgroup limit is used when lower or when unset")
	fs.IntVar(&o.limits.DiskMB, "limit-disk-mb", 0, "the container's ephemeral-storage limit in MiB (Downward API)")
	fs.IntVar(&o.limits.CPUMillicores, "limit-cpu-millicores", 0, "the container's CPU limit in millicores (Downward API)")
	fs.StringVar(&o.seed, "seed", "", "scenario seed written with every fault record; required when a fault is set at start")
	fs.StringVar(&o.scenario, "scenario", "", "scenario name written with every fault record")
	cross := &o.crossLimits
	fs.BoolVar(cross, "cross-limits", false, "let the memory, disk and cpu faults go over the pod's limit (up to twice it), at start and at the endpoints")
	memoryMB := fs.Int("memory-mb", 0, "memory to allocate and hold, MiB")
	diskMB := fs.Int("disk-mb", 0, "file size to write into --disk-dir, MiB")
	cpuM := fs.Int("cpu-millicores", 0, "CPU to burn, millicores")
	cpuS := fs.Int("cpu-seconds", 300, "how long the cpu fault runs")
	crashCode := fs.Int("crash-code", 0, "exit with this code (1 to 255)")
	crashAfter := fs.Duration("crash-after", 0, "delay before the crash")
	ready := fs.Bool("ready", true, "the readiness answer")
	errRate := fs.Float64("error-rate", 0, "share of requests to / answered with HTTP 500 (0 to 1)")
	latency := fs.Int("latency-ms", 0, "latency added to requests to /")
	logPattern := fs.String("log-pattern", "", "log lines to write: noise, misleading or injection")
	logRate := fs.Int("log-per-second", 1, "log lines per second")
	logS := fs.Int("log-seconds", 60, "how long the log fault runs")
	if err := fs.Parse(args); err != nil {
		return o, err
	}
	if fs.NArg() > 0 {
		return o, fmt.Errorf("unexpected arguments: %v", fs.Args())
	}
	set := map[string]bool{}
	fs.Visit(func(f *flag.Flag) { set[f.Name] = true })
	if o.config != "" {
		if err := applyConfig(fs, o.config, set); err != nil {
			return o, err
		}
	}

	for _, l := range []struct {
		name string
		v    int
	}{{"limit-memory-mb", o.limits.MemoryMB}, {"limit-disk-mb", o.limits.DiskMB}, {"limit-cpu-millicores", o.limits.CPUMillicores}} {
		if l.v < 0 || l.v > maxLimit {
			return o, fmt.Errorf("%s %d is outside 0 to %d", l.name, l.v, maxLimit)
		}
	}

	needs := map[string]string{"cpu-seconds": "cpu-millicores", "crash-after": "crash-code", "log-per-second": "log-pattern", "log-seconds": "log-pattern"}
	for sub, parent := range needs {
		if set[sub] && !set[parent] {
			return o, fmt.Errorf("%s needs %s", sub, parent)
		}
	}
	if set["memory-mb"] {
		o.faults = append(o.faults, Fault{Kind: KindMemory, MB: *memoryMB, Cross: *cross})
	}
	if set["disk-mb"] {
		o.faults = append(o.faults, Fault{Kind: KindDisk, MB: *diskMB, Cross: *cross})
	}
	if set["cpu-millicores"] {
		o.faults = append(o.faults, Fault{Kind: KindCPU, Millicores: *cpuM, Seconds: *cpuS, Cross: *cross})
	}
	if set["ready"] && !*ready {
		o.faults = append(o.faults, Fault{Kind: KindReady, Ready: false})
	}
	if set["error-rate"] {
		o.faults = append(o.faults, Fault{Kind: KindErrors, Rate: *errRate})
	}
	if set["latency-ms"] {
		o.faults = append(o.faults, Fault{Kind: KindLatency, MS: *latency})
	}
	if set["log-pattern"] {
		o.faults = append(o.faults, Fault{Kind: KindLog, Pattern: *logPattern, PerSecond: *logRate, Seconds: *logS})
	}
	if set["crash-code"] {
		o.faults = append(o.faults, Fault{Kind: KindCrash, Code: *crashCode, After: *crashAfter})
	}
	if o.seed != "" && !validSeed(o.seed) {
		return o, errors.New("seed must be 1 to 64 of A-Z a-z 0-9 . _ : -")
	}
	if len(o.faults) > 0 && o.seed == "" {
		return o, errors.New("a fault set at start needs --seed")
	}
	return o, nil
}

// applyConfig sets each key=value line of the file as its flag, unless the command line set it. Blank lines and
// lines starting with # are skipped; an unknown or repeated key is an error.
func applyConfig(fs *flag.FlagSet, path string, set map[string]bool) error {
	f, err := os.Open(path)
	if err != nil {
		return fmt.Errorf("config file: %w", err)
	}
	defer func() { _ = f.Close() }()
	b, err := io.ReadAll(io.LimitReader(f, maxConfigBytes+1))
	if err != nil {
		return fmt.Errorf("config file: %w", err)
	}
	if len(b) > maxConfigBytes {
		return fmt.Errorf("config file larger than %d bytes", maxConfigBytes)
	}
	seen := map[string]bool{}
	sc := bufio.NewScanner(bytes.NewReader(b))
	for n := 1; sc.Scan(); n++ {
		line := strings.TrimSpace(sc.Text())
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		k, v, ok := strings.Cut(line, "=")
		k, v = strings.TrimSpace(k), strings.TrimSpace(v)
		if !ok || !configKeys[k] {
			return fmt.Errorf("config line %d: unknown key %q", n, k)
		}
		if seen[k] {
			return fmt.Errorf("config line %d: %s set twice", n, k)
		}
		seen[k] = true
		if set[k] {
			continue // the command line wins
		}
		if err := fs.Set(k, v); err != nil {
			return fmt.Errorf("config line %d: %s: %w", n, k, err)
		}
		set[k] = true
	}
	return sc.Err()
}

// run is main without the process: it returns the exit code.
func run(ctx context.Context, args []string, stdout, stderr io.Writer, cgroupRoot string, exit func(int)) int {
	o, err := parseOptions(args, stderr)
	logger := slog.New(slog.NewJSONHandler(stdout, nil))
	if err != nil {
		if errors.Is(err, flag.ErrHelp) {
			return 0
		}
		logger.Error("start refused", "event", "start_refused", "reason", err.Error())
		return 2
	}
	o.limits.MemoryMB = minKnown(o.limits.MemoryMB, cgroupMemoryLimitMB(cgroupRoot))
	// Every start fault is checked before the first one is applied: a refused scenario applies nothing.
	for _, f := range o.faults {
		if err := f.Validate(o.limits); err != nil {
			logger.Error("start refused", "event", "start_refused", "fault", string(f.Kind), "seed", o.seed, "reason", err.Error())
			return 2
		}
	}
	box := NewBox(stdout, o.limits, o.diskDir, o.scenario, o.crossLimits, exit)
	defer box.Close()
	for _, f := range o.faults {
		if err := box.Apply(f, SourceStart, o.seed); err != nil {
			return 1
		}
	}

	srv := &http.Server{
		Addr:              o.listen,
		Handler:           NewServer(box, o.tokenFile, o.seed),
		ReadHeaderTimeout: 5 * time.Second,
		ReadTimeout:       10 * time.Second,
		WriteTimeout:      (hardLatencyMS + 10000) * time.Millisecond,
		IdleTimeout:       60 * time.Second,
		MaxHeaderBytes:    8 << 10,
	}
	errc := make(chan error, 1)
	go func() { errc <- srv.ListenAndServe() }()
	box.log.Info("serving", "event", "serving", "listen", o.listen, "seed", o.seed, "scenario", o.scenario,
		"limit_memory_mb", o.limits.MemoryMB, "limit_disk_mb", o.limits.DiskMB, "limit_cpu_millicores", o.limits.CPUMillicores)
	select {
	case err := <-errc:
		box.log.Error("server stopped", "event", "server_stopped", "error", err.Error())
		return 1
	case <-ctx.Done():
	}
	sctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	_ = srv.Shutdown(sctx)
	return 0
}

func main() {
	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGTERM, os.Interrupt)
	code := run(ctx, os.Args[1:], os.Stdout, os.Stderr, "/sys/fs/cgroup", os.Exit)
	stop()
	os.Exit(code)
}
