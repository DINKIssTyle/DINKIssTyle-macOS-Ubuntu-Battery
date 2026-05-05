import AppKit
import Foundation
import Network
import Security
import ServiceManagement
import SwiftUI

@MainActor
final class AppState: ObservableObject {
    @Published var port: UInt16
    @Published var colorIcon: Bool
    @Published var showPercent: Bool
    @Published var battery: BatteryPayload?
    @Published var serverStatus = "Starting"
    @Published var apiKey: String
    @Published var launchAtLogin: Bool
    @Published var launchAtLoginStatus: String

    private var server: BatteryHTTPServer?
    private var lastReceivedTime: Date?
    private var measuredInterval: TimeInterval?
    private var timeoutTask: Task<Void, Never>?

    init() {
        let defaults = UserDefaults.standard
        let savedPort = defaults.integer(forKey: "receivePort")
        port = savedPort > 0 ? UInt16(savedPort) : 8787
        colorIcon = defaults.object(forKey: "colorIcon") as? Bool ?? false
        showPercent = defaults.object(forKey: "showPercent") as? Bool ?? true
        let storedAPIKey = defaults.string(forKey: "apiKey") ?? Self.generateAPIKey()
        apiKey = storedAPIKey
        launchAtLogin = Self.isLaunchAtLoginEnabled
        launchAtLoginStatus = Self.launchAtLoginDescription
        defaults.set(storedAPIKey, forKey: "apiKey")
        startServer()
    }

    var menuBarTitle: String {
        guard let battery else {
            return ""
        }
        return showPercent ? "\(battery.percent)%" : ""
    }

    var isCharging: Bool {
        guard let battery else {
            return false
        }

        let normalizedStatus = battery.status.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return battery.isCharging == true || normalizedStatus == "charging" || normalizedStatus == "full"
    }

    var batteryLevelSymbol: String {
        guard let battery else {
            return "circle.dotted"
        }

        if isCharging {
            return "battery.100percent.bolt"
        }

        switch battery.percent {
        case 0...10:
            return "battery.0percent"
        case 11...35:
            return "battery.25percent"
        case 36...75:
            return "battery.50percent"
        default:
            return "battery.100percent"
        }
    }

    var batteryIconColor: NSColor? {
        guard colorIcon, let battery else {
            return nil
        }

        if battery.percent < 10 {
            return NSColor(red: 251 / 255, green: 20 / 255, blue: 0 / 255, alpha: 1)
        }

        if battery.percent < 20 {
            return NSColor(red: 254 / 255, green: 204 / 255, blue: 6 / 255, alpha: 1)
        }

        return NSColor(red: 54 / 255, green: 199 / 255, blue: 91 / 255, alpha: 1)
    }

    var detailText: String {
        guard let battery else {
            return lastReceivedTime == nil ? "No battery data received yet." : "Idle (Connection lost)"
        }

        var parts = [battery.host, "\(battery.percent)%", battery.status]
        if let isCharging = battery.isCharging {
            parts.append(isCharging ? "charging" : "not charging")
        }
        return parts.joined(separator: " | ")
    }

    func startServer() {
        server?.stop()
        timeoutTask?.cancel()
        battery = nil
        lastReceivedTime = nil
        measuredInterval = nil

        do {
            let newServer = try BatteryHTTPServer(port: port, apiKey: apiKey) { [weak self] payload in
                Task { @MainActor in
                    self?.handleIncomingPayload(payload)
                }
            }
            try newServer.start()
            server = newServer
            serverStatus = "Listening on :\(port)"
        } catch {
            serverStatus = "Server error: \(error.localizedDescription)"
        }
    }

