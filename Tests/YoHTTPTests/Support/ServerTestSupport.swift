import Foundation
import NIOCore
import NIOPosix
import NIOSSL
import Testing
@testable import YoHTTP

#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

enum ServerTestError: Error {
    case socketCreation
    case connection(Int32)
    case send(Int32)
    case receive(Int32)
    case invalidResponse(String)
}

struct RawHTTPResponse: Sendable {
    let statusCode: Int
    let reasonPhrase: String
    let headers: [String: [String]]
    let body: Data

    func header(_ name: String) -> String? {
        headers[name.lowercased()]?.first
    }
}

func waitForAddress(of server: YoHTTPServer) async throws -> YoHTTP.SocketAddress {
    for _ in 0..<500 {
        if let address = server.localAddress { return address }
        try await Task.sleep(for: .milliseconds(5))
    }
    throw ServerTestError.invalidResponse("Server did not bind in time")
}

func withServer<T: Sendable>(
    configuration: ServerConfiguration = .init(hostname: "127.0.0.1", port: 0),
    handler: @escaping Handler,
    operation: (YoHTTPServer, YoHTTP.SocketAddress) async throws -> T
) async throws -> T {
    let server = YoHTTPServer()
    server.handler(handler)
    let listening = Task { try await server.listen(configuration) }

    do {
        let address = try await waitForAddress(of: server)
        let result = try await operation(server, address)
        try await server.shutdown()
        try await listening.value
        return result
    } catch {
        try? await server.shutdown()
        listening.cancel()
        _ = try? await listening.value
        throw error
    }
}

func rawRequest(
    port: Int,
    method: String = "GET",
    target: String = "/",
    version: String = "HTTP/1.1",
    headers: [(String, String)] = [],
    body: String = "",
    close: Bool = true
) -> String {
    var fields = [("Host", "127.0.0.1:\(port)")]
    fields.append(contentsOf: headers)
    if !body.isEmpty, !fields.contains(where: { $0.0.lowercased() == "content-length" || $0.0.lowercased() == "transfer-encoding" }) {
        fields.append(("Content-Length", String(Data(body.utf8).count)))
    }
    if close, !fields.contains(where: { $0.0.lowercased() == "connection" }) {
        fields.append(("Connection", "close"))
    }
    let headerBlock = fields.map { "\($0.0): \($0.1)" }.joined(separator: "\r\n")
    return "\(method) \(target) \(version)\r\n\(headerBlock)\r\n\r\n\(body)"
}

func exchangeRawHTTP(port: Int, request: String) async throws -> Data {
    try await exchangeRawHTTP(port: port, requestParts: [request])
}

func exchangeRawHTTP(
    port: Int,
    requestParts: [String],
    pauseBetweenParts: useconds_t = 0
) async throws -> Data {
    try await Task.detached {
        #if os(Linux)
        let streamType = Int32(SOCK_STREAM.rawValue)
        #else
        let streamType = SOCK_STREAM
        #endif
        let descriptor = socket(AF_INET, streamType, 0)
        guard descriptor >= 0 else { throw ServerTestError.socketCreation }
        defer { _ = close(descriptor) }

        var timeout = timeval(tv_sec: 3, tv_usec: 0)
        _ = withUnsafePointer(to: &timeout) {
            setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, $0, socklen_t(MemoryLayout<timeval>.size))
        }

        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(port).bigEndian
        guard inet_pton(AF_INET, "127.0.0.1", &address.sin_addr) == 1 else {
            throw ServerTestError.connection(errno)
        }
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard connected == 0 else { throw ServerTestError.connection(errno) }

        for (index, part) in requestParts.enumerated() {
            let requestData = Data(part.utf8)
            var sent = 0
            while sent < requestData.count {
                let count = requestData.withUnsafeBytes { bytes in
                    send(descriptor, bytes.baseAddress!.advanced(by: sent), requestData.count - sent, 0)
                }
                guard count > 0 else { throw ServerTestError.send(errno) }
                sent += count
            }
            if pauseBetweenParts > 0, index < requestParts.count - 1 {
                usleep(pauseBetweenParts)
            }
        }

        var response = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = recv(descriptor, &buffer, buffer.count, 0)
            if count == 0 { break }
            if count < 0 {
                if errno == EINTR { continue }
                if (errno == EAGAIN || errno == EWOULDBLOCK), !response.isEmpty { break }
                throw ServerTestError.receive(errno)
            }
            response.append(contentsOf: buffer[0..<count])
        }
        return response
    }.value
}

func exchangeRawHTTPS(port: Int, tls: TLS, request: String) async throws -> Data {
    try await exchangeRawHTTPS(port: port, tls: tls, requestParts: [request])
}

