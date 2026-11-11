import Foundation

/// Installs only Board's local stdio adapter. Claude keeps its own authentication.
enum BoardMCPSetup {
    struct SetupFailure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    private struct Report: Decodable {
        let ok: Bool
        let results: [ClientResult]
    }

    private struct ClientResult: Decodable {
        let client: String
        let status: String
        let message: String
    }

    /// Returns a short per-client result suitable for a native alert.
    static func connect() async throws -> String {
        guard let helper = Bundle.main.url(forResource: "setup-claude-mcp", withExtension: "py"),
              let server = Bundle.main.url(forResource: "board-mcp", withExtension: "py") else {
            throw SetupFailure(message: "Board's MCP setup is missing. Reinstall Board.")
        }
        return try await Task.detached(priority: .userInitiated) {
            try run(helper: helper, server: server)
        }.value
    }

    private static func run(helper: URL, server: URL) throws -> String {
        guard let python = pythonExecutable() else {
            throw SetupFailure(message: "Python 3 is required to connect Claude.")
        }
        let process = Process()
        let output = Pipe()
        process.executableURL = python
        process.arguments = [helper.path, "--client", "all", "--python", python.path,
                             "--server-script", server.path, "--json"]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        // Config values and Claude's output never become app messages or logs.
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            throw SetupFailure(message: "Claude setup could not start.")
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard data.count <= 16_384,
              let report = try? JSONDecoder().decode(Report.self, from: data) else {
            throw SetupFailure(message: "Claude setup could not finish. Try again after closing Claude.")
        }
        let message = report.results.map { "\($0.client): \($0.message)" }.joined(separator: "\n\n")
        guard report.ok else { throw SetupFailure(message: message) }
        return message
    }

    private static func pythonExecutable() -> URL? {
        let paths = [
            "/Library/Frameworks/Python.framework/Versions/Current/bin/python3",
            "/opt/homebrew/bin/python3", "/usr/local/bin/python3"
        ] + (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":")
            .filter { $0.hasPrefix("/") }.map { "\($0)/python3" } + ["/usr/bin/python3"]
        for path in paths where FileManager.default.isExecutableFile(atPath: path) {
            return URL(fileURLWithPath: path).resolvingSymlinksInPath()
        }
        return nil
    }
}
