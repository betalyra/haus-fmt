package speed

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"slices"
	"testing"
)

// Row is one task's results, in the shape every language writes
// (SpeedRow in bench/size/src/results.ts).
type Row struct {
	Group  string `json:"group"`
	Input  string `json:"input"`
	Format string `json:"format"`
	Impl   string `json:"impl"`
	// Bytes read (parse, typed) or written (write) per iteration.
	Bytes   int64   `json:"bytes"`
	Docs    int     `json:"docs"`
	Hz      float64 `json:"hz"`
	MeanMs  float64 `json:"mean_ms"`
	P75Ms   float64 `json:"p75_ms"`
	P99Ms   float64 `json:"p99_ms"`
	Samples int     `json:"samples"`
	MBs     float64 `json:"mb_s"`
	UsDoc   float64 `json:"us_per_doc"`
	// Allocations and bytes allocated per iteration (testing's -benchmem).
	Allocs     float64 `json:"allocs"`
	AllocBytes float64 `json:"alloc_bytes"`
}

// Quantile returns the q quantile of sorted values, interpolated between
// the nearest ranks.
func Quantile(sorted []float64, q float64) float64 {
	pos := q * float64(len(sorted)-1)
	lo, hi := int(pos), min(int(pos)+1, len(sorted)-1)
	return sorted[lo] + (sorted[hi]-sorted[lo])*(pos-float64(lo))
}

// NewRow summarizes the samples of a task: each a testing.Benchmark run,
// whose mean time per iteration is one sample (as criterion's samples are
// the means of batches). The mean is over all iterations of all samples.
func NewRow(t Task, docs int, samples []testing.BenchmarkResult) Row {
	var n, ns, allocs, allocBytes float64
	per := make([]float64, len(samples))
	for i, s := range samples {
		n += float64(s.N)
		ns += float64(s.T.Nanoseconds())
		allocs += float64(s.MemAllocs)
		allocBytes += float64(s.MemBytes)
		per[i] = float64(s.T.Nanoseconds()) / float64(s.N) / 1e6
	}
	slices.Sort(per)
	meanMs := ns / n / 1e6
	return Row{
		Group: t.Group, Input: t.Input, Format: t.Format, Impl: t.Impl,
		Bytes: t.Bytes, Docs: docs,
		Hz:      1000 / meanMs,
		MeanMs:  meanMs,
		P75Ms:   Quantile(per, 0.75),
		P99Ms:   Quantile(per, 0.99),
		Samples: len(samples),
		MBs:     float64(t.Bytes) / 1e6 / (meanMs / 1000),
		UsDoc:   meanMs * 1000 / float64(docs),
		Allocs:  allocs / n, AllocBytes: allocBytes / n,
	}
}

// Line is the row for the terminal, as the other languages print it.
func (r Row) Line() string {
	task := fmt.Sprintf("%s | %s | %s", r.Group, r.Input, r.Impl)
	return fmt.Sprintf("%-56s %8.1f MB/s %9.2f µs/doc  p99 %.3f ms  %8.0f allocs  (%d samples)",
		task, r.MBs, r.UsDoc, r.P99Ms, r.Allocs, r.Samples)
}

// OptionsOut are the timing options as recorded.
type OptionsOut struct {
	TimeMs   int64 `json:"time_ms"`
	WarmupMs int64 `json:"warmup_ms"`
	Quick    bool  `json:"quick"`
}

// Results are one source's results: bench/.out/<source>/speed-go.json, the
// shape of speed-typescript.json and speed-rust.json.
type Results struct {
	Lang      string     `json:"lang"`
	Harness   string     `json:"harness"`
	Machine   Machine    `json:"machine"`
	Options   OptionsOut `json:"options"`
	Documents []string   `json:"documents"`
	// JSONNotStable counts the documents encoding/json writes back as
	// another document through any (numbers as float64; it sorts members,
	// which isn't counted).
	JSONNotStable int   `json:"jsonNotStable"`
	Rows          []Row `json:"rows"`
	// Checksum is the sum of the sizes of every task's output, once:
	// it changes when an output changes.
	Checksum int64 `json:"checksum"`
}

// Write writes <out>/<source>/speed-go.json and returns its path.
func (s Results) Write(out, source string) (string, error) {
	path := filepath.Join(out, source, "speed-go.json")
	text, err := json.MarshalIndent(s, "", "  ")
	if err != nil {
		return "", err
	}
	return path, os.WriteFile(path, text, 0o644)
}
