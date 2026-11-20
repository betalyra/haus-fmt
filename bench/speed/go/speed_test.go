package speed

import (
	"testing"
)

// BenchmarkSpeed runs every task of every source (HAUS_BENCH_SOURCES), each
// checked first, as BenchmarkSpeed/<source>/<task>:
//
//	go test -bench . -benchmem -count 10 > old.txt
//	benchstat old.txt new.txt
//
// cmd/speed runs the same tasks and writes the results files.
func BenchmarkSpeed(b *testing.B) {
	settings, err := SettingsFromEnv()
	if err != nil {
		b.Fatal(err)
	}
	for _, source := range settings.Sources {
		c, err := LoadCorpus(settings.Out, source)
		if err != nil {
			b.Fatal(err)
		}
		in, err := Prepare(c)
		if err != nil {
			b.Fatal(err)
		}
		if _, err := in.Check(); err != nil {
			b.Fatalf("%s: %v", source, err)
		}
		tasks, err := in.Tasks()
		if err != nil {
			b.Fatal(err)
		}
		b.Run(source, func(b *testing.B) {
			for _, t := range tasks {
				b.Run(t.ID, t.Bench)
			}
		})
	}
}

func TestQuantile(t *testing.T) {
	xs := []float64{1, 2, 3, 4, 5}
	for _, c := range []struct{ q, want float64 }{{0, 1}, {0.5, 3}, {0.75, 4}, {0.99, 4.96}, {1, 5}} {
		if got := Quantile(xs, c.q); got-c.want > 1e-9 || c.want-got > 1e-9 {
			t.Errorf("Quantile(%v) = %v, want %v", c.q, got, c.want)
		}
	}
	if got := Quantile([]float64{7}, 0.99); got != 7 {
		t.Errorf("one value: %v", got)
	}
}
