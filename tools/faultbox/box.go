package main

import (
	"context"
	"errors"
	"fmt"
	"hash/fnv"
	"io"
	"io/fs"
	"log/slog"
	"math/rand/v2"
	"os"
	"path/filepath"
	"runtime/debug"
	"sync"
	"sync/atomic"
	"time"
)

// diskFileName is the one file the disk fault writes, in the emptyDir given by --disk-dir.
const diskFileName = "faultbox.fill"

// syncWriter serialises writes, so a fault record and a generated log line never interleave.
type syncWriter struct {
	mu sync.Mutex
	w  io.Writer
}

func (s *syncWriter) Write(p []byte) (int, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.w.Write(p)
}

// Box holds the faults in force and applies new ones. Every applied fault is first written as one JSON log line
// with the seed (the ground truth), then carried out, so a fault that kills the process is on record before it does.
type Box struct {
	log      *slog.Logger
	out      io.Writer // generated log lines (the same writer as log)
	limits   Limits
	diskDir  string
	exit     func(int)
	scenario string

	mu         sync.Mutex
	mem        [][]byte
	cpuStop    context.CancelFunc
	logStop    context.CancelFunc
	crashTimer *time.Timer
	wg         sync.WaitGroup

	ready   atomic.Bool
	latency atomic.Int64 // milliseconds

	errMu   sync.Mutex
	errRate float64
	errRNG  *rand.Rand
}

// NewBox returns a Box with no fault in force. out receives the JSON records and the generated log lines.
func NewBox(out io.Writer, limits Limits, diskDir, scenario string, exit func(int)) *Box {
	w := &syncWriter{w: out}
	b := &Box{
		log:      slog.New(slog.NewJSONHandler(w, nil)),
		out:      w,
		limits:   limits,
		diskDir:  diskDir,
		exit:     exit,
		scenario: scenario,
	}
	b.ready.Store(true)
	return b
}

// rngFor gives the fault's own random sequence from the seed, so the same seed gives the same errors and lines.
func rngFor(seed string, k Kind) *rand.Rand {
	h1, h2 := fnv.New64a(), fnv.New64a()
	_, _ = h1.Write([]byte(seed))
	_, _ = h2.Write([]byte(k))
	return rand.New(rand.NewPCG(h1.Sum64(), h2.Sum64()))
}

// Apply validates the fault, writes its record and carries it out. A refusal is logged and returned without any
// change; an error after the record is logged as fault_failed and returned.
func (b *Box) Apply(f Fault, src Source, seed string) error {
	if !validSeed(seed) {
		err := fmt.Errorf("%w: a valid seed is required (1 to 64 of A-Z a-z 0-9 . _ : -)", errInvalid)
		b.log.Warn("fault refused", "event", "fault_refused", "fault", string(f.Kind), "source", string(src), "reason", err.Error())
		return err
	}
	if err := f.Validate(b.limits); err != nil {
		b.log.Warn("fault refused", "event", "fault_refused", "fault", string(f.Kind), "source", string(src),
			"seed", seed, "reason", err.Error())
		return err
	}
	if f.Kind == KindCrash && src == SourceEndpoint {
		f.After = max(f.After, endpointCrashDelay) // the caller gets its answer first; the record shows the real delay
	}
	b.log.Info("fault applied", "event", "fault", "fault", string(f.Kind), "source", string(src), "seed", seed,
		"scenario", b.scenario, slog.Group("params", f.params()...))
	if err := b.carryOut(f, src, seed); err != nil {
		b.log.Error("fault failed", "event", "fault_failed", "fault", string(f.Kind), "source", string(src),
			"seed", seed, "error", err.Error())
		return err
	}
	return nil
}

func (b *Box) carryOut(f Fault, src Source, seed string) error {
	b.mu.Lock()
	defer b.mu.Unlock()
	switch f.Kind {
	case KindMemory:
		b.setMemory(f.MB)
	case KindDisk:
		return b.setDisk(f.MB)
	case KindCPU:
		b.startCPU(f.Millicores, time.Duration(f.Seconds)*time.Second)
	case KindCrash:
		b.scheduleCrash(f.Code, f.After)
	case KindReady:
		b.ready.Store(f.Ready)
	case KindErrors:
		b.errMu.Lock()
		b.errRate, b.errRNG = f.Rate, rngFor(seed, KindErrors)
		b.errMu.Unlock()
	case KindLatency:
		b.latency.Store(int64(f.MS))
	case KindLog:
		b.startLog(f.Pattern, f.PerSecond, time.Duration(f.Seconds)*time.Second, rngFor(seed, KindLog))
	case KindReset:
		return b.reset()
	}
	return nil
}

