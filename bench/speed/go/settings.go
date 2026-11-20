package speed

import (
	"fmt"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"time"
)

// Options are the timing options, as recorded in the results.
type Options struct {
	// Time is the time per task (Samples runs of Time/Samples each), after
	// Warmup.
	Time, Warmup time.Duration
	Samples      int
	Quick        bool
}

// Settings say what to run, from the environment (like the Rust benchmark,
// whose command line belongs to criterion):
//
//	HAUS_BENCH_SOURCES=vega-lite,geojson   only these sources (default: every source in sources.haus)
//	HAUS_BENCH_QUICK=1                     a short budget: checks the harness, not for publishing
//	HAUS_BENCH_OUT=/elsewhere              the results directory convert wrote to (default bench/.out)
type Settings struct {
	Bench   string // the bench/ directory
	Out     string
	Sources []string
	Options Options
}

// SettingsFromEnv reads the settings, finding bench/ from the working
// directory.
func SettingsFromEnv() (Settings, error) {
	wd, err := os.Getwd()
	if err != nil {
		return Settings{}, err
	}
	bench, err := BenchDir(wd)
	if err != nil {
		return Settings{}, err
	}
	all, err := Sources(filepath.Join(bench, "sources.haus"))
	if err != nil {
		return Settings{}, err
	}
	s := Settings{Bench: bench, Out: filepath.Join(bench, ".out"), Sources: all}
	if out := os.Getenv("HAUS_BENCH_OUT"); out != "" {
		s.Out = out
	}
	if list := os.Getenv("HAUS_BENCH_SOURCES"); list != "" {
		s.Sources = strings.Split(list, ",")
		for _, name := range s.Sources {
			if !slices.Contains(all, name) {
				return Settings{}, fmt.Errorf("no corpus source %s in sources.haus", name)
			}
		}
	}
	quick := os.Getenv("HAUS_BENCH_QUICK")
	if quick != "" && quick != "0" {
		s.Options = Options{Time: 150 * time.Millisecond, Warmup: 50 * time.Millisecond, Samples: 5, Quick: true}
	} else {
		s.Options = Options{Time: 3 * time.Second, Warmup: time.Second, Samples: 20}
	}
	return s, nil
}
