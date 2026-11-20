// Command speed times the haus Go binding against encoding/json on the
// exported corpus and writes bench/.out/<source>/speed-go.json for the
// report (pnpm --filter haus-bench speed-go, or go run ./cmd/speed in
// bench/speed/go). Options come from the environment: HAUS_BENCH_SOURCES,
// HAUS_BENCH_QUICK, HAUS_BENCH_OUT (see speed.Settings).
//
// Each task runs once untimed (its output's size goes into the checksum),
// then for the warm-up, then Samples times with testing.Benchmark, each run
// one sample. Every run is also printed in the format of go test -bench,
// so the output feeds benchstat.
package main

import (
	"flag"
	"fmt"
	"os"
	"runtime"
	"testing"
	"time"

	speed "github.com/betalyra/haus-fmt/bench/speed/go"
)

// harness is the harness, as recorded in the results.
const harness = "testing.Benchmark (b.Loop)"

func main() {
	if err := run(); err != nil {
		fmt.Fprintln(os.Stderr, "error:", err)
		os.Exit(1)
	}
}

// setBenchTime sets the time testing.Benchmark runs a benchmark for.
func setBenchTime(d time.Duration) error {
	return flag.Set("test.benchtime", d.String())
}

func run() error {
	settings, err := speed.SettingsFromEnv()
	if err != nil {
		return err
	}
	testing.Init()
	machine := speed.DetectMachine()
	for _, source := range settings.Sources {
		if err := bench(settings, machine, source); err != nil {
			return fmt.Errorf("%s: %w", source, err)
		}
	}
	return nil
}

func bench(settings speed.Settings, machine speed.Machine, source string) error {
	c, err := speed.LoadCorpus(settings.Out, source)
	if err != nil {
		return err
	}
	in, err := speed.Prepare(c)
	if err != nil {
		return err
	}
	jsonNotStable, err := in.Check()
	if err != nil {
		return err
	}
	tasks, err := in.Tasks()
	if err != nil {
		return err
	}
	var checksum int64
	for _, t := range tasks {
		n, err := t.Run()
		if err != nil {
			return fmt.Errorf("%s: %w", t.ID, err)
		}
		checksum += int64(n)
	}
	o := settings.Options
	docs := len(c.Documents)
	out := speed.Results{
		Lang:          "go",
		Harness:       harness,
		Machine:       machine,
		Options:       speed.OptionsOut{TimeMs: o.Time.Milliseconds(), WarmupMs: o.Warmup.Milliseconds(), Quick: o.Quick},
		JSONNotStable: jsonNotStable,
		Checksum:      checksum,
	}
	for _, d := range c.Documents {
		out.Documents = append(out.Documents, d.ID)
	}
	for _, t := range tasks {
		if err := setBenchTime(o.Warmup); err != nil {
			return err
		}
		testing.Benchmark(t.Bench)
		if err := setBenchTime(o.Time / time.Duration(o.Samples)); err != nil {
			return err
		}
		samples := make([]testing.BenchmarkResult, o.Samples)
		for i := range samples {
			samples[i] = testing.Benchmark(t.Bench)
			if samples[i].N == 0 {
				return fmt.Errorf("%s failed", t.ID)
			}
			fmt.Printf("BenchmarkSpeed/%s/%s-%d\t%s\t%s\n", source, t.ID, runtime.GOMAXPROCS(0),
				samples[i].String(), samples[i].MemString())
		}
		out.Rows = append(out.Rows, speed.NewRow(t, docs, samples))
	}
	path, err := out.Write(settings.Out, source)
	if err != nil {
		return err
	}
	quick := ""
	if o.Quick {
		quick = " (quick)"
	}
	fmt.Printf("\n%s: %s, %s%s\n", source, machine.CPU, machine.Runtime, quick)
	for _, r := range out.Rows {
		fmt.Println(r.Line())
	}
	fmt.Printf("encoding/json wrote %d documents back as another document; wrote %s\n\n", jsonNotStable, path)
	return nil
}
