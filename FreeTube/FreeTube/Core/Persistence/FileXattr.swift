import Foundation

/// Thin Swift wrapper around POSIX extended-attribute syscalls (`setxattr`, `getxattr`,
/// `removexattr`) defined in `<sys/xattr.h>`. Used by `DownloadsStore` to carry per-file
/// metadata (title, channel, original URL, thumbnail, …) on the actual `.mp4` on disk —
/// no SwiftData row needed.
///
/// **Why we use `fileSystemRepresentation` not `path`**: POSIX expects a C string of bytes
/// in the file system's native encoding (NFD-normalised UTF-8 on APFS), not Swift's
/// Unicode-canonical `String.utf8`. The two diverge for paths with combining characters
/// (most non-ASCII Unicode). The `fileSystemRepresentation` accessor produces the right
/// bytes; passing `URL.path` directly would silently miss files with accented names.
enum FileXattr {
    /// Read the value of an extended attribute. Returns nil for "attribute doesn't exist"
    /// (`ENOATTR`) as well as for any other read failure — the caller treats both the same.
    static func read(key: String, at url: URL) -> Data? {
        url.withUnsafeFileSystemRepresentation { cPath -> Data? in
            guard let cPath else { return nil }
            // First call: ask for the length only. Second call: read into a buffer of
            // exactly that size. Two-step pattern recommended by the man page.
            let length = getxattr(cPath, key, nil, 0, 0, 0)
            guard length > 0 else { return nil }
            var data = Data(count: length)
            let actual = data.withUnsafeMutableBytes { buf -> ssize_t in
                guard let base = buf.baseAddress else { return -1 }
                return getxattr(cPath, key, base, length, 0, 0)
            }
            guard actual == length else { return nil }
            return data
        }
    }

    /// Write (or replace) an extended attribute. Throws on any failure so callers can log.
    static func write(_ data: Data, key: String, at url: URL) throws {
        let status = url.withUnsafeFileSystemRepresentation { cPath -> Int32 in
            guard let cPath else { return -1 }
            return data.withUnsafeBytes { buf -> Int32 in
                guard let base = buf.baseAddress else { return -1 }
                return setxattr(cPath, key, base, buf.count, 0, 0)
            }
        }
        if status != 0 {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: [
                NSLocalizedDescriptionKey: "setxattr(\(key)) failed for \(url.lastPathComponent)"
            ])
        }
    }

    /// Remove an attribute. No-op when the attribute doesn't exist (matches the
    /// ObjC reference implementation that early-returns success in that case).
    static func remove(key: String, at url: URL) {
        url.withUnsafeFileSystemRepresentation { cPath in
            guard let cPath else { return }
            _ = removexattr(cPath, key, 0)
        }
    }
}
