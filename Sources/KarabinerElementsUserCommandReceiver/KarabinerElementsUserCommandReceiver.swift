import Darwin
import Foundation

public enum KEUserCommandReceiverError: Error, CustomStringConvertible {
  case sys(String)
  case invalidPath(String)
  case alreadyRunning

  public var description: String {
    switch self {
    case .sys(let s): return s
    case .invalidPath(let p): return "invalid socket path: \(p)"
    case .alreadyRunning: return "server already running"
    }
  }
}

public actor KEUserCommandReceiver {
  public typealias JSONHandler = @Sendable (Any) -> Void
  public typealias ErrorHandler = @Sendable (Error) -> Void

  private struct Handlers: Sendable {
    let onJSON: @Sendable (Any) -> Void
    let onError: (@Sendable (Error) -> Void)?
  }

  private let path: String
  private let maxDatagramBytes: Int
  private let recvBufferBytes: Int
  private let onJSON: JSONHandler
  private let onError: ErrorHandler?
  private var fd: Int32 = -1
  private var task: Task<Void, Never>?

  public static func defaultSocketPath() -> String {
    return "/Library/Application Support/org.pqrs/tmp/user/\(geteuid())/user_command_receiver.sock"
  }

  public init(
    path: String,
    maxDatagramBytes: Int = 32 * 1024,
    recvBufferBytes: Int = 128 * 1024,
    onJSON: @escaping JSONHandler,
    onError: ErrorHandler? = nil
  ) {
    self.path = path
    self.maxDatagramBytes = maxDatagramBytes
    self.recvBufferBytes = recvBufferBytes
    self.onJSON = onJSON
    self.onError = onError
  }

  // After calling start, the caller must take responsibility for calling stop.
  public func start() throws {
    if fd >= 0 {
      throw KEUserCommandReceiverError.alreadyRunning
    }
    if task != nil {
      throw KEUserCommandReceiverError.alreadyRunning
    }
    fd = try bindUnixDatagramSocket(path: path)

    var bufsize = recvBufferBytes
    _ = setsockopt(
      fd, SOL_SOCKET, SO_RCVBUF, &bufsize, socklen_t(MemoryLayout.size(ofValue: bufsize)))

    let capturedFD = fd
    let capturedMaxDatagramBytes = maxDatagramBytes
    let handlers = Handlers(onJSON: onJSON, onError: onError)

    task = Task.detached { [weak self] in
      Self.receiveLoop(
        fd: capturedFD,
        maxDatagramBytes: capturedMaxDatagramBytes,
        handlers: handlers)
      await self?.markStopped()
    }
  }

  public func stop() {
    task?.cancel()
    task = nil
    if fd >= 0 {
      close(fd)
      fd = -1
    }
    unlinkIfExists(path)
  }

  private func markStopped() {
    fd = -1
    task = nil
  }

  private static func receiveLoop(
    fd: Int32,
    maxDatagramBytes: Int,
    handlers: Handlers
  ) {
    var buf = [UInt8](repeating: 0, count: maxDatagramBytes)

    while true {
      if Task.isCancelled { break }

      let n = recvfrom(fd, &buf, buf.count, 0, nil, nil)
      if n < 0 {
        if errno == EINTR { continue }
        if errno == EBADF { break }
        handlers.onError?(KEUserCommandReceiverError.sys("recvfrom failed errno=\(errno)"))
        continue
      }
      if n == 0 { continue }

      var end = n
      if end > 0 && buf[end - 1] == 0x0A { end -= 1 }
      if end > 0 && buf[end - 1] == 0x0D { end -= 1 }
      if end == 0 { continue }

      let data = Data(bytes: buf, count: end)
      do {
        let json = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        handlers.onJSON(json)
      } catch {
        handlers.onError?(error)
      }
    }
  }
}

private func withErrno<T>(_ fn: () -> T) -> (T, Int32) {
  errno = 0
  let r = fn()
  return (r, errno)
}

private func sockaddr_un_forPath(_ path: String) throws -> sockaddr_un {
  guard !path.isEmpty else { throw KEUserCommandReceiverError.invalidPath(path) }
  var addr = sockaddr_un()
  addr.sun_family = sa_family_t(AF_UNIX)

  let maxLen = MemoryLayout.size(ofValue: addr.sun_path)
  let utf8Len = path.utf8CString.count
  guard utf8Len <= maxLen else { throw KEUserCommandReceiverError.invalidPath(path) }

  path.withCString { cstr in
    withUnsafeMutablePointer(to: &addr.sun_path) { p in
      p.withMemoryRebound(to: CChar.self, capacity: maxLen) { buf in
        strncpy(buf, cstr, maxLen - 1)
        buf[maxLen - 1] = 0
      }
    }
  }

  return addr
}

private func unlinkIfExists(_ path: String) {
  _ = path.withCString { cstr in
    unlink(cstr)
  }
}

private func bindUnixDatagramSocket(path: String) throws -> Int32 {
  let (fd, err1) = withErrno { socket(AF_UNIX, SOCK_DGRAM, 0) }
  if fd < 0 { throw KEUserCommandReceiverError.sys("socket(dgram) failed errno=\(err1)") }

  unlinkIfExists(path)
  var addr = try sockaddr_un_forPath(path)
  let bindRes: Int32 = withUnsafePointer(to: &addr) { p in
    p.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
      bind(fd, sa, socklen_t(MemoryLayout<sockaddr_un>.size))
    }
  }
  if bindRes != 0 {
    let e = errno
    close(fd)
    throw KEUserCommandReceiverError.sys("bind(dgram) failed errno=\(e) path=\(path)")
  }

  return fd
}
