import Foundation

/// Minimal HTTP/1.1 request, enough for the phone web client.
public struct HTTPRequest: Equatable, Sendable {
    public let method: String
    public let path: String
    public let query: [String: String]
    public let headers: [String: String] // lower-cased names
    public let body: Data

    public func header(_ name: String) -> String? { headers[name.lowercased()] }

    public var cookies: [String: String] {
        guard let raw = header("cookie") else { return [:] }
        var result: [String: String] = [:]
        for part in raw.split(separator: ";") {
            let pair = part.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            if pair.count == 2 { result[pair[0]] = pair[1] }
        }
        return result
    }
}

public enum HTTPParseResult: Equatable, Sendable {
    case incomplete
    case invalid
    case complete(HTTPRequest)
}

public enum HTTPParser {
    public static let maxHeaderBytes = 16 * 1024
    public static let maxBodyBytes = 1024 * 1024

    public static func parse(_ data: Data) -> HTTPParseResult {
        let separator = Data("\r\n\r\n".utf8)
        guard let headerEnd = data.range(of: separator) else {
            return data.count > maxHeaderBytes ? .invalid : .incomplete
        }
        guard let head = String(data: data[data.startIndex..<headerEnd.lowerBound], encoding: .utf8) else {
            return .invalid
        }
        let lines = head.components(separatedBy: "\r\n")
        let requestLine = lines[0].split(separator: " ")
        guard requestLine.count == 3, requestLine[2].hasPrefix("HTTP/1.") else { return .invalid }

        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { return .invalid }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            headers[name] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }

        let length = Int(headers["content-length"] ?? "0") ?? -1
        guard length >= 0, length <= maxBodyBytes else { return .invalid }
        let bodyStart = headerEnd.upperBound
        guard data.count - (bodyStart - data.startIndex) >= length else { return .incomplete }
        let body = Data(data[bodyStart..<(bodyStart + length)])

        let target = String(requestLine[1])
        let components = URLComponents(string: target)
        let path = components?.percentEncodedPath.removingPercentEncoding ?? target
        var query: [String: String] = [:]
        for item in components?.queryItems ?? [] { query[item.name] = item.value ?? "" }
        return .complete(HTTPRequest(method: String(requestLine[0]), path: path, query: query,
                                     headers: headers, body: body))
    }
}

/// Only private networks may reach the server: loopback, LAN and Tailscale.
public enum AddressPolicy {
    public static func isAllowed(_ host: String) -> Bool {
        var address = host.lowercased()
        if let percent = address.firstIndex(of: "%") { address = String(address[..<percent]) }
        if address.hasPrefix("::ffff:"), address.contains(".") { address = String(address.dropFirst(7)) }
        if address.contains(".") { return isAllowedIPv4(address) }
        return isAllowedIPv6(address)
    }

    private static func isAllowedIPv4(_ address: String) -> Bool {
        let parts = address.split(separator: ".").compactMap { UInt8($0) }
        guard parts.count == 4 else { return false }
        switch (parts[0], parts[1]) {
        case (127, _), (10, _), (192, 168): return true
        case (172, 16...31): return true
        case (100, 64...127): return true // CGNAT, used by Tailscale
        case (169, 254): return true
        default: return false
        }
    }

    private static func isAllowedIPv6(_ address: String) -> Bool {
        if address == "::1" { return true }
        guard let first = address.split(separator: ":", omittingEmptySubsequences: false).first,
              let value = UInt16(first, radix: 16) else { return false }
        if value & 0xFE00 == 0xFC00 { return true } // fc00::/7 unique local (Tailscale fd7a:…)
        if value & 0xFFC0 == 0xFE80 { return true } // fe80::/10 link local
        return false
    }
}
