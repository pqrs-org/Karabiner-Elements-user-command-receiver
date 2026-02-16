import Darwin
import Foundation

private struct ProcessSample {
  let cpu: Double
  let mem: Double
  let command: String
}

private struct Options {
  var top = 20
  var load1Max = 3.0
  var windowServerMax = 25.0
  var procCpuMax = 35.0
  var maxBusyProcesses = 3
  var busyCpuThreshold = 20.0
  var topCpuSumMax = 120.0
  var json = false
}

private struct Snapshot {
  let uptimeLine: String
  let systemUptimeSeconds: TimeInterval
  let load: (Double, Double, Double)
  let processes: [ProcessSample]
}

private func printHelp() {
  print(
    """
    kar-uc-system-check
      Evaluate whether this Mac is in a clean state for latency testing.

    Usage:
      kar-uc-system-check [options]

    Options:
      --top <n>                    Number of top CPU processes to print (default: 20)
      --load1-max <value>          Max allowed 1-minute load avg (default: 3.0)
      --windowserver-max <value>   Max allowed WindowServer CPU% (default: 25.0)
      --proc-cpu-max <value>       Max allowed top process CPU% (default: 35.0)
      --max-busy-procs <n>         Max allowed busy processes above threshold (default: 3)
      --busy-cpu-threshold <value> Busy threshold CPU% (default: 20.0)
      --top-cpu-sum-max <value>    Max allowed sum CPU% of top 5 processes (default: 120.0)
      --json                       Emit JSON output
      -h, --help                   Show this help

    Exit codes:
      0 = READY
      2 = NOT_READY
      64 = invalid arguments
    """
  )
}

private func runCommand(_ executable: String, _ arguments: [String]) throws -> (Int32, String, String) {
  let process = Process()
  process.executableURL = URL(fileURLWithPath: executable)
  process.arguments = arguments

  // Use one combined pipe and drain it before waitUntilExit.
  // This avoids deadlock when command output is large (e.g. `ps -Ao ...`).
  let outputPipe = Pipe()
  process.standardOutput = outputPipe
  process.standardError = outputPipe

  try process.run()
  let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
  process.waitUntilExit()

  let output = String(decoding: outputData, as: UTF8.self)
  if process.terminationStatus == 0 {
    return (process.terminationStatus, output, "")
  }
  return (process.terminationStatus, "", output)
}

private func parseProcessTable(_ text: String) -> [ProcessSample] {
  let lines = text.split(separator: "\n", omittingEmptySubsequences: true)
  if lines.isEmpty {
    return []
  }

  var rows: [ProcessSample] = []
  rows.reserveCapacity(max(0, lines.count - 1))

  for line in lines.dropFirst() {
    let parts = line.split(maxSplits: 2,
                           omittingEmptySubsequences: true,
                           whereSeparator: { $0 == " " || $0 == "\t" })
    if parts.count < 3 {
      continue
    }
    guard let cpu = Double(parts[0]), let mem = Double(parts[1]) else {
      continue
    }
    let command = String(parts[2])
    rows.append(ProcessSample(cpu: cpu, mem: mem, command: command))
  }

  rows.sort { lhs, rhs in
    if lhs.cpu == rhs.cpu {
      return lhs.command < rhs.command
    }
    return lhs.cpu > rhs.cpu
  }
  return rows
}

private func loadAverages() throws -> (Double, Double, Double) {
  var avg = loadavg()
  var size = MemoryLayout<loadavg>.size

  let rc = withUnsafeMutablePointer(to: &avg) { ptr -> Int32 in
    ptr.withMemoryRebound(to: CChar.self, capacity: size) { raw in
      sysctlbyname("vm.loadavg", raw, &size, nil, 0)
    }
  }
  if rc != 0 {
    throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
  }

  let scale = Double(avg.fscale)
  return (
    Double(avg.ldavg.0) / scale,
    Double(avg.ldavg.1) / scale,
    Double(avg.ldavg.2) / scale
  )
}

