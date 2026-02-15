import Combine
import KarabinerElementsUserCommandReceiver
import SwiftUI

@MainActor
final class ServerViewModel: ObservableObject {
  @Published var socketPath: String
  @Published var isRunning = false
  @Published var logs: [String] = []

  private var server: KEUserCommandReceiver?
  init() {
    socketPath = KEUserCommandReceiver.defaultSocketPath()
  }

  deinit {
    // Deinit runs in a nonisolated context; hop to the main actor to call actor-isolated async API.
    let server = self.server
    Task { @MainActor in
      if let server {
        await server.stop()
      }
    }
  }

  func start() async {
    guard !isRunning else { return }

    let server = KEUserCommandReceiver(
      path: socketPath,
      onJSON: { [weak self] json in
        // Convert to a Sendable representation before hopping actors
        let message = "JSON: \(String(describing: json))"
        Task { @MainActor in
          self?.appendLog(message)
        }
      },
      onError: { [weak self] error in
        // Convert to a Sendable representation before hopping actors
        let message = "Error: \(String(describing: error))"
        Task { @MainActor in
          self?.appendLog(message)
        }
      }
    )

    self.server = server
    isRunning = true
    appendLog("Start listening: \(socketPath)")

    do {
      try await server.start()
    } catch {
      appendLog("Start failed: \(error)")
      isRunning = false
    }
  }

  func stop() async {
    guard isRunning else { return }
    if let server {
      await server.stop()
    }
    self.server = nil
    isRunning = false
    appendLog("Stopped")
  }

  func clearLogs() {
    logs.removeAll()
  }

  private func appendLog(_ message: String) {
    let timestamp = Self.timestamp()
    DispatchQueue.main.async {
      self.logs.append("[\(timestamp)] \(message)")
      if self.logs.count > 500 {
        self.logs.removeFirst(self.logs.count - 500)
      }
    }
  }

  private static func timestamp() -> String {
    let formatter = DateFormatter()
    formatter.dateFormat = "HH:mm:ss"
    return formatter.string(from: Date())
  }
}

struct ContentView: View {
  @StateObject private var viewModel = ServerViewModel()

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("KarabinerElementsUserCommandReceiver")
        .font(.title2)

      HStack(spacing: 8) {
        TextField("Socket path", text: $viewModel.socketPath)
          .textFieldStyle(.roundedBorder)
          .disabled(viewModel.isRunning)

        Button("Start") {
          Task { await viewModel.start() }
        }
        .disabled(viewModel.isRunning)

        Button("Stop") {
          Task { await viewModel.stop() }
        }
        .disabled(!viewModel.isRunning)
      }

      Divider()

      HStack {
        Text("Logs")
        Spacer()

        Button("Clear") { viewModel.clearLogs() }
      }

      ScrollView {
        LazyVStack(alignment: .leading, spacing: 4) {
          ForEach(viewModel.logs.indices, id: \.self) { index in
            Text(viewModel.logs[index])
              .font(.system(.body, design: .monospaced))
              .frame(maxWidth: .infinity, alignment: .leading)
          }
        }
      }
      .frame(minHeight: 200)
      .border(Color.secondary.opacity(0.3))
    }
    .padding(16)
    .frame(minWidth: 760, minHeight: 420)
  }
}

#Preview {
  ContentView()
}
