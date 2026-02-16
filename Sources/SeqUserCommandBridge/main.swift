import Darwin
import Dispatch
import Foundation
import KarabinerElementsUserCommandReceiver

private struct BridgeConfig {
  let receiverSocketPath: String
  let seqStreamSocketPath: String
  let seqDgramSocketPath: String
  let preferDgram: Bool
  let verbose: Bool
  let highPriority: Bool

  static let `default` = BridgeConfig(
    receiverSocketPath: "~/.local/share/karabiner/tmp/karabiner_user_command_receiver.sock",
    seqStreamSocketPath: "/tmp/seqd.sock",
    seqDgramSocketPath: "/tmp/seqd.sock.dgram",
    preferDgram: true,
    verbose: false,
    highPriority: true
  )
}

private func logErr(_ message: String) {
  FileHandle.standardError.write(Data((message + "\n").utf8))
}

private struct RuntimePriorityGuard {
  private let activityToken: NSObjectProtocol?

  init(enabled: Bool) {
    if enabled {
      activityToken = ProcessInfo.processInfo.beginActivity(
        options: [.userInteractive],
        reason: "seq-user-command-bridge low-latency forwarding"
      )
#if os(macOS)
      pthread_set_qos_class_self_np(QOS_CLASS_USER_INTERACTIVE, 0)
#endif
    } else {
      activityToken = nil
    }
  }

  func close() {
    guard let token = activityToken else { return }
    ProcessInfo.processInfo.endActivity(token)
  }
}

private func monotonicMicroseconds() -> UInt64 {
  DispatchTime.now().uptimeNanoseconds / 1_000
}

private func realtimeMicroseconds() -> UInt64 {
  var ts = timespec()
  clock_gettime(CLOCK_REALTIME, &ts)
  let sec = UInt64(ts.tv_sec)
  let nsec = UInt64(ts.tv_nsec)
  return sec * 1_000_000 + (nsec / 1_000)
}

private func compactCommand(_ command: String, limit: Int = 120) -> String {
  let normalized = command.replacingOccurrences(of: "\n", with: " ")
  if normalized.count <= limit {
    return normalized
  }
  let endIndex = normalized.index(normalized.startIndex, offsetBy: max(0, limit - 3))
  return String(normalized[..<endIndex]) + "..."
}

private enum CommandParser {
  static func parse(from json: Any) -> String? {
    if let value = json as? String {
      return normalize(value, implicitRun: true)
    }

    guard let obj = json as? [String: Any] else {
      return nil
    }

    if let line = string(obj["line"]) {
      return normalize(line, implicitRun: false)
    }
    if let command = string(obj["command"]) {
      return normalize(command, implicitRun: true)
    }

    if let type = string(obj["type"])?.lowercased() {
      switch type {
      case "run":
        if let name = string(obj["name"]) ?? string(obj["macro"]) ?? string(obj["arg"]) {
          return normalize("RUN \(name)", implicitRun: false)
        }
      case "open_app":
        if let app = string(obj["app"]) ?? string(obj["name"]) ?? string(obj["arg"]) {
          return normalize("OPEN_APP \(app)", implicitRun: false)
        }
      case "open_app_toggle":
        if let app = string(obj["app"]) ?? string(obj["name"]) ?? string(obj["arg"]) {
          return normalize("OPEN_APP_TOGGLE \(app)", implicitRun: false)
        }
      case "raw":
        if let raw = string(obj["line"]) ?? string(obj["command"]) {
          return normalize(raw, implicitRun: false)
        }
      default:
        break
      }
    }

    if let name = string(obj["name"]) {
      return normalize(name, implicitRun: true)
    }

    return nil
  }

  private static func string(_ value: Any?) -> String? {
    guard let raw = value as? String else { return nil }
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }

