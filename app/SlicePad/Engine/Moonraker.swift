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

        // The only decision made here is whether a scheme is already present;
        // URL does the parsing. Asked as an exact prefix against the two schemes
        // this speaks, because the obvious alternatives are both wrong: searching
        // for "://" matches it inside a query string, and asking URLComponents for
        // a nil scheme reads "sv08.local:7125" as the scheme "sv08.local".
        let lowered = trimmed.lowercased()
        let hasScheme = lowered.hasPrefix("http://") || lowered.hasPrefix("https://")

        guard let url = URL(string: hasScheme ? trimmed : "http://\(trimmed)"),
              url.host?.isEmpty == false else { return nil }
        return url
    }

    struct UploadResult {
        /// Path the server assigned, relative to `root`. Starting the print uses
        /// this rather than the name we sent, since the server may have changed it.
        let path: String
    }

    enum Failure: LocalizedError {
        case unreachable(address: String, reason: String)
        case badResponse(status: Int, detail: String)
        case unexpectedPayload(body: String)

        var errorDescription: String? {
            switch self {
            case let .unreachable(address, reason):
                return "Could not reach \(address). \(reason)"
            case let .badResponse(status, detail):
                return "The printer answered \(status). \(detail)"
            case let .unexpectedPayload(body):
                // Thrown after the file has already arrived, so it says so —
                // reporting it as a plain failure is what left someone believing
                // the upload had not happened when it had. The body is quoted
                // because the alternative is guessing at a shape we did not read.
                let landed = "The file reached the printer, but its reply did not "
                    + "name the file, so the print was not started."
                return body.isEmpty ? landed : landed + " It said: \(body)"
            }
        }
    }

    /// Moonraker has moved the uploaded item between the top level and a "result"
    /// envelope across versions, and both are in the field — the SV08 this was
    /// first run against returns the top-level shape, which is why reading only
    /// the envelope failed on an upload that had in fact succeeded.
    private struct UploadResponse: Decodable {
        struct Item: Decodable { let path: String }
        struct Envelope: Decodable { let item: Item? }

        let item: Item?
        let result: Envelope?

        var path: String? { item?.path ?? result?.item?.path }
    }

    /// Split out from the request so it can be checked directly — see app/Tests.
    ///
    /// Deliberately throws rather than falling back to the filename we sent, which
    /// is what Orca does. Moonraker renames on collision, so that fallback can name
    /// an *older* file of the same name, and starting the wrong print is worse than
    /// reporting that the upload landed but could not be identified.
    static func uploadedPath(fromResponse data: Data) throws -> String {
        let body = String(data: data, encoding: .utf8) ?? ""
        guard let decoded = try? JSONDecoder().decode(UploadResponse.self, from: data),
              let path = decoded.path, !path.isEmpty else {
            throw Failure.unexpectedPayload(body: String(body.prefix(200)))
        }
        return path
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
        let path = try Self.uploadedPath(fromResponse: data)
        return UploadResult(path: path)
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

    /// Whether the address leads to something answering HTTP.
    ///
    /// Asks Moonraker about itself rather than about the printer. /printer/info is
    /// proxied to Klipper and answers 503 whenever Klippy is starting, shut down or
    /// disconnected — all states a reachable machine sits in — so using it reported
    /// "could not reach the printer" for a printer that was plainly there. Any HTTP
    /// answer at all settles the question this is asked for; whether Klipper is
    /// ready is the upload's business to report.
    func reachable() async -> Bool {
        var request = URLRequest(url: host.appendingPathComponent("server/info"))
        // Generous, because the first contact with a .local name waits on mDNS.
        request.timeoutInterval = 15
        apiKey.map { request.setValue($0, forHTTPHeaderField: "X-Api-Key") }
        guard let (_, response) = try? await URLSession.shared.data(for: request) else { return false }
        return response is HTTPURLResponse
    }

    /// Moonraker reports failures as {"error": {"message": "Klippy Not Connected"}}.
    /// That sentence is the useful part; the JSON around it is not.
    static func detail(fromErrorBody body: String) -> String {
        struct Envelope: Decodable {
            struct Reported: Decodable { let message: String? }
            let error: Reported?
        }
        if let data = body.data(using: .utf8),
           let envelope = try? JSONDecoder().decode(Envelope.self, from: data),
           let message = envelope.error?.message, !message.isEmpty {
            return message
        }
        return String(body.prefix(200))
    }

    private func send(_ request: URLRequest, body: Data) async throws -> Data {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.upload(for: request, from: body)
        } catch {
            // A wrong address arrives here rather than as a status code, and the
            // address is the thing worth naming when it does.
            throw Failure.unreachable(address: host.absoluteString,
                                      reason: error.localizedDescription)
        }

        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200 ..< 300).contains(status) else {
            throw Failure.badResponse(
                status: status,
                detail: Self.detail(fromErrorBody: String(data: data, encoding: .utf8) ?? ""))
        }
        return data
    }
}

private extension Data {
    mutating func append(_ string: String) {
        append(Data(string.utf8))
    }
}
