//go:build !unix && !windows

package schema

import (
	"io/fs"
	"os"
)

// isLink reports whether os.Lstat saw a symbolic link.
func isLink(fi fs.FileInfo) bool { return fi.Mode()&fs.ModeSymlink != 0 }

// openFile opens a file to read. These platforms (WebAssembly, Plan 9) have
// no flag to open without following a link or without blocking: the path
// is checked just before (os.Lstat), the opened file after (a regular
// file, the same one), and a file swapped in between can still be opened.
func openFile(path string) (*os.File, error) { return os.Open(path) }

// openDir opens a directory to list it.
func openDir(path string) (*os.File, error) { return os.Open(path) }
