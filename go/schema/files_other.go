//go:build !unix

package schema

import (
	"errors"
	"io/fs"
	"os"
	"path/filepath"
)

// errLink is opening a link that isn't followed.
var errLink = errors.New("a symbolic link, not followed")

// openFile opens a file to read, without following a link at path when
// follow is false: the path is checked before the open and the opened file
// after it (its type and size), as far as the platform allows.
func openFile(path string, follow bool) (*os.File, error) {
	if follow {
		return os.Open(path)
	}
	before, err := os.Lstat(path)
	if err != nil {
		return nil, err
	}
	if before.Mode()&fs.ModeSymlink != 0 || !before.Mode().IsRegular() {
		return nil, errLink
	}
	f, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	after, err := f.Stat()
	if err != nil || !os.SameFile(before, after) {
		f.Close()
		return nil, errLink
	}
	return f, nil
}

// worldWritable reports whether everyone may write to dir; not known here.
func worldWritable(string) bool { return false }

// driveRoot reports whether dir is the root of a drive (C:\), where any user
// can create node_modules.
func driveRoot(dir string) bool {
	return filepath.Dir(dir) == dir
}
