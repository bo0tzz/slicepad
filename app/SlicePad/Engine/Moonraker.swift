import Foundation

/// Uploads G-code to a Klipper machine and optionally starts the print.
///
/// A hand-rolled multipart POST rather than OrcaSlicer's own Moonraker client:
/// that one talks through libcurl and passes wxString around, and neither is in
/// this build. The protocol below is copied from its behaviour — see
/// docs/moonraker.md — not from the Moonraker documentation, which differs on one
/// point that matters.
struct Moonraker {
    /// e.g. `http://sv08.local` or `http://10.0.0.20`. Plain HTTP on a LAN.
    var host: URL
    var apiKey: String?
    var root = "gcodes"

    /// "sv08.local" is what someone types; without a scheme URL parses it as a path
    /// and every request fails for a reason that has nothing to do with the printer.
    static func address(from typed: String) -> URL? {
        let trimmed = typed.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        let withScheme = trimmed.contains("://") ? trimmed : "http://\(trimmed)"
        guard let url = URL(string: withScheme), url.host != nil else { return nil }
        return url
    }

    struct UploadResult {
        /// Path the server assigned, relative to `root`. Starting the print uses
        /// this rather than the name we sent, since the server may have changed it.
        let path: String
    }

    enum Failure: LocalizedError {
        case badResponse(status: Int, body: String)
        case unexpectedPayload

        var errorDescription: String? {
            switch self {
            case let .badResponse(status, body):
                return "The printer answered \(status). \(body.prefix(200))"
            case .unexpectedPayload:
                return "The printer's reply was not in the expected form."
            }
        }
    }

    private struct UploadResponse: Decodable {
        struct Result: Decodable {
            struct Item: Decodable { let path: String }
            let item: Item
        }
        let result: Result
    }

    func upload(_ gcode: URL, as name: String) async throws -> UploadResult {
        let boundary = "slicepad.\(UUID().uuidString)"
        var request = URLRequest(url: host.appendingPathComponent("server/files/upload"))
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)",
                         forHTTPHeaderField: "Content-Type")
        apiKey.map { request.setValue($0, forHTTPHeaderField: "X-Api-Key") }

        var body = Data()
        func field(_ name: String, _ value: String) {
            body.append("--\(boundary)\r\n")
            body.append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n")
            body.append("\(value)\r\n")
        }

        field("root", root)
        body.append("--\(boundary)\r\n")
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"\(name)\"\r\n")
        body.append("Content-Type: application/octet-stream\r\n\r\n")
        body.append(try Data(contentsOf: gcode))
        body.append("\r\n--\(boundary)--\r\n")

        let data = try await send(request, body: body)
        guard let decoded = try? JSONDecoder().decode(UploadResponse.self, from: data) else {
            throw Failure.unexpectedPayload
        }
        return UploadResult(path: decoded.result.item.path)
    }

    /// Started explicitly rather than with the upload's `print=true`, which is what
    /// Orca does: the upload reply names the path the server actually assigned, so
    /// starting separately removes any guessing about how the name was read.
    func startPrint(path: String) async throws {
        var request = URLRequest(url: host.appendingPathComponent("printer/print/start"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        apiKey.map { request.setValue($0, forHTTPHeaderField: "X-Api-Key") }
        let body = try JSONSerialization.data(withJSONObject: ["filename": path])
        _ = try await send(request, body: body)
    }

    /// Cheap check against a wrong address, so that failure reads as "cannot reach
    /// the printer" rather than as a confusing upload error.
    func reachable() async -> Bool {
        var request = URLRequest(url: host.appendingPathComponent("printer/info"))
        request.timeoutInterval = 5
        apiKey.map { request.setValue($0, forHTTPHeaderField: "X-Api-Key") }
        guard let (_, response) = try? await URLSession.shared.data(for: request) else { return false }
        return (response as? HTTPURLResponse)?.statusCode == 200
    }

    private func send(_ request: URLRequest, body: Data) async throws -> Data {
        let (data, response) = try await URLSession.shared.upload(for: request, from: body)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200 ..< 300).contains(status) else {
            throw Failure.badResponse(status: status,
                                      body: String(data: data, encoding: .utf8) ?? "")
        }
        return data
    }
}

private extension Data {
    mutating func append(_ string: String) {
        append(Data(string.utf8))
    }
}