// setMemory holds mb MiB, touching every page so the memory is resident and counts against the cgroup limit.
func (b *Box) setMemory(mb int) {
	b.mem = nil
	debug.FreeOSMemory()
	held := make([][]byte, 0, mb)
	for range mb {
		c := make([]byte, 1<<20)
		for i := 0; i < len(c); i += 4096 {
			c[i] = 1
		}
		held = append(held, c)
	}
	b.mem = held
}

// heldMB is the memory the memory fault holds.
func (b *Box) heldMB() int {
	b.mu.Lock()
	defer b.mu.Unlock()
	return len(b.mem)
}

// setDisk writes an mb MiB file into the disk directory (an emptyDir, counted against ephemeral storage), or
// removes it for 0.
func (b *Box) setDisk(mb int) error {
	if b.diskDir == "" {
		return errors.New("no disk directory configured (--disk-dir)")
	}
	path := filepath.Join(b.diskDir, diskFileName)
	if mb == 0 {
		if err := os.Remove(path); err != nil && !errors.Is(err, fs.ErrNotExist) {
			return err
		}
		return nil
	}
	file, err := os.OpenFile(path, os.O_CREATE|os.O_WRONLY|os.O_TRUNC, 0o600)
	if err != nil {
		return err
	}
	chunk := make([]byte, 1<<20)
	for i := range chunk {
		chunk[i] = 0xA5 // not zeros, so no filesystem can store the file sparse
	}
	for range mb {
		if _, err := file.Write(chunk); err != nil {
			_ = file.Close()
			return err
		}
	}
	if err := file.Sync(); err != nil {
		_ = file.Close()
		return err
	}
	return file.Close()
}

// startCPU burns millicores of CPU for d, replacing any cpu fault in force. Each worker is busy for its share of
// every 100 ms period and sleeps for the rest.
func (b *Box) startCPU(millicores int, d time.Duration) {
	if b.cpuStop != nil {
		b.cpuStop()
	}
	ctx, cancel := context.WithTimeout(context.Background(), d)
	b.cpuStop = cancel
	workers := (millicores + 999) / 1000
	const period = 100 * time.Millisecond
	busy := period * time.Duration(millicores/workers) / 1000
	for range workers {
		b.wg.Go(func() {
			for {
				start := time.Now()
				for time.Since(start) < busy {
					if ctx.Err() != nil {
						return
					}
				}
				select {
				case <-ctx.Done():
					return
				case <-time.After(period - busy):
				}
			}
		})
	}
}

// startLog writes perSecond lines of the pattern for d, replacing any log fault in force.
func (b *Box) startLog(pattern string, perSecond int, d time.Duration, rng *rand.Rand) {
	if b.logStop != nil {
		b.logStop()
	}
	ctx, cancel := context.WithTimeout(context.Background(), d)
	b.logStop = cancel
	lines := logPatterns[pattern]
	b.wg.Go(func() {
		t := time.NewTicker(time.Second / time.Duration(perSecond))
		defer t.Stop()
		for {
			select {
			case <-ctx.Done():
				return
			case <-t.C:
				_, _ = io.WriteString(b.out, lines[rng.IntN(len(lines))]+"\n")
			}
		}
	})
}

// endpointCrashDelay is the shortest delay of a crash asked for at an endpoint.
const endpointCrashDelay = 100 * time.Millisecond

// scheduleCrash exits with code after the delay, at once for none.
func (b *Box) scheduleCrash(code int, after time.Duration) {
	if b.crashTimer != nil {
		b.crashTimer.Stop()
	}
	if after == 0 {
		b.exit(code)
		return
	}
	b.crashTimer = time.AfterFunc(after, func() { b.exit(code) })
}

// reset ends every fault: frees the memory, removes the disk file, stops the cpu, log and a pending crash, and
// sets readiness, errors and latency back.
func (b *Box) reset() error {
	b.stopLocked()
	b.mem = nil
	debug.FreeOSMemory()
	b.ready.Store(true)
	b.latency.Store(0)
	b.errMu.Lock()
	b.errRate, b.errRNG = 0, nil
	b.errMu.Unlock()
	if b.diskDir == "" {
		return nil
	}
	return b.setDisk(0)
}

func (b *Box) stopLocked() {
	for _, stop := range []context.CancelFunc{b.cpuStop, b.logStop} {
		if stop != nil {
			stop()
		}
	}
	b.cpuStop, b.logStop = nil, nil
	if b.crashTimer != nil {
		b.crashTimer.Stop()
		b.crashTimer = nil
	}
}

// Close stops the running faults and waits for their goroutines.
func (b *Box) Close() {
	b.mu.Lock()
	b.stopLocked()
	b.mu.Unlock()
	b.wg.Wait()
}

// injectError reports whether this request gets an HTTP 500, drawn from the seed's sequence.
func (b *Box) injectError() bool {
	b.errMu.Lock()
	defer b.errMu.Unlock()
	return b.errRNG != nil && b.errRNG.Float64() < b.errRate
}
