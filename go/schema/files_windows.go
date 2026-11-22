//go:build windows

package schema

import (
	"io/fs"
	"os"
	"syscall"
)

// isLink reports whether os.Lstat saw a symbolic link or any other reparse
// point (a junction, a mount point).
func isLink(fi fs.FileInfo) bool {
	if fi.Mode()&fs.ModeSymlink != 0 {
		return true
	}
	a, ok := fi.Sys().(*syscall.Win32FileAttributeData)
	return ok && a.FileAttributes&syscall.FILE_ATTRIBUTE_REPARSE_POINT != 0
}

// openFile opens a file to read with FILE_FLAG_OPEN_REPARSE_POINT, so that a
// symbolic link or junction at its last name is opened itself, not
// followed, and requires a file on disk (GetFileType: FILE_TYPE_DISK, not a
// pipe or a device such as CON) that is neither a reparse point nor a
// directory (GetFileInformationByHandle). The caller checks that it is the
// file the path named (spec §13.3, "Files read").
func openFile(path string) (*os.File, error) {
	name, err := syscall.UTF16PtrFromString(path)
	if err != nil {
		return nil, &fs.PathError{Op: "open", Path: path, Err: err}
	}
	h, err := syscall.CreateFile(name, syscall.GENERIC_READ,
		syscall.FILE_SHARE_READ|syscall.FILE_SHARE_WRITE|syscall.FILE_SHARE_DELETE, nil,
		syscall.OPEN_EXISTING, syscall.FILE_ATTRIBUTE_NORMAL|syscall.FILE_FLAG_OPEN_REPARSE_POINT, 0)
	if err != nil {
		return nil, &fs.PathError{Op: "open", Path: path, Err: err}
	}
	typ, err := syscall.GetFileType(h)
	if err != nil || typ != syscall.FILE_TYPE_DISK {
		_ = syscall.CloseHandle(h)
		return nil, errNotRegular
	}
	var info syscall.ByHandleFileInformation
	if err := syscall.GetFileInformationByHandle(h, &info); err != nil ||
		info.FileAttributes&(syscall.FILE_ATTRIBUTE_REPARSE_POINT|syscall.FILE_ATTRIBUTE_DIRECTORY) != 0 {
		_ = syscall.CloseHandle(h)
		return nil, errNotRegular
	}
	return os.NewFile(uintptr(h), path), nil
}

// openDir opens a directory to list it.
func openDir(path string) (*os.File, error) { return os.Open(path) }
