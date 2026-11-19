//go:build unix

package schema

import (
	"os"
	"syscall"
)

// openFile opens a file to read: without following a link at path when
// follow is false (O_NOFOLLOW), and without blocking on a FIFO (O_NONBLOCK).
func openFile(path string, follow bool) (*os.File, error) {
	flags := os.O_RDONLY | syscall.O_NONBLOCK
	if !follow {
		flags |= syscall.O_NOFOLLOW
	}
	return os.OpenFile(path, flags, 0)
}

// worldWritable reports whether everyone may write to dir, such as /tmp: a
// node_modules there is never used (spec §13.3).
func worldWritable(dir string) bool {
	fi, err := os.Stat(dir)
	return err == nil && fi.Mode().Perm()&0o002 != 0
}

// driveRoot reports whether dir is the root of a Windows drive.
func driveRoot(string) bool { return false }