func exchangeRawHTTPS(port: Int, tls: TLS, requestParts: [String]) async throws -> Data {
    let certificates = try NIOSSLCertificate.fromPEMBytes(Array(tls.cert.utf8))
    var clientTLS = TLSConfiguration.makeClientConfiguration()
    clientTLS.trustRoots = .certificates(certificates)
    let sslContext = try NIOSSLContext(configuration: clientTLS)

    let clientChannel = try await ClientBootstrap(group: MultiThreadedEventLoopGroup.singleton)
        .channelOption(ChannelOptions.connectTimeout, value: .seconds(3))
        .connect(host: "127.0.0.1", port: port) { channel in
            channel.eventLoop.makeCompletedFuture {
                try channel.pipeline.syncOperations.addHandler(
                    try NIOSSLClientHandler(context: sslContext, serverHostname: "localhost")
                )
                return try NIOAsyncChannel<ByteBuffer, ByteBuffer>(wrappingChannelSynchronously: channel)
            }
        }

    return try await clientChannel.executeThenClose { inbound, outbound in
        for part in requestParts {
            var buffer = ByteBuffer()
            buffer.writeString(part)
            try await outbound.write(buffer)
        }
        var response = Data()
        for try await chunk in inbound {
            var chunk = chunk
            if let bytes = chunk.readBytes(length: chunk.readableBytes) {
                response.append(contentsOf: bytes)
            }
        }
        return response
    }
}

func openAndCloseRawConnection(port: Int) async throws {
    try await Task.detached {
        #if os(Linux)
        let streamType = Int32(SOCK_STREAM.rawValue)
        #else
        let streamType = SOCK_STREAM
        #endif
        let descriptor = socket(AF_INET, streamType, 0)
        guard descriptor >= 0 else { throw ServerTestError.socketCreation }
        defer { _ = close(descriptor) }

        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(port).bigEndian
        guard inet_pton(AF_INET, "127.0.0.1", &address.sin_addr) == 1 else {
            throw ServerTestError.connection(errno)
        }
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard connected == 0 else { throw ServerTestError.connection(errno) }
    }.value
}

func parseSingleResponse(_ data: Data, bodyIsSuppressed: Bool = false) throws -> RawHTTPResponse {
    guard let boundary = data.range(of: Data("\r\n\r\n".utf8)) else {
        throw ServerTestError.invalidResponse(String(decoding: data, as: UTF8.self))
    }
    let headerData = data[..<boundary.lowerBound]
    let lines = String(decoding: headerData, as: UTF8.self).components(separatedBy: "\r\n")
    guard let statusLine = lines.first else { throw ServerTestError.invalidResponse("Missing status") }
    let statusParts = statusLine.split(separator: " ", maxSplits: 2).map(String.init)
    guard statusParts.count >= 2, let statusCode = Int(statusParts[1]) else {
        throw ServerTestError.invalidResponse(statusLine)
    }

    var headers: [String: [String]] = [:]
    for line in lines.dropFirst() {
        let pieces = line.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        guard pieces.count == 2 else { continue }
        headers[String(pieces[0]).lowercased(), default: []].append(String(pieces[1]).trimmingCharacters(in: .whitespaces))
    }
    let body = bodyIsSuppressed ? Data() : Data(data[boundary.upperBound...])
    return RawHTTPResponse(
        statusCode: statusCode,
        reasonPhrase: statusParts.count == 3 ? statusParts[2] : "",
        headers: headers,
        body: body
    )
}

func parseResponses(_ data: Data) throws -> [RawHTTPResponse] {
    var responses: [RawHTTPResponse] = []
    var remainder = data
    while !remainder.isEmpty {
        guard let boundary = remainder.range(of: Data("\r\n\r\n".utf8)) else {
            throw ServerTestError.invalidResponse(String(decoding: remainder, as: UTF8.self))
        }
        let headerData = remainder[..<boundary.lowerBound]
        let headerText = String(decoding: headerData, as: UTF8.self)
        let lengthLine = headerText.components(separatedBy: "\r\n").first {
            $0.lowercased().hasPrefix("content-length:")
        }
        let bodyLength = lengthLine.flatMap { Int($0.split(separator: ":", maxSplits: 1)[1].trimmingCharacters(in: .whitespaces)) } ?? 0
        let responseEnd = boundary.upperBound + bodyLength
        guard responseEnd <= remainder.endIndex else { throw ServerTestError.invalidResponse(headerText) }
        responses.append(try parseSingleResponse(Data(remainder[..<responseEnd])))
        remainder = Data(remainder[responseEnd...])
    }
    return responses
}
