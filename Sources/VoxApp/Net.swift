import Foundation

/// Shared networking helpers for the two outbound paths (chat completions and speech upload).
enum Net {

    /// True for loopback and RFC1918 / link-local hosts.
    static func isLocal(_ host: String) -> Bool {
        if host == "localhost" || host == "127.0.0.1" || host == "::1" { return true }
        if host.hasPrefix("10.") || host.hasPrefix("192.168.") || host.hasPrefix("169.254.") { return true }
        if host.hasPrefix("172.") {
            let parts = host.split(separator: ".")
            if parts.count > 1, let second = Int(parts[1]), (16...31).contains(second) { return true }
        }
        return false
    }

    /// A direct localhost/LAN call must bypass the system proxy (a global proxy answers 502 for
    /// 127.0.0.1), while a remote vendor usually needs one. So only clear it for local hosts.
    static func session(timeout: TimeInterval) -> URLSession {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = timeout
        cfg.timeoutIntervalForResource = timeout + 60
        return URLSession(configuration: cfg)
    }

    static func session(timeout: TimeInterval, host: String) -> URLSession {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = timeout
        cfg.timeoutIntervalForResource = timeout + 60
        if isLocal(host) { cfg.connectionProxyDictionary = [:] }
        return URLSession(configuration: cfg)
    }

    /// Trim whitespace and trailing slashes so path joins stay predictable.
    static func normalizedBase(_ base: String) -> String {
        var s = base.trimmingCharacters(in: .whitespaces)
        while s.hasSuffix("/") { s.removeLast() }
        return s
    }
}