    private func handleIncomingPayload(_ payload: BatteryPayload) {
        let now = Date()
        if let last = lastReceivedTime {
            let interval = now.timeIntervalSince(last)
            if let existing = measuredInterval {
                // Smooth the interval measurement to avoid jitter
                measuredInterval = existing * 0.8 + interval * 0.2
            } else {
                measuredInterval = interval
            }
        }
        lastReceivedTime = now
        battery = payload
        serverStatus = "Listening on :\(port)"

        timeoutTask?.cancel()
        // Timeout if no data for 3.5x the measured interval, with a minimum of 15 seconds
        let timeout = max((measuredInterval ?? 5) * 3.5, 15)

        timeoutTask = Task {
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            if !Task.isCancelled {
                self.battery = nil
            }
        }
    }

    func updatePort(_ newPort: UInt16) {
        port = newPort
        UserDefaults.standard.set(Int(newPort), forKey: "receivePort")
        startServer()
    }

    func setShowPercent(_ enabled: Bool) {
        showPercent = enabled
        UserDefaults.standard.set(enabled, forKey: "showPercent")
    }

    func setColorIcon(_ enabled: Bool) {
        colorIcon = enabled
        UserDefaults.standard.set(enabled, forKey: "colorIcon")
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        guard Self.isRunningFromAppBundle else {
            launchAtLogin = false
            launchAtLoginStatus = "Available in the app bundle build"
            return
        }

        do {
            if enabled {
                if SMAppService.mainApp.status != .enabled {
                    try SMAppService.mainApp.register()
                }
            } else if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            launchAtLoginStatus = "Login item error: \(error.localizedDescription)"
        }

        refreshLaunchAtLogin()
    }

    func refreshLaunchAtLogin() {
        launchAtLogin = Self.isLaunchAtLoginEnabled
        launchAtLoginStatus = Self.launchAtLoginDescription
    }

    func copyAPIKey() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(apiKey, forType: .string)
    }

    func regenerateAPIKey() {
        apiKey = Self.generateAPIKey()
        UserDefaults.standard.set(apiKey, forKey: "apiKey")
        startServer()
    }

    private static func generateAPIKey() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        if status == errSecSuccess {
            return bytes.map { String(format: "%02x", $0) }.joined()
        }
        return UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
            + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    }

    private static var isRunningFromAppBundle: Bool {
        Bundle.main.bundleURL.pathExtension == "app"
    }

    private static var isLaunchAtLoginEnabled: Bool {
        isRunningFromAppBundle && SMAppService.mainApp.status == .enabled
    }

    private static var launchAtLoginDescription: String {
        guard isRunningFromAppBundle else {
            return "Available in the app bundle build"
        }

        switch SMAppService.mainApp.status {
        case .enabled:
            return "Start at login is enabled"
        case .notRegistered:
            return "Start at login is disabled"
        case .requiresApproval:
            return "Approve in System Settings > Login Items"
        case .notFound:
            return "Login item not found"
        @unknown default:
            return "Unknown login item status"
        }
    }
}

struct BatteryPayload: Codable, Sendable {
    let host: String
    let percent: Int
    let status: String
    let isCharging: Bool?
    let timestamp: Int?

    enum CodingKeys: String, CodingKey {
        case host
        case percent
        case status
        case isCharging = "is_charging"
        case timestamp
    }
}

final class BatteryHTTPServer: @unchecked Sendable {
    private let port: UInt16
    private let apiKey: String
    private let onBattery: @Sendable (BatteryPayload) -> Void
    private var listener: NWListener?

    init(port: UInt16, apiKey: String, onBattery: @escaping @Sendable (BatteryPayload) -> Void) throws {
        self.port = port
        self.apiKey = apiKey
        self.onBattery = onBattery
    }

