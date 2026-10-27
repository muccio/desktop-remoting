import Foundation

public struct PollResponse: Decodable {
    public let success: Bool
    public let found: Bool
    public let mac_id: String?
    public let status: String?
    public let reset_requested: Bool?
    public let has_answer: Bool?
    public let sdp_answer: String?
    public let candidates: [[String: AnyCodable]]?
    public let total_candidates: Int?
}

/// Helper per decodificare tipi eterogenei in JSON (stringhe, numeri, bool)
public struct AnyCodable: Codable {
    public let value: Any

    public init(_ value: Any) {
        self.value = value
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let bool = try? container.decode(Bool.self) {
            value = bool
        } else if let int = try? container.decode(Int.self) {
            value = int
        } else if let double = try? container.decode(Double.self) {
            value = double
        } else if let string = try? container.decode(String.self) {
            value = string
        } else if let array = try? container.decode([AnyCodable].self) {
            value = array.map { $0.value }
        } else if let dict = try? container.decode([String: AnyCodable].self) {
            value = dict.mapValues { $0.value }
        } else {
            value = ()
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        if let bool = value as? Bool {
            try container.encode(bool)
        } else if let int = value as? Int {
            try container.encode(int)
        } else if let double = value as? Double {
            try container.encode(double)
        } else if let string = value as? String {
            try container.encode(string)
        }
    }
}

/// Client HTTP per comunicare con il backend di signaling PHP basato su file CSV
public final class SignalingClient {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    /// Registra l'offerta SDP generata dall'Host macOS sul file CSV
    public func registerOffer(serverBaseUrl: URL, macId: String, sdp: String) async throws {
        let endpoint = serverBaseUrl.appendingPathComponent("register.php")
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let payload: [String: Any] = [
            "action": "offer",
            "mac_id": macId,
            "sdp": sdp,
            "role": "host"
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, (200...299).contains(httpResponse.statusCode) else {
            let errorText = String(data: data, encoding: .utf8) ?? "Errore sconosciuto"
            throw NSError(domain: "SignalingClient", code: -1, userInfo: [NSLocalizedDescriptionKey: errorText])
        }
    }

    /// Invia un candidato ICE scoperto localmente dall'Host
    public func sendIceCandidate(serverBaseUrl: URL, macId: String, candidateDict: [String: Any]) async throws {
        let endpoint = serverBaseUrl.appendingPathComponent("register.php")
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let payload: [String: Any] = [
            "action": "candidate",
            "mac_id": macId,
            "role": "host",
            "candidate": candidateDict
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        let _ = try await session.data(for: request)
    }

    /// Interroga il server PHP (poll.php) per verificare se il client ha caricato la risposta SDP Answer
    public func pollAnswer(serverBaseUrl: URL, macId: String, sinceIndex: Int = 0) async throws -> PollResponse {
        var components = URLComponents(url: serverBaseUrl.appendingPathComponent("poll.php"), resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "mac_id", value: macId),
            URLQueryItem(name: "role", value: "host"),
            URLQueryItem(name: "since_index", value: String(sinceIndex))
        ]

        guard let url = components?.url else {
            throw NSError(domain: "SignalingClient", code: -2, userInfo: [NSLocalizedDescriptionKey: "URL non valido"])
        }

        let (data, _) = try await session.data(from: url)
        let decoder = JSONDecoder()
        return try decoder.decode(PollResponse.self, from: data)
    }

    /// Rimuove la sessione dal server CSV alla disconnessione
    public func closeSession(serverBaseUrl: URL, macId: String) async {
        let endpoint = serverBaseUrl.appendingPathComponent("register.php")
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let payload: [String: Any] = ["action": "close", "mac_id": macId]
        request.httpBody = try? JSONSerialization.data(withJSONObject: payload)
        _ = try? await session.data(for: request)
    }
}
