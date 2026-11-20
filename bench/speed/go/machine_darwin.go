package speed

import (
	"encoding/binary"
	"syscall"
)

// system reads the CPU, memory and OS release with sysctl, as Node's os does.
func system() (cpu string, memory uint64, release string) {
	cpu, _ = syscall.Sysctl("machdep.cpu.brand_string")
	release, _ = syscall.Sysctl("kern.osrelease")
	// hw.memsize is a uint64; Sysctl drops one trailing zero byte.
	if raw, err := syscall.Sysctl("hw.memsize"); err == nil && len(raw) <= 8 {
		var b [8]byte
		copy(b[:], raw)
		memory = binary.LittleEndian.Uint64(b[:])
	}
	return cpu, memory, release
}
