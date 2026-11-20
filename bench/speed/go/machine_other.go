//go:build !darwin

package speed

import (
	"os"
	"strconv"
	"strings"
)

// procField returns the value of a line "key : value" of a /proc file.
func procField(file, key string) string {
	text, err := os.ReadFile(file)
	if err != nil {
		return ""
	}
	for line := range strings.SplitSeq(string(text), "\n") {
		if k, v, ok := strings.Cut(line, ":"); ok && strings.TrimSpace(k) == key {
			return strings.TrimSpace(v)
		}
	}
	return ""
}

// system reads the CPU, memory and OS release from /proc (Linux; empty
// elsewhere).
func system() (cpu string, memory uint64, release string) {
	cpu = procField("/proc/cpuinfo", "model name")
	kb, _ := strconv.ParseUint(strings.TrimSpace(strings.TrimSuffix(procField("/proc/meminfo", "MemTotal"), "kB")), 10, 64)
	osRelease, _ := os.ReadFile("/proc/sys/kernel/osrelease")
	return cpu, kb * 1024, strings.TrimSpace(string(osRelease))
}
