package wen

import std.collection.*

/*
 * An incoming HTTP request. Header keys are stored lower-cased so that lookups
 * are case-insensitive, matching the HTTP spec.
 */
public class HttpRequest {
    public var method: String
    public var url: String          // original request target, e.g. "/a?x=1"
    public var path: String         // path component only, e.g. "/a"
    public var httpVersion: String

    public let headers: HashMap<String, String>
    public let query: HashMap<String, String>
    public var params: HashMap<String, String>
    public var body: String

    // Free-form per-request store for middleware to pass *string* data
    // downstream (the analogue of attaching properties to `req` in Express).
    public let attributes: HashMap<String, String>

    // Typed per-request store: middleware may stash arbitrary objects here (a
    // parsed body, an authenticated user, a DB handle, ...) for downstream
    // handlers. Read back with `local(key)` and downcast with `as`.
    public let locals: HashMap<String, Any>

    // Parsed request cookies, populated by the cookieParser middleware.
    public let cookies: HashMap<String, String>

    // Raw request body bytes, preserved by the server so binary payloads
    // (uploads, proxied content, ...) survive intact. `body` is the UTF-8 view.
    public var bodyBytes: Array<UInt8>

    // Parsed JSON body, populated by the jsonParser middleware when the request
    // carries a well-formed application/json body. Read via `json()`.
    public var jsonBody: ?JsonValue = None

    // Remote peer address, filled in by the server (empty when handled directly
    // via app.handle, e.g. in tests).
    public var ip: String = ""

    // The owning application, set when a request is dispatched, so middleware
    // can reach app settings at request time (Express's `req.app`).
    public var app: ?Application = None

    public init(method: String, url: String) {
        this.method = method
        this.url = url
        this.path = url
        this.httpVersion = "HTTP/1.1"
        this.headers = HashMap<String, String>()
        this.query = HashMap<String, String>()
        this.params = HashMap<String, String>()
        this.body = ""
        this.attributes = HashMap<String, String>()
        this.locals = HashMap<String, Any>()
        this.cookies = HashMap<String, String>()
        this.bodyBytes = Array<UInt8>()
    }

    // Case-insensitive header lookup.
    public func header(name: String): ?String {
        return this.headers.get(name.toAsciiLower())
    }

    // Express-style alias for `header`.
    public func get(name: String): ?String {
        return header(name)
    }

    // A captured route parameter, e.g. `/users/:id` -> param("id").
    public func param(name: String): ?String {
        return this.params.get(name)
    }

    // A query-string value, e.g. `?page=2` -> queryParam("page").
    public func queryParam(name: String): ?String {
        return this.query.get(name)
    }

    public func setAttribute(key: String, value: String): Unit {
        this.attributes[key] = value
    }

    public func attribute(key: String): ?String {
        return this.attributes.get(key)
    }

    // Stash an arbitrary typed value for downstream handlers.
    public func setLocal(key: String, value: Any): Unit {
        this.locals[key] = value
    }

    // Retrieve a typed value stashed by upstream middleware. Downcast the
    // result with `as`, e.g. `(req.local("user") ?? ...) as User`.
    public func local(key: String): ?Any {
        return this.locals.get(key)
    }

    // A parsed cookie value (requires the cookieParser middleware).
    public func cookie(name: String): ?String {
        return this.cookies.get(name)
    }

    // The parsed JSON body, if the jsonParser middleware ran and the body was
    // well-formed application/json. Navigate it with get/at/asString/asInt/...
    public func json(): ?JsonValue {
        return this.jsonBody
    }

    // Read an application setting at request time, if the owning app is known.
    public func setting(key: String): ?String {
        match (this.app) {
            case Some(a) => return a.setting(key)
            case None => return None
        }
    }

    // The host name from the Host header, with any port stripped (Express's
    // req.hostname). Handles bracketed IPv6 literals like "[::1]:8080".
    public func hostname(): ?String {
        match (this.header("host")) {
            case Some(h) =>
                if (h.startsWith("[")) {
                    match (h.indexOf("]")) {
                        case Some(i) => return Some(h[0..(i + 1)])
                        case None => return Some(h)
                    }
                }
                let (host, _) = splitOnce(h, ":")
                if (host.isEmpty()) {
                    return None
                }
                return Some(host)
            case None => return None
        }
    }

    // Whether the request body's Content-Type matches `t`. `t` may be a
    // shorthand ("json") or a full MIME type. (Named `isType` because `is` is a
    // Cangjie keyword; Express calls this `req.is`.)
    public func isType(t: String): Bool {
        let ct = match (this.header("content-type")) {
            case Some(v) => v.toAsciiLower()
            case None => return false
        }
        let (wantMain, _) = splitOnce(contentTypeFor(t).toAsciiLower(), ";")
        return ct.contains(wantMain.trimAscii())
    }

    // Whether the client's Accept header admits `t` (shorthand or full MIME).
    // A missing/`*/*` Accept admits anything, matching Express.
    public func accepts(t: String): Bool {
        let accept = match (this.header("accept")) {
            case Some(v) => v.toAsciiLower()
            case None => return true
        }
        if (accept.isEmpty() || accept.contains("*/*")) {
            return true
        }
        let (wantMain, _) = splitOnce(contentTypeFor(t).toAsciiLower(), ";")
        return accept.contains(wantMain.trimAscii())
    }
}
