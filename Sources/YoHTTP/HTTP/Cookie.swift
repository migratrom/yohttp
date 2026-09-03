import Foundation

public struct Cookie: Sendable, Equatable {
    public var name: String
    public var value: String
    public var domain: String?
    public var path: String?
    public var expires: Date?
    public var maxAge: Duration?
    public var secure: Bool
    public var httpOnly: Bool
    public var sameSite: SameSite?

    public init(
        name: String,
        value: String,
        domain: String? = nil,
        path: String? = nil,
        expires: Date? = nil,
        maxAge: Duration? = nil,
        secure: Bool = false,
        httpOnly: Bool = false,
        sameSite: SameSite? = nil
    ) {
        self.name = name
        self.value = value
        self.domain = domain
        self.path = path
        self.expires = expires
        self.maxAge = maxAge
        self.secure = secure
        self.httpOnly = httpOnly
        self.sameSite = sameSite
    }

    func serialized() -> String {
        var components = ["\(name)=\(value)"]
        if let domain { components.append("Domain=\(domain)") }
        if let path { components.append("Path=\(path)") }
        if let expires { components.append("Expires=\(Self.httpDate(expires))") }
        if let maxAge {
            let seconds = maxAge.components.seconds
            components.append("Max-Age=\(seconds)")
        }
        if secure { components.append("Secure") }
        if httpOnly { components.append("HttpOnly") }
        if let sameSite { components.append("SameSite=\(sameSite.rawValue)") }
        return components.joined(separator: "; ")
    }

    private static func httpDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
        return formatter.string(from: date)
    }
}

public enum SameSite: String, Sendable, Equatable {
    case strict = "Strict"
    case lax = "Lax"
    case none = "None"
}
