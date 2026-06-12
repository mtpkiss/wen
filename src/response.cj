package wen

import std.collection.*
import std.fs.*

/*
 * An outgoing HTTP response. Methods accumulate state; the server serializes a
 * finished response onto the socket. Chainable setters mirror Express's
 * `res.status(201).set(...).send(...)`.
 */
public class HttpResponse {
    public var statusCode: Int64 = 200
    public var statusMessage: String = "OK"
    public let headers: HashMap<String, String>
    // Set-Cookie needs to appear once per cookie, which a single-valued header
    // map cannot express, so outgoing cookies live in their own list.
    public let setCookies: ArrayList<String>
    public var body: String = ""
    // When set, the response body is these raw bytes (binary payloads) and
    // `body` is ignored. Lets middleware emit images, gzip, etc.
    public var bodyBytes: ?Array<UInt8> = None
    public var finished: Bool = false

    // Live connection for streaming responses, attached by the server. None when
    // driven directly via app.handle (e.g. tests).
    public var conn: ?ResponseConnection = None
    // True once a handler has taken over the connection to stream; the server
    // then skips its normal serialize-and-write step.
    public var hijacked: Bool = false

    // When true, serialization keeps the Content-Length header but writes no
    // body (used for auto-HEAD responses).
    public var suppressBody: Bool = false

    // Response-scoped typed store for passing data between middleware/handlers
    // within a single response (Express's res.locals).
    public let locals: HashMap<String, Any> = HashMap<String, Any>()

    public init() {
        this.headers = HashMap<String, String>()
        this.headers["Content-Type"] = "text/plain; charset=utf-8"
        this.setCookies = ArrayList<String>()
    }

    public func status(code: Int64): HttpResponse {
        this.statusCode = code
        this.statusMessage = reasonPhrase(code)
        return this
    }

    public func set(name: String, value: String): HttpResponse {
        this.headers[name] = value
        return this
    }

    // Read back a header previously set on this response.
    public func get(name: String): ?String {
        return this.headers.get(name)
    }

    // Set several headers at once from a map, mirroring Express's
    // `res.set({...})`. Returns `this` for chaining.
    public func set(headers: HashMap<String, String>): HttpResponse {
        for ((k, v) in headers) {
            this.headers[k] = v
        }
        return this
    }

    public func contentType(value: String): HttpResponse {
        this.headers["Content-Type"] = value
        return this
    }

    // Set Content-Type, expanding shorthands like "json"/"html"/"text", mirroring
    // Express's res.type(). A value containing "/" is used verbatim.
    public func mimeType(value: String): HttpResponse {
        this.headers["Content-Type"] = contentTypeFor(value)
        return this
    }

    // Set the Location header (without finishing the response).
    public func location(url: String): HttpResponse {
        this.headers["Location"] = url
        return this
    }

    // Append a value to a header, creating it if absent. Set-Cookie is routed to
    // the dedicated cookie list so multiple cookies are preserved.
    public func append(name: String, value: String): HttpResponse {
        if (name.toAsciiLower() == "set-cookie") {
            this.setCookies.add(value)
            return this
        }
        match (this.headers.get(name)) {
            case Some(existing) => this.headers[name] = "${existing}, ${value}"
            case None => this.headers[name] = value
        }
        return this
    }

    // Queue a Set-Cookie header. Options are optional named arguments.
    public func cookie(name: String, value: String, path!: String = "/", maxAge!: Int64 = -1,
                       httpOnly!: Bool = false, secure!: Bool = false, sameSite!: String = ""): HttpResponse {
        var c = "${name}=${value}"
        if (!path.isEmpty()) {
            c += "; Path=${path}"
        }
        if (maxAge >= 0) {
            c += "; Max-Age=${maxAge}"
        }
        if (httpOnly) {
            c += "; HttpOnly"
        }
        if (secure) {
            c += "; Secure"
        }
        if (!sameSite.isEmpty()) {
            c += "; SameSite=${sameSite}"
        }
        this.setCookies.add(c)
        return this
    }

