//go:build !unix

package schema_test

import "errors"

// mkfifo makes a FIFO at path: only on Unix (the suite's Fifo cases have
// os: "unix", and are skipped elsewhere).
func mkfifo(string) error { return errors.New("no FIFOs on this platform") }
