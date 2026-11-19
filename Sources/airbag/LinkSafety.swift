import Darwin

/// Rejects pre-existing hard-linked files before a path-scoped sandbox is installed.
/// The walk uses directory descriptors and never follows symbolic links.
enum LinkSafety {
    static func validateDirectory(_ path: String) throws {
        let fd = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw failure(path, "cannot open directory for link verification") }
        try walk(fd: fd, path: path, depth: 0)
    }

    static func validateFile(_ path: String) throws {
        var info = stat()
        guard lstat(path, &info) == 0 else { throw failure(path, "cannot inspect protected file") }
        try rejectHardLink(info, path: path)
    }

    /// Takes ownership of fd, including error paths.
    private static func walk(fd: Int32, path: String, depth: Int) throws {
        guard depth <= 256 else {
            close(fd)
            throw failure(path, "directory nesting exceeds the verification limit")
        }
        guard let stream = fdopendir(fd) else {
            close(fd)
            throw failure(path, "cannot enumerate directory")
        }
        defer { closedir(stream) }
        while true {
            errno = 0
            guard let entry = readdir(stream) else {
                if errno != 0 { throw failure(path, "directory enumeration failed") }
                return
            }
            let name = withUnsafePointer(to: entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) { String(cString: $0) }
            }
            if name == "." || name == ".." { continue }
            let childPath = path + "/" + name
            var info = stat()
            guard fstatat(fd, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else {
                throw failure(childPath, "directory changed or entry cannot be inspected")
            }
            try rejectHardLink(info, path: childPath)
            if info.st_mode & S_IFMT == S_IFDIR {
                let child = openat(fd, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard child >= 0 else { throw failure(childPath, "directory changed or cannot be opened") }
                var opened = stat()
                guard fstat(child, &opened) == 0,
                      opened.st_dev == info.st_dev, opened.st_ino == info.st_ino else {
                    close(child)
                    throw failure(childPath, "directory identity changed during verification")
                }
                try walk(fd: child, path: childPath, depth: depth + 1)
            }
        }
    }

    private static func rejectHardLink(_ info: stat, path: String) throws {
        if info.st_mode & S_IFMT == S_IFREG && info.st_nlink > 1 {
            throw failure(path, "file has multiple hard links; use an independent copy or a workspace without hard-linked files")
        }
    }

    private static func failure(_ path: String, _ reason: String) -> SettingsError {
        SettingsError("Link verification failed for \(String(reflecting: path)): \(reason).")
    }
}