private func takeSnapshot() throws -> Snapshot {
  let (uptimeCode, uptimeOut, uptimeErr) = try runCommand("/usr/bin/uptime", [])
  guard uptimeCode == 0 else {
    throw NSError(domain: "kar-uc-system-check", code: Int(uptimeCode), userInfo: [
      NSLocalizedDescriptionKey: "uptime failed: \(uptimeErr)"
    ])
  }

  let (psCode, psOut, psErr) = try runCommand("/bin/ps", ["-Ao", "pcpu,pmem,comm"])
  guard psCode == 0 else {
    throw NSError(domain: "kar-uc-system-check", code: Int(psCode), userInfo: [
      NSLocalizedDescriptionKey: "ps failed: \(psErr)"
    ])
  }

  return Snapshot(
    uptimeLine: uptimeOut.trimmingCharacters(in: .whitespacesAndNewlines),
    systemUptimeSeconds: ProcessInfo.processInfo.systemUptime,
    load: try loadAverages(),
    processes: parseProcessTable(psOut)
  )
}

private func isIgnoredProcess(_ command: String) -> Bool {
  if command.contains("kar-uc-system-check") {
    return true
  }
  return command == "ps"
}

private func evaluate(_ snapshot: Snapshot, _ options: Options) -> (Bool, [String], [String]) {
  var reasons: [String] = []
  var notes: [String] = []

  let load1 = snapshot.load.0
  if load1 > options.load1Max {
    reasons.append(
      String(format: "load1 %.2f > %.2f", load1, options.load1Max)
    )
  }

  let visible = snapshot.processes.filter { !isIgnoredProcess($0.command) }
  if let top = visible.first, top.cpu > options.procCpuMax {
    reasons.append(
      String(format: "top process %.1f%% > %.1f%% (%@)", top.cpu, options.procCpuMax, top.command)
    )
  }

  if let ws = visible.first(where: { $0.command.contains("WindowServer") }),
     ws.cpu > options.windowServerMax
  {
    reasons.append(
      String(format: "WindowServer %.1f%% > %.1f%%", ws.cpu, options.windowServerMax)
    )
  }

  let busy = visible.filter { $0.cpu >= options.busyCpuThreshold }
  if busy.count > options.maxBusyProcesses {
    reasons.append(
      "busy processes \(busy.count) > \(options.maxBusyProcesses) (>= \(String(format: "%.1f", options.busyCpuThreshold))% CPU)"
    )
  }

  let top5Sum = visible.prefix(5).reduce(0.0) { $0 + $1.cpu }
  if top5Sum > options.topCpuSumMax {
    reasons.append(
      String(format: "top5 cpu sum %.1f%% > %.1f%%", top5Sum, options.topCpuSumMax)
    )
  }

  if snapshot.systemUptimeSeconds < 600 {
    notes.append("system uptime < 10m (post-reboot indexing may still be active)")
  }

  return (reasons.isEmpty, reasons, notes)
}

private func parseOptions() -> Options {
  var options = Options()
  var i = 1
  let args = CommandLine.arguments

  func needValue(_ flag: String) -> String {
    guard i + 1 < args.count else {
      fputs("missing value for \(flag)\n", stderr)
      exit(64)
    }
    i += 1
    return args[i]
  }

  while i < args.count {
    let arg = args[i]
    switch arg {
    case "-h", "--help":
      printHelp()
      exit(0)
    case "--json":
      options.json = true
    case "--top":
      options.top = Int(needValue(arg)) ?? { fputs("invalid --top\n", stderr); exit(64) }()
    case "--load1-max":
      options.load1Max = Double(needValue(arg)) ?? { fputs("invalid --load1-max\n", stderr); exit(64) }()
    case "--windowserver-max":
      options.windowServerMax = Double(needValue(arg)) ?? { fputs("invalid --windowserver-max\n", stderr); exit(64) }()
    case "--proc-cpu-max":
      options.procCpuMax = Double(needValue(arg)) ?? { fputs("invalid --proc-cpu-max\n", stderr); exit(64) }()
    case "--max-busy-procs":
      options.maxBusyProcesses = Int(needValue(arg)) ?? { fputs("invalid --max-busy-procs\n", stderr); exit(64) }()
    case "--busy-cpu-threshold":
      options.busyCpuThreshold = Double(needValue(arg)) ?? { fputs("invalid --busy-cpu-threshold\n", stderr); exit(64) }()
    case "--top-cpu-sum-max":
      options.topCpuSumMax = Double(needValue(arg)) ?? { fputs("invalid --top-cpu-sum-max\n", stderr); exit(64) }()
    default:
      fputs("unknown argument: \(arg)\n", stderr)
      exit(64)
    }
    i += 1
  }

  return options
}

