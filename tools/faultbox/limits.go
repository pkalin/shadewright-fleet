package main

import (
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strconv"
	"strings"
)

// Hard ceilings: no fault goes above these, whatever the limits or the scenario say. They bound the damage of a
// wrong limit flag or a scenario typo.
const (
	hardMemoryMB      = 4096
	hardDiskMB        = 4096
	hardCPUMillicores = 4000
	hardSeconds       = 3600
	hardLatencyMS     = 60000
	hardLogPerSecond  = 100
)

// Caps used when the pod's limit is not known: small, and crossing is refused (there is no limit to cross, so a
// larger size would press the node instead of the pod).
const (
	defaultMemoryCapMB      = 64
	defaultDiskCapMB        = 64
	defaultCPUCapMillicores = 500
)

// errOverCap is wrapped by every refusal of a size above a cap.
var errOverCap = errors.New("over cap")

// Limits are the pod's own limits. Zero means not known.
type Limits struct {
	MemoryMB      int
	DiskMB        int
	CPUMillicores int
}

// safeCap is the size a fault may reach without asking to cross the limit: three quarters of the limit (the rest
// is headroom for the runtime and the logs), or a small default when the limit is not known.
func safeCap(limit, def int) int {
	if limit <= 0 {
		return def
	}
	return limit * 3 / 4
}

// crossCap is the size a fault may reach when the scenario asks to cross the limit: twice the limit (enough to
// cross it, while a wrong limit still bounds the damage), never above the hard ceiling.
func crossCap(limit, hard int) int {
	return min(2*limit, hard)
}

// checkSize refuses a size above the cap that applies. what names the resource in the error.
func checkSize(what string, size, limit, def, hard int, cross bool) error {
	if size < 0 {
		return fmt.Errorf("%s must not be negative", what)
	}
	if cross {
		if limit <= 0 {
			return fmt.Errorf("%w: crossing the %s limit needs a known limit", errOverCap, what)
		}
		if c := crossCap(limit, hard); size > c {
			return fmt.Errorf("%w: %s %d is above the crossing cap %d (limit %d)", errOverCap, what, size, c, limit)
		}
		return nil
	}
	if c := min(safeCap(limit, def), hard); size > c {
		return fmt.Errorf("%w: %s %d is above the cap %d (limit %d); set cross to go over the limit", errOverCap, what, size, c, limit)
	}
	return nil
}

// cgroupMemoryLimitMB reads the container's memory limit from the cgroup filesystem under root (cgroup v2, then
// v1). It returns 0 when there is no limit or it cannot be read: the caller then uses the flag or the default.
func cgroupMemoryLimitMB(root string) int {
	for _, p := range []string{"memory.max", filepath.Join("memory", "memory.limit_in_bytes")} {
		b, err := os.ReadFile(filepath.Join(root, p))
		if err != nil {
			continue
		}
		s := strings.TrimSpace(string(b))
		if s == "max" {
			return 0
		}
		n, err := strconv.ParseInt(s, 10, 64)
		if err != nil || n <= 0 || n >= 1<<50 { // v1 reports "no limit" as a huge number
			return 0
		}
		return int(n >> 20)
	}
	return 0
}

// minKnown is the smaller of two limits, ignoring an unknown (zero) one.
func minKnown(a, b int) int {
	switch {
	case a <= 0:
		return b
	case b <= 0:
		return a
	default:
		return min(a, b)
	}
}