  private static func normalize(_ raw: String, implicitRun: Bool) -> String? {
    var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else { return nil }
    text = text.replacingOccurrences(of: "\r", with: " ").replacingOccurrences(of: "\n", with: " ")
    if text.hasPrefix("RUN ")
      || text.hasPrefix("OPEN_APP ")
      || text.hasPrefix("OPEN_APP_TOGGLE ")
      || text.hasPrefix("OPEN_WITH_APP ")
      || text.hasPrefix("PING")
    {
      return text
    }
    return implicitRun ? "RUN \(text)" : text
  }
}

private actor SeqForwarder {
  struct SendResult {
    let ok: Bool
    let transport: String
    let elapsedMicroseconds: UInt64
  }

  private let streamPath: String
  private let dgramPath: String
  private let preferDgram: Bool
  private let verbose: Bool
  private var streamFD: Int32 = -1

  init(streamPath: String, dgramPath: String, preferDgram: Bool, verbose: Bool) {
    self.streamPath = streamPath
    self.dgramPath = dgramPath
    self.preferDgram = preferDgram
    self.verbose = verbose
  }

  func send(command: String) -> SendResult {
    let startedAt = monotonicMicroseconds()
    let line = command.hasSuffix("\n") ? command : "\(command)\n"
    if preferDgram {
      if sendDgram(line) {
        return SendResult(
          ok: true,
          transport: "dgram",
          elapsedMicroseconds: monotonicMicroseconds() - startedAt
        )
      }
      if sendStream(line) {
        return SendResult(
          ok: true,
          transport: "stream(fallback)",
          elapsedMicroseconds: monotonicMicroseconds() - startedAt
        )
      }
      return SendResult(
        ok: false,
        transport: "none",
        elapsedMicroseconds: monotonicMicroseconds() - startedAt
      )
    }
    if sendStream(line) {
      return SendResult(
        ok: true,
        transport: "stream",
        elapsedMicroseconds: monotonicMicroseconds() - startedAt
      )
    }
    if sendDgram(line) {
      return SendResult(
        ok: true,
        transport: "dgram(fallback)",
        elapsedMicroseconds: monotonicMicroseconds() - startedAt
      )
    }
    return SendResult(
      ok: false,
      transport: "none",
      elapsedMicroseconds: monotonicMicroseconds() - startedAt
    )
  }

  func shutdown() {
    closeStream()
  }

  private func sendDgram(_ line: String) -> Bool {
    guard let addr = makeAddress(path: dgramPath) else { return false }
    let fd = socket(AF_UNIX, SOCK_DGRAM, 0)
    if fd < 0 { return false }
    defer { close(fd) }

    let sent = withUnsafePointer(to: addr.addr) { ptr in
      ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { saPtr in
        line.withCString { cstr in
          sendto(fd, cstr, strlen(cstr), 0, saPtr, addr.len)
        }
      }
    }

    if sent < 0 {
      return false
    }
    if verbose {
      logErr("[bridge] dgram -> \(line.trimmingCharacters(in: .whitespacesAndNewlines))")
    }
    return true
  }

  private func sendStream(_ line: String) -> Bool {
    if streamFD < 0 && !connectStream() {
      return false
    }
    if writeAll(fd: streamFD, data: line) {
      if verbose {
        logErr("[bridge] stream -> \(line.trimmingCharacters(in: .whitespacesAndNewlines))")
      }
      return true
    }

    // Retry once after reconnect for broken pipe / stale fd.
    closeStream()
    guard connectStream() else { return false }
    return writeAll(fd: streamFD, data: line)
  }

  private func connectStream() -> Bool {
    guard let addr = makeAddress(path: streamPath) else { return false }
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    if fd < 0 { return false }

    var opt = 1
    _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &opt, socklen_t(MemoryLayout.size(ofValue: opt)))

    let ok = withUnsafePointer(to: addr.addr) { ptr in
      ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { saPtr in
        connect(fd, saPtr, addr.len) == 0
      }
    }
    if !ok {
      close(fd)
      return false
    }
    streamFD = fd
    return true
  }

  private func closeStream() {
    if streamFD >= 0 {
      close(streamFD)
      streamFD = -1
    }
  }

  private func writeAll(fd: Int32, data: String) -> Bool {
    let bytes = Array(data.utf8)
    var written = 0
    while written < bytes.count {
      let n = bytes.withUnsafeBytes { ptr -> Int in
        let base = ptr.baseAddress!.advanced(by: written)
        return Darwin.write(fd, base, bytes.count - written)
      }
      if n < 0 {
        if errno == EINTR { continue }
        return false
      }
      if n == 0 { return false }
      written += n
    }
    return true
  }
}

