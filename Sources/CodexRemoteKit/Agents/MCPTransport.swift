import Foundation

/// JSON-RPC 2.0 over stdio, which is how Codex and Claude Code launch an MCP server.
///
/// One JSON object per line. Nothing else may be written to stdout — a stray `print` puts a
/// non-JSON line into the stream and the client drops the connection — so every diagnostic
/// here goes to stderr.
public struct MCPTransport {
    private let server: MCPServer
    private let name: String
    private let version: String

    public init(server: MCPServer, name: String = "codex-remote", version: String = CodexRemoteVersion.current) {
        self.server = server
        self.name = name
        self.version = version
    }

    public func serve() async {
        setvbuf(stdout, nil, _IOLBF, 0)
        log("Codex Remote MCP server ready.")

        while let line = readLine(strippingNewline: true) {
            guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
            guard let data = line.data(using: .utf8),
                  let message = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                log("Ignoring a line that is not JSON.")
                continue
            }
            guard let method = message["method"] as? String else { continue }
            let id = message["id"]
            let params = message["params"] as? [String: Any] ?? [:]

            // A notification has no id and takes no reply — answering one is a protocol
            // error, not a harmless extra.
            guard let id else {
                if method == "notifications/initialized" { log("Client ready.") }
                continue
            }

            switch method {
            case "initialize":
                reply(id: id, result: [
                    "protocolVersion": MCPServer.protocolVersion,
                    "capabilities": ["tools": [:] as [String: Any]],
                    "serverInfo": ["name": name, "version": version],
                ])

            case "tools/list":
                reply(id: id, result: ["tools": MCPServer.tools().map { tool in
                    [
                        "name": tool.name,
                        "description": tool.description,
                        "inputSchema": tool.schema,
                    ] as [String: Any]
                }])

            case "tools/call":
                let toolName = params["name"] as? String ?? ""
                let arguments = params["arguments"] as? [String: Any] ?? [:]
                let outcome = await server.call(toolName, arguments: arguments)
                // A failed tool is reported through isError, not a JSON-RPC error: the
                // agent is meant to read it and adjust, not treat it as a broken server.
                reply(id: id, result: [
                    "content": [["type": "text", "text": outcome.text]],
                    "isError": outcome.isError,
                ])

            case "ping":
                reply(id: id, result: [:])

            default:
                reply(id: id, error: -32601, message: "Unknown method `\(method)`.")
            }
        }
        log("Client disconnected.")
    }

    // MARK: - Framing

    private func reply(id: Any, result: [String: Any]) {
        send(["jsonrpc": "2.0", "id": id, "result": result])
    }

    private func reply(id: Any, error code: Int, message: String) {
        send(["jsonrpc": "2.0", "id": id, "error": ["code": code, "message": message]])
    }

    private func send(_ object: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.withoutEscapingSlashes]),
              let text = String(data: data, encoding: .utf8) else {
            log("Could not encode a reply.")
            return
        }
        print(text)
    }

    private func log(_ message: String) {
        FileHandle.standardError.write(Data("codex-remote mcp: \(message)\n".utf8))
    }
}
