package wen

import std.collection.*

/*
 * Shared helpers used across the framework.
 */

// Standard reason phrase for an HTTP status code.
public func reasonPhrase(code: Int64): String {
    match (code) {
        case 200 => "OK"
        case 201 => "Created"
        case 202 => "Accepted"
        case 204 => "No Content"
        case 301 => "Moved Permanently"
        case 302 => "Found"
        case 304 => "Not Modified"
        case 400 => "Bad Request"
        case 401 => "Unauthorized"
        case 403 => "Forbidden"
        case 404 => "Not Found"
        case 405 => "Method Not Allowed"
        case 409 => "Conflict"
        case 415 => "Unsupported Media Type"
        case 422 => "Unprocessable Entity"
        case 429 => "Too Many Requests"
        case 500 => "Internal Server Error"
        case 501 => "Not Implemented"
        case 503 => "Service Unavailable"
        case _ => "Status"
    }
}

// Split a string at the first occurrence of `sep`.
// Returns (head, tail). If `sep` is absent, tail is the empty string.
public func splitOnce(s: String, sep: String): (String, String) {
    let idx = s.indexOf(sep)
    match (idx) {
        case Some(i) =>
            let head = s[0..i]
            let tail = s[(i + sep.size)..s.size]
            return (head, tail)
        case None => return (s, "")
    }
}

// Trim leading/trailing ASCII whitespace.
public func trimWs(s: String): String {
    return s.trimAscii()
}

// Whether `list` already contains `value`.
public func listContains(list: ArrayList<String>, value: String): Bool {
    for (item in list) {
        if (item == value) {
            return true
        }
    }
    return false
}

// Split a path into non-empty segments: "/a/b/" -> ["a", "b"].
public func pathSegments(path: String): Array<String> {
    let raw = path.split("/")
    let parts = ArrayList<String>()
    for (seg in raw) {
        if (!seg.isEmpty()) {
            parts.add(seg)
        }
    }
    return parts.toArray()
}
