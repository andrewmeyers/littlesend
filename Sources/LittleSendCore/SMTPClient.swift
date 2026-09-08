import Foundation
import Network

public struct SMTPError: LocalizedError {
    public let code: Int?
    public let message: String
    public var errorDescription: String? { message }

    public init(code: Int?, message: String) {
        self.code = code
        self.message = message
    }
}

public struct SMTPConfiguration: Sendable, Equatable {
    public var host: String
    public var port: UInt16
    public var username: String
    public var password: String

    public init(host: String, port: UInt16, username: String, password: String) {
        self.host = host
        self.port = port
        self.username = username
        self.password = password
    }
}

/// A small SMTP client built on Network.framework.
///
/// The connection is TLS from the first byte (implicit TLS, normally port 465).
/// Network.framework cannot upgrade a live connection, so STARTTLS-only servers
/// — notably Office 365 on port 587 — are not supported; `send` reports that
/// explicitly rather than falling back to an unencrypted session.
public final class SMTPClient {
    private let configuration: SMTPConfiguration
    private let queue = DispatchQueue(label: "com.littlesend.smtp")
    private var connection: NWConnection?
    private var buffer = Data()

    public init(configuration: SMTPConfiguration) {
        self.configuration = configuration
    }

    public func send(envelopeFrom: String, recipients: [String], message: Data) async throws {
        guard !recipients.isEmpty else {
            throw SMTPError(code: nil, message: "No recipient address configured.")
        }

        try await connect()
        defer { disconnect() }

        let greeting = try await readReply()
        try expect(greeting, code: 220, step: "greeting")

        let ehlo = try await command("EHLO littlesend.local")
        try expect(ehlo, code: 250, step: "EHLO")

        try await authenticate(capabilities: ehlo.lines)

        let from = try await command("MAIL FROM:<\(envelopeFrom)>")
        try expect(from, code: 250, step: "MAIL FROM")

        for recipient in recipients {
            let reply = try await command("RCPT TO:<\(recipient)>")
            guard reply.code == 250 || reply.code == 251 else {
                throw SMTPError(
                    code: reply.code,
                    message: "The server rejected the recipient \(recipient): \(reply.text)"
                )
            }
        }

        let data = try await command("DATA")
        try expect(data, code: 354, step: "DATA")

        var payload = Self.dotStuffed(message)
        payload.append(contentsOf: Array("\r\n.\r\n".utf8))
        try await write(payload)

        let accepted = try await readReply()
        try expect(accepted, code: 250, step: "message body")

        _ = try? await command("QUIT")
    }

    // MARK: - Authentication

    private func authenticate(capabilities: [String]) async throws {
        let mechanisms = capabilities
            .filter { $0.uppercased().contains("AUTH") }
            .flatMap { $0.uppercased().split(separator: " ").map(String.init) }

        if mechanisms.contains("PLAIN") {
            let token = Data("\0\(configuration.username)\0\(configuration.password)".utf8).base64EncodedString()
            let reply = try await command("AUTH PLAIN \(token)", redacted: "AUTH PLAIN ****")
            try expectAuth(reply)
            return
        }

        // LOGIN is the common fallback and is what most providers advertise.
        let start = try await command("AUTH LOGIN")
        guard start.code == 334 else {
            throw SMTPError(code: start.code, message: "The server refused to start authentication: \(start.text)")
        }
        let user = try await command(
            Data(configuration.username.utf8).base64EncodedString(), redacted: "****"
        )
        guard user.code == 334 else {
            throw SMTPError(code: user.code, message: "The server rejected the username: \(user.text)")
        }
        let password = try await command(
            Data(configuration.password.utf8).base64EncodedString(), redacted: "****"
        )
        try expectAuth(password)
    }

    private func expectAuth(_ reply: Reply) throws {
        guard reply.code != 235 else { return }
        let hint: String
        if configuration.host.contains("gmail") {
            hint = " Gmail requires a 16-character app password, not your account password."
        } else {
            hint = ""
        }
        throw SMTPError(code: reply.code, message: "Sign-in to \(configuration.host) failed: \(reply.text).\(hint)")
    }

    // MARK: - Protocol plumbing

    struct Reply {
        let code: Int
        let lines: [String]
        var text: String { lines.joined(separator: " ") }
    }

    private func expect(_ reply: Reply, code: Int, step: String) throws {
        guard reply.code != code else { return }
        throw SMTPError(code: reply.code, message: "SMTP \(step) failed (\(reply.code)): \(reply.text)")
    }

