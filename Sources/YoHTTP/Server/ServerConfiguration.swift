public struct TLS: Sendable, Equatable {
    public var key: String
    public var cert: String

    public init(key: String, cert: String) {
        self.key = key
        self.cert = cert
    }
}

public struct ServerConfiguration: Sendable {
    public var hostname: String
    public var port: Int
    public var backlog: Int
    public var reuseAddress: Bool
    public var maxRequestBodySize: Int
    public var requestTimeout: Duration?
    public var serverName: String?
    public var tls: TLS?

    public init(
        hostname: String = "127.0.0.1",
        port: Int = 8080,
        backlog: Int = 256,
        reuseAddress: Bool = true,
        maxRequestBodySize: Int = 10 * 1024 * 1024,
        requestTimeout: Duration? = nil,
        serverName: String? = "yohttp",
        tls: TLS? = nil
    ) {
        self.hostname = hostname
        self.port = port
        self.backlog = backlog
        self.reuseAddress = reuseAddress
        self.maxRequestBodySize = maxRequestBodySize
        self.requestTimeout = requestTimeout
        self.serverName = serverName
        self.tls = tls
    }
}