private struct UnixAddress {
  var addr: sockaddr_un
  var len: socklen_t
}

private func makeAddress(path: String) -> UnixAddress? {
  var addr = sockaddr_un()
  addr.sun_family = sa_family_t(AF_UNIX)

  let maxLen = MemoryLayout.size(ofValue: addr.sun_path)
  let bytes = path.utf8CString
  if bytes.count > maxLen || bytes.isEmpty {
    return nil
  }

  path.withCString { cstr in
    withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
      ptr.withMemoryRebound(to: CChar.self, capacity: maxLen) { buf in
        strncpy(buf, cstr, maxLen - 1)
        buf[maxLen - 1] = 0
      }
    }
  }

#if os(macOS)
  // Use full sockaddr_un length for robust connect/sendto behavior across Darwin variants.
  // Some environments are strict about sockaddr length calculations and fail fast with EINVAL.
  let len = socklen_t(MemoryLayout<sockaddr_un>.size)
  addr.sun_len = UInt8(min(Int(len), Int(UInt8.max)))
#else
  let len = socklen_t(MemoryLayout<sockaddr_un>.size)
#endif
  return UnixAddress(addr: addr, len: len)
}

private func expandPath(_ raw: String) -> String {
  (raw as NSString).expandingTildeInPath
}

private func parseConfig(arguments: [String]) -> BridgeConfig {
  var receiverSocketPath = BridgeConfig.default.receiverSocketPath
  var seqStreamSocketPath = BridgeConfig.default.seqStreamSocketPath
  var seqDgramSocketPath = BridgeConfig.default.seqDgramSocketPath
  var preferDgram = BridgeConfig.default.preferDgram
  var verbose = BridgeConfig.default.verbose
  var highPriority = BridgeConfig.default.highPriority
  var i = 0
  while i < arguments.count {
    let arg = arguments[i]
    switch arg {
    case "--receiver-socket":
      i += 1
      if i < arguments.count { receiverSocketPath = arguments[i] }
    case "--seq-stream-socket":
      i += 1
      if i < arguments.count { seqStreamSocketPath = arguments[i] }
    case "--seq-dgram-socket":
      i += 1
      if i < arguments.count { seqDgramSocketPath = arguments[i] }
    case "--prefer-stream":
      preferDgram = false
    case "--normal-priority":
      highPriority = false
    case "--verbose":
      verbose = true
    default:
      break
    }
    i += 1
  }

  let receiverEnv = ProcessInfo.processInfo.environment["SEQ_USER_COMMAND_SOCKET_PATH"]
  let streamEnv = ProcessInfo.processInfo.environment["SEQ_SOCKET_PATH"]
  let dgramEnv = ProcessInfo.processInfo.environment["SEQ_DGRAM_SOCKET_PATH"]
  let verboseEnv = ProcessInfo.processInfo.environment["SEQ_BRIDGE_VERBOSE"] == "1"
  let highPriorityEnv = ProcessInfo.processInfo.environment["SEQ_BRIDGE_HIGH_PRIORITY"]
  if let highPriorityEnv, !highPriorityEnv.isEmpty {
    highPriority = highPriorityEnv != "0"
  }

  return BridgeConfig(
    receiverSocketPath: expandPath(receiverEnv?.isEmpty == false ? receiverEnv! : receiverSocketPath),
    seqStreamSocketPath: expandPath(streamEnv?.isEmpty == false ? streamEnv! : seqStreamSocketPath),
    seqDgramSocketPath: expandPath(dgramEnv?.isEmpty == false ? dgramEnv! : seqDgramSocketPath),
    preferDgram: preferDgram,
    verbose: verbose || verboseEnv,
    highPriority: highPriority
  )
}

