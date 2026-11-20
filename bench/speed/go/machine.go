package speed

import (
	"math"
	"runtime"
)

// Machine is the machine the benchmark runs on, in the words the TypeScript
// step uses (Node's os): Apple M1 Max, 10 cores, darwin 25.5.0 arm64.
type Machine struct {
	CPU      string `json:"cpu"`
	Cores    int    `json:"cores"`
	MemoryGB int    `json:"memory_gb"`
	OS       string `json:"os"`
	// Runtime is the Go version the benchmark was built with: go1.27.4.
	Runtime string `json:"runtime"`
	// GC is true: testing collects garbage before each run.
	GC bool `json:"gc"`
}

// DetectMachine describes this machine.
func DetectMachine() Machine {
	cpu, memory, release := system()
	if cpu == "" {
		cpu = "unknown"
	}
	// Node's names for the architecture, so every language's results read the same.
	arch := map[string]string{"amd64": "x64", "386": "ia32"}[runtime.GOARCH]
	if arch == "" {
		arch = runtime.GOARCH
	}
	return Machine{
		CPU:      cpu,
		Cores:    runtime.NumCPU(),
		MemoryGB: int(math.Round(float64(memory) / (1 << 30))),
		OS:       runtime.GOOS + " " + release + " " + arch,
		Runtime:  runtime.Version(),
		GC:       true,
	}
}
