package main

import (
	"errors"
	"fmt"
	"log/slog"
	"regexp"
	"time"
)

// Kind names a fault. The values are the "fault" field of the log line.
type Kind string

const (
	KindMemory  Kind = "memory"
	KindCPU     Kind = "cpu"
	KindDisk    Kind = "disk"
	KindCrash   Kind = "crash"
	KindReady   Kind = "ready"
	KindErrors  Kind = "errors"
	KindLatency Kind = "latency"
	KindLog     Kind = "log"
	KindReset   Kind = "reset"
)

// Source says where a fault came from: the log line records it.
type Source string

const (
	SourceStart    Source = "start" // flags or the config file
	SourceEndpoint Source = "endpoint"
)

// Fault is one fault with its parameters. Only the fields of its Kind are used.
type Fault struct {
	Kind       Kind
	MB         int           // memory, disk: the size to hold (0 releases)
	Millicores int           // cpu
	Seconds    int           // cpu, log: how long it runs
	Code       int           // crash: the exit code
	After      time.Duration // crash: delay before the exit
	Ready      bool          // ready: the readiness answer
	Rate       float64       // errors: share of requests answered with HTTP 500
	MS         int           // latency: added to each request
	Pattern    string        // log: one of logPatterns
	PerSecond  int           // log: lines per second
	Cross      bool          // the scenario asks to go over the pod's limit
}

// errInvalid is wrapped by every refusal of a parameter outside its range (other than a cap).
var errInvalid = errors.New("invalid fault")

var seedPattern = regexp.MustCompile(`^[A-Za-z0-9._:-]{1,64}$`)

// validSeed reports whether s may be a scenario seed: short, and safe in a log line and a query.
func validSeed(s string) bool { return seedPattern.MatchString(s) }

// Validate refuses a fault outside its range or above the cap that applies under the given limits.
func (f Fault) Validate(l Limits) error {
	bad := func(format string, a ...any) error {
		return fmt.Errorf("%w: %s", errInvalid, fmt.Sprintf(format, a...))
	}
	if f.Cross && f.Kind != KindMemory && f.Kind != KindDisk && f.Kind != KindCPU {
		return bad("cross applies to memory, disk and cpu only")
	}
	switch f.Kind {
	case KindMemory:
		return checkSize("memory MB", f.MB, l.MemoryMB, defaultMemoryCapMB, hardMemoryMB, f.Cross)
	case KindDisk:
		return checkSize("disk MB", f.MB, l.DiskMB, defaultDiskCapMB, hardDiskMB, f.Cross)
	case KindCPU:
		if f.Millicores < 1 {
			return bad("cpu millicores must be at least 1")
		}
		if f.Seconds < 1 || f.Seconds > hardSeconds {
			return bad("cpu seconds must be 1 to %d", hardSeconds)
		}
		if f.Cross {
			if l.CPUMillicores <= 0 {
				return fmt.Errorf("%w: crossing the cpu limit needs a known limit", errOverCap)
			}
			if c := crossCap(l.CPUMillicores, hardCPUMillicores); f.Millicores > c {
				return fmt.Errorf("%w: cpu millicores %d is above the crossing cap %d", errOverCap, f.Millicores, c)
			}
			return nil
		}
		c := defaultCPUCapMillicores
		if l.CPUMillicores > 0 {
			c = l.CPUMillicores // over the cpu limit only throttles the pod, so the limit itself is the cap
		}
		if c = min(c, hardCPUMillicores); f.Millicores > c {
			return fmt.Errorf("%w: cpu millicores %d is above the cap %d; set cross to go over the limit", errOverCap, f.Millicores, c)
		}
	case KindCrash:
		if f.Code < 1 || f.Code > 255 {
			return bad("crash code must be 1 to 255")
		}
		if f.After < 0 || f.After > hardSeconds*time.Second {
			return bad("crash delay must be 0 to %ds", hardSeconds)
		}
	case KindReady, KindReset:
	case KindErrors:
		if !(f.Rate >= 0 && f.Rate <= 1) { // also refuses NaN
			return bad("error rate must be 0 to 1")
		}
	case KindLatency:
		if f.MS < 0 || f.MS > hardLatencyMS {
			return bad("latency must be 0 to %d ms", hardLatencyMS)
		}
	case KindLog:
		if _, ok := logPatterns[f.Pattern]; !ok {
			return bad("unknown log pattern %q", f.Pattern)
		}
		if f.PerSecond < 1 || f.PerSecond > hardLogPerSecond {
			return bad("log lines per second must be 1 to %d", hardLogPerSecond)
		}
		if f.Seconds < 1 || f.Seconds > hardSeconds {
			return bad("log seconds must be 1 to %d", hardSeconds)
		}
	default:
		return bad("unknown fault %q", f.Kind)
	}
	return nil
}

// params are the fault's parameters for its log line.
func (f Fault) params() []any {
	switch f.Kind {
	case KindMemory, KindDisk:
		return []any{slog.Int("mb", f.MB), slog.Bool("cross", f.Cross)}
	case KindCPU:
		return []any{slog.Int("millicores", f.Millicores), slog.Int("seconds", f.Seconds), slog.Bool("cross", f.Cross)}
	case KindCrash:
		return []any{slog.Int("code", f.Code), slog.Int64("after_ms", f.After.Milliseconds())}
	case KindReady:
		return []any{slog.Bool("state", f.Ready)}
	case KindErrors:
		return []any{slog.Float64("rate", f.Rate)}
	case KindLatency:
		return []any{slog.Int("ms", f.MS)}
	case KindLog:
		return []any{slog.String("pattern", f.Pattern), slog.Int("per_second", f.PerSecond), slog.Int("seconds", f.Seconds)}
	default:
		return nil
	}
}
