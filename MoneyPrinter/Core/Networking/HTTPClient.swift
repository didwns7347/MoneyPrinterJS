import Foundation

final class HTTPClient {
    private let baseURL: URL
    private let defaultHeaders: [String: String]
    private let retryPolicy: RetryPolicy
    private let requestIDHeader: String?
    private let session: URLSession
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(
        baseURL: URL,
        defaultHeaders: [String: String] = [:],
        timeout: TimeInterval = 30,
        retryPolicy: RetryPolicy = RetryPolicy(),
        requestIDHeader: String? = nil,
        encoder: JSONEncoder = JSONEncoder(),
        decoder: JSONDecoder = JSONDecoder(),
        session: URLSession? = nil
    ) {
        self.baseURL = baseURL
        self.defaultHeaders = defaultHeaders
        self.retryPolicy = retryPolicy
        self.requestIDHeader = requestIDHeader
        self.encoder = encoder
        self.decoder = decoder
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = timeout
            configuration.timeoutIntervalForResource = timeout
            self.session = URLSession(configuration: configuration)
        }
    }

    func get<Response: Decodable>(
        _ path: String,
        query: [URLQueryItem] = [],
        as type: Response.Type = Response.self
    ) async throws -> Response {
        let response = try await send(HTTPRequest(method: .get, path: path, query: query))
        return try decode(type, from: response.data)
    }

    func post<Body: Encodable, Response: Decodable>(
        _ path: String,
        body: Body,
        as type: Response.Type = Response.self
    ) async throws -> Response {
        let payload: Data
        do {
            payload = try encoder.encode(body)
        } catch {
            throw NetworkError.encoding(error.localizedDescription)
        }
        let request = HTTPRequest(
            method: .post,
            path: path,
            headers: ["Content-Type": "application/json"],
            body: payload
        )
        let response = try await send(request)
        return try decode(type, from: response.data)
    }

    func postData<Body: Encodable>(_ path: String, body: Body) async throws -> (request: Data, response: Data) {
        let payload: Data
        do {
            payload = try encoder.encode(body)
        } catch {
            throw NetworkError.encoding(error.localizedDescription)
        }
        let request = HTTPRequest(
            method: .post,
            path: path,
            headers: ["Content-Type": "application/json"],
            body: payload
        )
        let response = try await send(request)
        return (payload, response.data)
    }

    func send(_ request: HTTPRequest, retryPolicy: RetryPolicy? = nil) async throws -> HTTPResponse {
        let policy = retryPolicy ?? self.retryPolicy
        let urlRequest = try makeURLRequest(request)
        var attempt = 0
        while true {
            let data: Data
            let response: URLResponse
            do {
                (data, response) = try await session.data(for: urlRequest)
            } catch let error as CancellationError {
                throw error
            } catch let error as URLError {
                throw NetworkError.transport(error)
            } catch {
                throw NetworkError.invalidResponse(error.localizedDescription)
            }

            guard let http = response as? HTTPURLResponse else {
                throw NetworkError.invalidResponse("HTTP 응답이 아닙니다.")
            }
            if (200 ..< 300).contains(http.statusCode) {
                return HTTPResponse(data: data, response: http)
            }

            if policy.retryableStatusCodes.contains(http.statusCode),
               attempt < policy.maxRetries
            {
                let delay = retryDelay(attempt: attempt, response: http, policy: policy)
                attempt += 1
                try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                continue
            }

            throw NetworkError.http(
                status: http.statusCode,
                message: Self.errorMessage(from: data),
                requestID: requestIDHeader.flatMap { http.value(forHTTPHeaderField: $0) }
            )
        }
    }

    func send<Response: Decodable>(
        _ request: HTTPRequest,
        as type: Response.Type,
        retryPolicy: RetryPolicy? = nil
    ) async throws -> Response {
        let response = try await send(request, retryPolicy: retryPolicy)
        return try decode(type, from: response.data)
    }

    private func makeURLRequest(_ request: HTTPRequest) throws -> URLRequest {
        let pathURL = request.path.split(separator: "/").reduce(baseURL) { partial, component in
            partial.appending(path: String(component))
        }
        guard var components = URLComponents(url: pathURL, resolvingAgainstBaseURL: false) else {
            throw NetworkError.invalidURL(request.path)
        }
        if !request.query.isEmpty {
            components.queryItems = (components.queryItems ?? []) + request.query
        }
        guard let url = components.url else {
            throw NetworkError.invalidURL(request.path)
        }

        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = request.method.rawValue
        urlRequest.httpBody = request.body
        urlRequest.setValue("application/json", forHTTPHeaderField: "Accept")
        for (name, value) in defaultHeaders.merging(request.headers, uniquingKeysWith: { $1 }) {
            urlRequest.setValue(value, forHTTPHeaderField: name)
        }
        return urlRequest
    }

    private func decode<Response: Decodable>(_ type: Response.Type, from data: Data) throws -> Response {
        do {
            return try decoder.decode(type, from: data)
        } catch {
            throw NetworkError.decoding(String(describing: error))
        }
    }

    private func retryDelay(attempt: Int, response: HTTPURLResponse, policy: RetryPolicy) -> TimeInterval {
        if let header = response.value(forHTTPHeaderField: "Retry-After") {
            if let seconds = TimeInterval(header) {
                return min(max(seconds, 0), 60)
            }
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
            if let date = formatter.date(from: header) {
                return min(max(date.timeIntervalSinceNow, 0), 60)
            }
        }
        return min(policy.baseDelay * pow(2, Double(attempt)), policy.maxDelay)
    }

    private static func errorMessage(from data: Data) -> String {
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let message = json["message"] as? String, !message.isEmpty {
                return message
            }
            if let message = json["msg1"] as? String, !message.isEmpty {
                return message
            }
            if let error = json["error"] as? [String: Any],
               let message = error["message"] as? String,
               !message.isEmpty
            {
                return message
            }
            if let error = json["error"] as? String, !error.isEmpty {
                return error
            }
            if let detail = json["detail"] as? String, !detail.isEmpty {
                return detail
            }
            if let details = json["detail"] as? [[String: Any]] {
                let messages = details.compactMap { $0["msg"] as? String }
                if !messages.isEmpty {
                    return messages.joined(separator: " ")
                }
            }
        }
        let text = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if text.isEmpty {
            return "응답 본문이 비어 있습니다."
        }
        return String(text.prefix(2_000))
    }
}
