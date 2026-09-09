#if canImport(Darwin)
private import Darwin
#elseif canImport(Glibc)
private import Glibc
#endif

#if canImport(System)
public import System
#else
public import SystemPackage
#endif

extension Terminal {

    /// Returns the current terminal viewport size for a file descriptor.
    ///
    /// This function queries the operating system with `TIOCGWINSZ` and
    /// returns the terminal's current column and row count. Pass a file
    /// descriptor connected to a terminal device, such as standard input,
    /// standard output, or standard error.
    ///
    /// - Parameter fileDescriptor: The terminal file descriptor to query.
    /// - Returns: The terminal size reported by the operating system.
    /// - Throws: `Errno` when the underlying `ioctl` call fails.
    public static func size(for fileDescriptor: FileDescriptor) throws(Errno) -> Size {
        var size = winsize()
        let result = unsafe ioctl(fileDescriptor.rawValue, .init(TIOCGWINSZ), &size)
        guard result == 0
        else {
            throw .init(rawValue: errno)
        }
        return .init(columns: .init(size.ws_col), rows: .init(size.ws_row))
    }
}