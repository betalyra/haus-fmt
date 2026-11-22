//go:build unix

package schema

import (
	"io/fs"
	"os"
	"syscall"
)

// isLink reports whether os.Lstat saw a symbolic link.
func isLink(fi fs.FileInfo) bool { return fi.Mode()&fs.ModeSymlink != 0 }

// openFile opens a file to read without following a link at its last name
// (O_NOFOLLOW), without blocking on a FIFO or a device (O_NONBLOCK), and
// without making a terminal the controlling one (O_NOCTTY). The caller
// checks the opened file (spec §13.3, "Files read").
func openFile(path string) (*os.File, error) {
	return os.OpenFile(path, os.O_RDONLY|syscall.O_NOFOLLOW|syscall.O_NONBLOCK|syscall.O_NOCTTY, 0)
}

// openDir opens a directory to list it, without blocking if it is a FIFO
// (listing one then fails).
func openDir(path string) (*os.File, error) {
	return os.OpenFile(path, os.O_RDONLY|syscall.O_NONBLOCK|syscall.O_NOCTTY, 0)
}