private func emitText(snapshot: Snapshot, options: Options, ready: Bool, reasons: [String], notes: [String]) {
  let verdict = ready ? "READY_FOR_CLEAN_TEST" : "NOT_READY_FOR_CLEAN_TEST"
  print("kar-uc-system-check")
  print("verdict: \(verdict)")
  print(
    String(
      format: "loadavg: %.2f %.2f %.2f (load1 max %.2f)",
      snapshot.load.0,
      snapshot.load.1,
      snapshot.load.2,
      options.load1Max
    )
  )
  print(
    String(
      format: "system_uptime_s: %.0f",
      snapshot.systemUptimeSeconds
    )
  )
  print("uptime: \(snapshot.uptimeLine)")

  if !reasons.isEmpty {
    print("reasons:")
    for reason in reasons {
      print("- \(reason)")
    }
  }

  if !notes.isEmpty {
    print("notes:")
    for note in notes {
      print("- \(note)")
    }
  }

  print("top_processes:")
  let shown = snapshot.processes.prefix(options.top)
  for (idx, proc) in shown.enumerated() {
    print(
      String(
        format: "%2d. %6.1f%% cpu  %5.1f%% mem  %@",
        idx + 1,
        proc.cpu,
        proc.mem,
        proc.command
      )
    )
  }
}

private func emitJSON(snapshot: Snapshot, options: Options, ready: Bool, reasons: [String], notes: [String]) {
  let top = snapshot.processes.prefix(options.top).map { p in
    [
      "cpu": p.cpu,
      "mem": p.mem,
      "command": p.command
    ] as [String: Any]
  }

  let payload: [String: Any] = [
    "ready": ready,
    "verdict": ready ? "READY_FOR_CLEAN_TEST" : "NOT_READY_FOR_CLEAN_TEST",
    "uptime_line": snapshot.uptimeLine,
    "system_uptime_s": snapshot.systemUptimeSeconds,
    "loadavg": [
      "load1": snapshot.load.0,
      "load5": snapshot.load.1,
      "load15": snapshot.load.2,
    ],
    "thresholds": [
      "load1_max": options.load1Max,
      "windowserver_max": options.windowServerMax,
      "proc_cpu_max": options.procCpuMax,
      "max_busy_processes": options.maxBusyProcesses,
      "busy_cpu_threshold": options.busyCpuThreshold,
      "top_cpu_sum_max": options.topCpuSumMax
    ],
    "reasons": reasons,
    "notes": notes,
    "top_processes": top
  ]

  if let data = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted]),
     let text = String(data: data, encoding: .utf8)
  {
    print(text)
  } else {
    fputs("failed to encode json output\n", stderr)
    exit(2)
  }
}

private let options = parseOptions()

do {
  let snapshot = try takeSnapshot()
  let (ready, reasons, notes) = evaluate(snapshot, options)

  if options.json {
    emitJSON(snapshot: snapshot, options: options, ready: ready, reasons: reasons, notes: notes)
  } else {
    emitText(snapshot: snapshot, options: options, ready: ready, reasons: reasons, notes: notes)
  }

  exit(ready ? 0 : 2)
} catch {
  fputs("kar-uc-system-check failed: \(error)\n", stderr)
  exit(2)
}