@main
enum SeqUserCommandBridgeMain {
  static func main() async {
    let args = Array(CommandLine.arguments.dropFirst())
    if args.contains("--help") || args.contains("-h") {
      print(
        """
        seq-user-command-bridge
          Receives Karabiner send_user_command JSON datagrams and forwards to seqd.

        Options:
          --receiver-socket <path>   Karabiner receiver socket path
          --seq-stream-socket <path> seqd stream socket path (default /tmp/seqd.sock)
          --seq-dgram-socket <path>  seqd datagram socket path (default /tmp/seqd.sock.dgram)
          --prefer-stream            Prefer stream first (default prefers dgram)
          --normal-priority          Disable userInteractive scheduling hint
          --verbose                  Print forwarded commands

        Env overrides:
          SEQ_USER_COMMAND_SOCKET_PATH
          SEQ_SOCKET_PATH
          SEQ_DGRAM_SOCKET_PATH
          SEQ_BRIDGE_HIGH_PRIORITY=0|1 (default 1)
          SEQ_BRIDGE_VERBOSE=1
        """
      )
      return
    }

    let cfg = parseConfig(arguments: args)
    let priorityGuard = RuntimePriorityGuard(enabled: cfg.highPriority)
    defer {
      priorityGuard.close()
    }
    let forwarder = SeqForwarder(
      streamPath: cfg.seqStreamSocketPath,
      dgramPath: cfg.seqDgramSocketPath,
      preferDgram: cfg.preferDgram,
      verbose: cfg.verbose
    )

    let receiver = KEUserCommandReceiver(
      path: cfg.receiverSocketPath,
      onJSON: { json in
        guard let command = CommandParser.parse(from: json) else {
          fputs("[bridge] ignored payload (unrecognized JSON shape)\n", stderr)
          return
        }
        let receivedAtMonotonic = monotonicMicroseconds()
        let receivedAtRealtime = realtimeMicroseconds()
        let commandForLog = compactCommand(command)
        Task(priority: .high) {
          let result = await forwarder.send(command: command)
          let totalMicroseconds = monotonicMicroseconds() - receivedAtMonotonic
          if cfg.verbose {
            logErr(
              "[bridge][latency] recv_rt_us=\(receivedAtRealtime) transport=\(result.transport) " +
                "forward_us=\(result.elapsedMicroseconds) total_us=\(totalMicroseconds) " +
                "ok=\(result.ok ? 1 : 0) command=\"\(commandForLog)\""
            )
          }
          if !result.ok {
            fputs("[bridge] failed forwarding command: \(command)\n", stderr)
          }
        }
      },
      onError: { error in
        fputs("[bridge] receiver error: \(error)\n", stderr)
      }
    )

    do {
      try await receiver.start()
      logErr("[bridge] listening: \(cfg.receiverSocketPath)")
      logErr("[bridge] seq stream: \(cfg.seqStreamSocketPath)")
      logErr("[bridge] seq dgram:  \(cfg.seqDgramSocketPath)")
      logErr("[bridge] priority:   \(cfg.highPriority ? "userInteractive" : "normal")")
      while true {
        do {
          try await Task.sleep(nanoseconds: 3_600_000_000_000)
        } catch {
          break
        }
      }
      await receiver.stop()
      await forwarder.shutdown()
    } catch {
      logErr("[bridge] failed to start: \(error)")
      exit(1)
    }
  }
}