    func start() throws {
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        let listener = try NWListener(using: parameters, on: NWEndpoint.Port(rawValue: port)!)
        listener.newConnectionHandler = { [weak self] connection in
            self?.handle(connection)
        }
        listener.start(queue: .global(qos: .userInitiated))
        self.listener = listener
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: .global(qos: .userInitiated))
        receive(from: connection, buffer: Data())
    }

    private func receive(from connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self else { return }

            var nextBuffer = buffer
            if let data {
                nextBuffer.append(data)
            }

            if error != nil || isComplete || self.hasCompleteHTTPRequest(nextBuffer) {
                self.respond(to: connection, request: nextBuffer)
                return
            }

            self.receive(from: connection, buffer: nextBuffer)
        }
    }

    private func hasCompleteHTTPRequest(_ data: Data) -> Bool {
        guard let headerRange = data.range(of: Data("\r\n\r\n".utf8)) else {
            return false
        }

        let headerData = data[..<headerRange.lowerBound]
        let headers = String(data: headerData, encoding: .utf8) ?? ""
        let bodyStart = headerRange.upperBound
        let contentLength = headers
            .components(separatedBy: "\r\n")
            .first { $0.lowercased().hasPrefix("content-length:") }
            .flatMap { Int($0.split(separator: ":", maxSplits: 1).last?.trimmingCharacters(in: .whitespaces) ?? "") } ?? 0
        return data.count >= bodyStart + contentLength
    }

    private func respond(to connection: NWConnection, request data: Data) {
        let result = parseBatteryPayload(from: data)
        let statusLine: String
        let body: String

        switch result {
        case .success(let payload):
            onBattery(payload)
            statusLine = "HTTP/1.1 204 No Content"
            body = ""
        case .failure(ServerError.unauthorized):
            statusLine = "HTTP/1.1 401 Unauthorized"
            body = "Invalid or missing API key.\n"
        case .failure(let error):
            statusLine = "HTTP/1.1 400 Bad Request"
            body = "\(error.localizedDescription)\n"
        }

        let response = """
        \(statusLine)\r
        Connection: close\r
        Content-Length: \(body.utf8.count)\r
        Content-Type: text/plain; charset=utf-8\r
        \r
        \(body)
        """

        connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    private func parseBatteryPayload(from data: Data) -> Result<BatteryPayload, Error> {
        guard let headerRange = data.range(of: Data("\r\n\r\n".utf8)),
              let headers = String(data: data[..<headerRange.lowerBound], encoding: .utf8) else {
            return .failure(ServerError.invalidRequest)
        }

        let requestLine = headers.components(separatedBy: "\r\n").first ?? ""
        guard requestLine.hasPrefix("POST /battery ") else {
            return .failure(ServerError.unsupportedRoute)
        }

        let headerFields = parseHeaders(headers)
        guard isAuthorized(headerFields) else {
            return .failure(ServerError.unauthorized)
        }

        let contentLength = headers
            .components(separatedBy: "\r\n")
            .first { $0.lowercased().hasPrefix("content-length:") }
            .flatMap { Int($0.split(separator: ":", maxSplits: 1).last?.trimmingCharacters(in: .whitespaces) ?? "") } ?? 0
        let bodyStart = headerRange.upperBound
        let bodyEnd = min(data.count, bodyStart + contentLength)
        let body = data[bodyStart..<bodyEnd]

        do {
            let payload = try JSONDecoder().decode(BatteryPayload.self, from: body)
            guard (0...100).contains(payload.percent) else {
                return .failure(ServerError.invalidPercent)
            }
            return .success(payload)
        } catch {
            return .failure(error)
        }
    }

    private func parseHeaders(_ headers: String) -> [String: String] {
        var fields: [String: String] = [:]
        for line in headers.components(separatedBy: "\r\n").dropFirst() {
            let parts = line.split(separator: ":", maxSplits: 1)
            guard parts.count == 2 else {
                continue
            }
            let name = parts[0].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let value = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
            fields[name] = value
        }
        return fields
    }

    private func isAuthorized(_ headers: [String: String]) -> Bool {
        if headers["x-api-key"] == apiKey {
            return true
        }

        guard let authorization = headers["authorization"] else {
            return false
        }

        let parts = authorization.split(separator: " ", maxSplits: 1)
        guard parts.count == 2, parts[0].lowercased() == "bearer" else {
            return false
        }
        return String(parts[1]) == apiKey
    }

    enum ServerError: LocalizedError {
        case invalidRequest
        case unsupportedRoute
        case invalidPercent
        case unauthorized

        var errorDescription: String? {
            switch self {
            case .invalidRequest:
                return "Invalid HTTP request."
            case .unsupportedRoute:
                return "Expected POST /battery."
            case .invalidPercent:
                return "Battery percent must be between 0 and 100."
            case .unauthorized:
                return "Invalid or missing API key."
            }
        }
    }
}

