//go:build unix

package schema_test

import "syscall"

// mkfifo makes a FIFO at path, for the suite's Fifo entries.
func mkfifo(path string) error { return syscall.Mkfifo(path, 0o644) }