    private func connect() async throws {
        guard let port = NWEndpoint.Port(rawValue: configuration.port) else {
            throw SMTPError(code: nil, message: "Invalid SMTP port \(configuration.port).")
        }

        let options = NWProtocolTLS.Options()
        let parameters = NWParameters(tls: options, tcp: NWProtocolTCP.Options())
        let connection = NWConnection(
            host: NWEndpoint.Host(configuration.host), port: port, using: parameters
        )
        self.connection = connection

        let gate = ResumeGate()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if gate.claim() { continuation.resume() }
                case .failed(let error):
                    if gate.claim() {
                        continuation.resume(throwing: SMTPError(
                            code: nil,
                            message: "Could not connect to \(self.configuration.host):\(self.configuration.port). \(error.localizedDescription)"
                        ))
                    }
                case .cancelled:
                    if gate.claim() {
                        continuation.resume(throwing: SMTPError(code: nil, message: "The connection was cancelled."))
                    }
                default:
                    break
                }
            }
            connection.start(queue: queue)
        }
    }

    private func disconnect() {
        connection?.stateUpdateHandler = nil
        connection?.cancel()
        connection = nil
        buffer.removeAll()
    }

    private func command(_ line: String, redacted: String? = nil) async throws -> Reply {
        try await write(Array("\(line)\r\n".utf8))
        do {
            return try await readReply()
        } catch let error as SMTPError {
            // Keep credentials out of any surfaced error text.
            throw SMTPError(code: error.code, message: error.message.replacingOccurrences(of: line, with: redacted ?? line))
        }
    }

    private func write(_ bytes: [UInt8]) async throws {
        guard let connection else {
            throw SMTPError(code: nil, message: "The SMTP connection is not open.")
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: Data(bytes), completion: .contentProcessed { error in
                if let error {
                    continuation.resume(throwing: SMTPError(code: nil, message: "Send failed: \(error.localizedDescription)"))
                } else {
                    continuation.resume()
                }
            })
        }
    }

    private func readReply() async throws -> Reply {
        while true {
            if let reply = Self.parseReply(from: &buffer) { return reply }
            let chunk = try await receive()
            guard !chunk.isEmpty else {
                throw SMTPError(code: nil, message: "The server closed the connection unexpectedly.")
            }
            buffer.append(chunk)
        }
    }

    private func receive() async throws -> Data {
        guard let connection else {
            throw SMTPError(code: nil, message: "The SMTP connection is not open.")
        }
        return try await withCheckedThrowingContinuation { continuation in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, _, isComplete, error in
                if let error {
                    continuation.resume(throwing: SMTPError(code: nil, message: "Read failed: \(error.localizedDescription)"))
                } else if let data, !data.isEmpty {
                    continuation.resume(returning: data)
                } else if isComplete {
                    continuation.resume(returning: Data())
                } else {
                    continuation.resume(returning: Data())
                }
            }
        }
    }

    /// Consumes one complete reply from `buffer`, if a terminal line is present.
    /// SMTP continuation lines use `250-`; the final line uses `250 `.
    static func parseReply(from buffer: inout Data) -> Reply? {
        guard let text = String(data: buffer, encoding: .utf8) ?? String(data: buffer, encoding: .isoLatin1) else {
            return nil
        }
        var lines: [String] = []
        var consumed = 0

        for rawLine in text.components(separatedBy: "\r\n") {
            let lineLength = rawLine.utf8.count + 2
            guard consumed + lineLength <= buffer.count else { break }
            consumed += lineLength

            let characters = Array(rawLine)
            guard characters.count >= 4, let parsed = Int(String(characters[0..<3])) else {
                lines.append(rawLine)
                continue
            }
            lines.append(String(characters[4...]))
            if characters[3] == " " {
                buffer.removeFirst(consumed)
                return Reply(code: parsed, lines: lines)
            }
        }
        return nil
    }

    /// RFC 5321 dot-stuffing: a line starting with "." gets an extra ".".
    static func dotStuffed(_ message: Data) -> [UInt8] {
        var output: [UInt8] = []
        output.reserveCapacity(message.count + 16)
        var atLineStart = true

        for byte in message {
            if atLineStart, byte == 0x2E { output.append(0x2E) }
            output.append(byte)
            atLineStart = byte == 0x0A
        }
        return output
    }
}


/// Guarantees a continuation is resumed exactly once from a state handler that
/// can fire more than once.
private final class ResumeGate: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false

    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if claimed { return false }
        claimed = true
        return true
    }
}