struct MenuContent: View {
    @ObservedObject var state: AppState
    @State private var portText = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(state.detailText)
                .font(.headline)
            Text(state.serverStatus)
                .font(.caption)
                .foregroundStyle(.secondary)

            Divider()

            HStack {
                Text("API Key")
                Text(maskedAPIKey)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                Spacer()
            }

            HStack {
                Button("Copy API Key") {
                    state.copyAPIKey()
                }

                Button("Regenerate") {
                    state.regenerateAPIKey()
                }
            }

            Divider()

            HStack {
                Text("Port")
                TextField("8787", text: $portText)
                    .frame(width: 72)
                    .onSubmit(applyPort)
                Button("Apply", action: applyPort)
            }

            Toggle("Color icon", isOn: Binding(
                get: { state.colorIcon },
                set: { state.setColorIcon($0) }
            ))

            Toggle("Show percentage", isOn: Binding(
                get: { state.showPercent },
                set: { state.setShowPercent($0) }
            ))

            Toggle("Start at login", isOn: Binding(
                get: { state.launchAtLogin },
                set: { state.setLaunchAtLogin($0) }
            ))

            Text(state.launchAtLoginStatus)
                .font(.caption)
                .foregroundStyle(.secondary)

            Divider()

            Button("Quit") {
                NSApplication.shared.terminate(nil)
            }
            .keyboardShortcut("q")
        }
        .padding()
        .frame(width: 300)
        .onAppear {
            portText = String(state.port)
            state.refreshLaunchAtLogin()
        }
    }

    private func applyPort() {
        guard let value = UInt16(portText), value > 0 else {
            portText = String(state.port)
            return
        }
        state.updatePort(value)
    }

    private var maskedAPIKey: String {
        guard state.apiKey.count > 12 else {
            return "********"
        }
        return "\(state.apiKey.prefix(6))...\(state.apiKey.suffix(6))"
    }
}

struct MenuBarLabel: View {
    @ObservedObject var state: AppState

    var body: some View {
        HStack(spacing: 4) {
            if let color = state.batteryIconColor {
                Image(nsImage: Self.tintedSymbolImage(named: state.batteryLevelSymbol, color: color))
                    .renderingMode(.original)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 18, height: 14)
            } else {
                Image(systemName: state.batteryLevelSymbol)
                    .font(.system(size: 14, weight: .semibold))
            }

            Text(state.menuBarTitle)
                .font(.system(size: 13, weight: .medium))
                .monospacedDigit()
        }
        .lineLimit(1)
        .fixedSize()
    }

    private static func tintedSymbolImage(named symbolName: String, color: NSColor) -> NSImage {
        let configuration = NSImage.SymbolConfiguration(pointSize: 14, weight: .semibold)
        guard let symbol = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration) else {
            return NSImage(size: NSSize(width: 18, height: 14))
        }

        let image = NSImage(size: symbol.size)
        image.lockFocus()
        color.setFill()
        NSRect(origin: .zero, size: symbol.size).fill()
        symbol.draw(
            in: NSRect(origin: .zero, size: symbol.size),
            from: NSRect(origin: .zero, size: symbol.size),
            operation: .destinationIn,
            fraction: 1
        )
        image.unlockFocus()
        image.isTemplate = false
        return image
    }
}

@main
struct LinuxBatteryMenuBarApp: App {
    @StateObject private var state = AppState()

    var body: some Scene {
        MenuBarExtra {
            MenuContent(state: state)
        } label: {
            MenuBarLabel(state: state)
        }
        .menuBarExtraStyle(.window)
    }
}