    // Expire a cookie on the client by sending an empty value with Max-Age=0.
    public func clearCookie(name: String, path!: String = "/"): HttpResponse {
        this.setCookies.add("${name}=; Path=${path}; Max-Age=0")
        return this
    }

    // Read a file from disk and send it, guessing Content-Type from the
    // extension. Throws if the file is missing so the error pipeline can handle
    // it (register an error middleware to convert that into a response). The
    // file is sent as raw bytes so binary assets (images, fonts, ...) survive
    // intact rather than being mangled by a UTF-8 round-trip.
    public func sendFile(path: String): Unit {
        let p = if (path.startsWith("./")) {
            path[2..path.size]
        } else {
            path
        }
        if (!exists(p)) {
            throw Exception("sendFile: file not found: ${path}")
        }
        this.headers["Content-Type"] = mimeFor(p)
        this.bodyBytes = Some(File.readFrom(p))
        this.finished = true
    }

    // Send a plain/HTML text body and finish the response.
    public func send(text: String): Unit {
        this.body = text
        this.finished = true
    }

    // Send a raw binary body and finish the response. Set Content-Type yourself
    // (e.g. res.contentType("image/png")) before calling if it matters.
    public func sendBytes(data: Array<UInt8>): Unit {
        this.bodyBytes = Some(data)
        this.finished = true
    }

    // Stream a response: flush status + headers (set them before calling), then
    // push chunks via the StreamWriter for as long as `body` runs. Omits
    // Content-Length; the connection closes when `body` returns. Set any headers
    // (e.g. Content-Type) before calling.
    public func stream(body: (StreamWriter) -> Unit): Unit {
        this.hijacked = true
        this.finished = true
        let writer = StreamWriter(this)
        writer.begin()
        body(writer)
    }

    // Server-Sent Events stream. Sets the text/event-stream headers, then hands
    // an SseWriter to `body` to push events. The connection closes when `body`
    // returns (browsers' EventSource will then reconnect).
    public func sse(body: (SseWriter) -> Unit): Unit {
        this.headers["Content-Type"] = "text/event-stream; charset=utf-8"
        this.headers["Cache-Control"] = "no-cache"
        this.headers["Connection"] = "keep-alive"
        this.stream({ w: StreamWriter => body(SseWriter(w)) })
    }

    // Send a JSON body (already-serialized string) and finish the response.
    public func json(payload: String): Unit {
        this.headers["Content-Type"] = "application/json; charset=utf-8"
        this.body = payload
        this.finished = true
    }

    // Serialize a JsonValue and send it as the JSON body.
    public func json(value: JsonValue): Unit {
        json(value.toJsonString())
    }

    // Convenience: send a JSON object built with the JsonObj builder.
    public func json(value: JsonObj): Unit {
        json(value.toJsonString())
    }

    // Finish with the current status/body but no new content.
    public func end(): Unit {
        this.finished = true
    }

    // Send only a status code with an empty body.
    public func sendStatus(code: Int64): Unit {
        status(code)
        this.body = this.statusMessage
        this.finished = true
    }

    // Set a redirect.
    public func redirect(location: String): Unit {
        status(302)
        this.headers["Location"] = location
        this.body = ""
        this.finished = true
    }
}

// Expand a content-type shorthand ("json", "html", "text", ...) to a full MIME
// type. A value already containing "/" is returned unchanged.
public func contentTypeFor(value: String): String {
    if (value.contains("/")) {
        return value
    }
    let n = value.toAsciiLower()
    if (n == "json") {
        return "application/json; charset=utf-8"
    } else if (n == "html") {
        return "text/html; charset=utf-8"
    } else if (n == "text" || n == "txt") {
        return "text/plain; charset=utf-8"
    } else if (n == "css") {
        return "text/css"
    } else if (n == "js") {
        return "application/javascript"
    } else if (n == "xml") {
        return "application/xml"
    } else {
        return "application/octet-stream"
    }
}
