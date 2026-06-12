package wen

import std.net.*
import std.collection.*
import std.sync.*

// Raised when an incoming request body exceeds the configured maximum, mapped
// to a 413 response by the server.
public class PayloadTooLargeException <: Exception {
    public init() {
        super("Payload Too Large")
    }
}

// Raised on malformed framing (e.g. both Content-Length and Transfer-Encoding
// present, a request-smuggling vector), mapped to a 400 response by the server.
public class BadRequestException <: Exception {
    public init() {
        super("Bad Request")
    }
}

/*
 * A minimal HTTP/1.1 server built directly on TCP sockets. It parses the raw
 * request, hands an (HttpRequest, HttpResponse) pair to the application's
 * middleware chain, then serializes the finished response back to the socket.
 *
 * Each connection is handled on its own lightweight thread via `spawn`.
 */
// Wraps a TCP socket so streaming handlers can write to the live connection
// through the ResponseConnection interface.
class SocketConnection <: ResponseConnection {
    let sock: TcpSocket

    init(sock: TcpSocket) {
        this.sock = sock
    }

    public func write(data: Array<UInt8>): Unit {
        sock.write(data)
    }

    public func close(): Unit {
        sock.close()
    }
}

public class HttpServer {
    let app: Application

    // Maximum accepted request body size in bytes (default 1 MiB).
    public var maxBodySize: Int64 = 1048576
    // Per-read socket timeout in milliseconds, guarding against slow/idle peers.
    public var readTimeoutMs: Int64 = 15000
    // Maximum number of connections served concurrently (default 1024). Bounds
    // the thread count so a connection flood cannot exhaust resources.
    public var maxConnections: Int64 = 1024

    public init(app: Application) {
        this.app = app
    }

    public func listen(port: Int64): Unit {
        let server = TcpServerSocket(bindAt: UInt16(port))
        server.bind()
        // Bound concurrency: the accept loop blocks once `maxConnections` are in
        // flight (the OS backlog absorbs the wait) and resumes as handlers free
        // their slot, so a flood cannot spawn unbounded threads.
        let slots = Semaphore(maxConnections)
        while (true) {
            slots.acquire()
            let client = server.accept()
            spawn {
                try {
                    handleConnection(client)
                } finally {
                    slots.release()
                }
            }
        }
    }

    func handleConnection(client: TcpSocket): Unit {
        client.readTimeout = Duration.millisecond * readTimeoutMs
        let reader = ConnReader(client, maxBodySize)
        try {
            while (true) {
                // None => clean end of stream / idle timeout: stop serving this
                // connection without emitting an error.
                let raw = match (reader.readMessage()) {
                    case Some(m) => m
                    case None => break
                }
                let req = parseRequest(raw)
                req.ip = remoteIp(client)
                let res = HttpResponse()
                res.conn = Some(SocketConnection(client))
                app.handle(req, res)
                if (!res.finished) {
                    res.status(404).send("Not Found")
                }
                // A streaming handler wrote directly to the socket; the stream is
                // connection-delimited, so close afterwards.
                if (res.hijacked) {
                    break
                }
                let keepAlive = shouldKeepAlive(req)
                res.headers["Connection"] = if (keepAlive) {
                    "keep-alive"
                } else {
                    "close"
                }
                client.write(serializeResponse(res))
                if (!keepAlive) {
                    break
                }
            }
        } catch (_: PayloadTooLargeException) {
            writeError(client, 413, "Payload Too Large")
        } catch (_: BadRequestException) {
            writeError(client, 400, "Bad Request")
        } catch (_: Exception) {
            writeError(client, 500, "Internal Server Error")
        } finally {
            client.close()
        }
    }

    // HTTP/1.1 defaults to keep-alive; HTTP/1.0 defaults to close. An explicit
    // Connection header overrides the default.
    func shouldKeepAlive(req: HttpRequest): Bool {
        match (req.header("connection")) {
            case Some(v) =>
                let lv = v.toAsciiLower()
                if (lv.contains("close")) {
                    return false
                }
                if (lv.contains("keep-alive")) {
                    return true
                }
            case None => ()
        }
        return req.httpVersion.trimAscii().contains("1.1")
    }

    func writeError(client: TcpSocket, code: Int64, message: String): Unit {
        try {
            let res = HttpResponse()
            res.status(code).send(message)
            client.write(serializeResponse(res))
        } catch (_: Exception) {
            ()
        }
    }

    // The peer's IP address (without port), or "" if unavailable. For a
    // bracketed IPv6 literal "[::1]:p" the inner "::1" is returned.
    func remoteIp(client: TcpSocket): String {
        try {
            let s = client.remoteAddress.toString()
            if (s.startsWith("[")) {
                match (s.indexOf("]")) {
                    case Some(i) => return s[1..i]
                    case None => return s
                }
            }
            let (host, _) = splitOnce(s, ":")
            return host
        } catch (_: Exception) {
            return ""
        }
    }

    func parseRequest(raw: Array<UInt8>): HttpRequest {
        // Split header bytes from body bytes at the "\r\n\r\n" boundary.
        let sep = indexOfHeaderEndArr(raw)
        let headerEnd = match (sep) {
            case Some(p) => p
            case None => raw.size
        }
        let bodyStart = match (sep) {
            case Some(p) => p + 4
            case None => raw.size
        }
        let headerPart = String.fromUtf8(subArray(raw, 0, headerEnd))
        let bodyBytes = subArray(raw, bodyStart, raw.size)

        let lines = headerPart.split("\r\n")
        let requestLine = lines[0]

        let (method, afterMethod) = splitOnce(requestLine, " ")
        let (target, version) = splitOnce(afterMethod, " ")

        let req = HttpRequest(method, target)
        req.httpVersion = version

        let (path, queryString) = splitOnce(target, "?")
        req.path = path
        parseQuery(queryString, req.query)

        var i = 1
        while (i < lines.size) {
            let line = lines[i]
            if (!line.isEmpty()) {
                let (key, value) = splitOnce(line, ":")
                req.headers[key.toAsciiLower().trimAscii()] = value.trimAscii()
            }
            i += 1
        }

        req.bodyBytes = bodyBytes
        req.body = String.fromUtf8(bodyBytes)
        return req
    }

    // Array variant of indexOfHeaderEnd.
    func indexOfHeaderEndArr(buf: Array<UInt8>): ?Int64 {
        var i = 0
        while (i + 3 < buf.size) {
            if (buf[i] == UInt8(13) && buf[i + 1] == UInt8(10) &&
                buf[i + 2] == UInt8(13) && buf[i + 3] == UInt8(10)) {
                return Some(i)
            }
            i += 1
        }
        return None
    }

    // Copy src[start..end) into a fresh Array<UInt8>.
    func subArray(src: Array<UInt8>, start: Int64, end: Int64): Array<UInt8> {
        if (end <= start) {
            return Array<UInt8>()
        }
        let out = Array<UInt8>(end - start, repeat: 0)
        var i = start
        while (i < end) {
            out[i - start] = src[i]
            i += 1
        }
        return out
    }

    func serializeResponse(res: HttpResponse): Array<UInt8> {
        // 204 No Content and 304 Not Modified carry neither a body nor a
        // Content-Length header, per RFC 7230.
        let bodyless = res.statusCode == 204 || res.statusCode == 304
        // For a HEAD response, keep the Content-Length already set (the GET body
        // size) but emit no body. Otherwise compute it from the actual body.
        let bodyBytes = if (res.suppressBody) {
            Array<UInt8>()
        } else if (bodyless) {
            res.headers.remove("Content-Length")
            Array<UInt8>()
        } else {
            let real = match (res.bodyBytes) {
                case Some(raw) => raw
                case None => res.body.toArray()
            }
            res.headers["Content-Length"] = real.size.toString()
            real
        }

        var head = "HTTP/1.1 ${res.statusCode} ${res.statusMessage}\r\n"
        for ((k, v) in res.headers) {
            head += "${k}: ${v}\r\n"
        }
        // Each queued cookie gets its own Set-Cookie line.
        for (c in res.setCookies) {
            head += "Set-Cookie: ${c}\r\n"
        }
        head += "\r\n"

        let headBytes = head.toArray()
        let total = Array<UInt8>(headBytes.size + bodyBytes.size, repeat: 0)
        var i = 0
        while (i < headBytes.size) {
            total[i] = headBytes[i]
            i += 1
        }
        var j = 0
        while (j < bodyBytes.size) {
            total[headBytes.size + j] = bodyBytes[j]
            j += 1
        }
        return total
    }
}

/*
 * Buffered reader that extracts one HTTP message at a time from a socket,
 * retaining leftover bytes between requests so a single connection can serve
 * many requests (keep-alive). Supports both Content-Length and chunked bodies.
 */
class ConnReader {
    let sock: TcpSocket
    let maxBodySize: Int64
    let buf: ArrayList<UInt8> = ArrayList<UInt8>()
    let tmp: Array<UInt8> = Array<UInt8>(4096, repeat: 0)

    init(sock: TcpSocket, maxBodySize: Int64) {
        this.sock = sock
        this.maxBodySize = maxBodySize
    }

    // Pull more bytes from the socket. Returns false on EOF/timeout/error.
    func fill(): Bool {
        try {
            let n = sock.read(tmp)
            if (n <= 0) {
                return false
            }
            var i = 0
            while (i < n) {
                buf.add(tmp[i])
                i += 1
            }
            return true
        } catch (_: Exception) {
            return false
        }
    }

    // Read one full request as reconstructed bytes (header section + body), or
    // None at clean end-of-stream / on an incomplete message.
    func readMessage(): ?Array<UInt8> {
        var sep = headerSeparatorIndex(buf)
        while (sep < 0) {
            if (buf.size > maxBodySize + 65536) {
                throw PayloadTooLargeException()
            }
            if (!fill()) {
                return None
            }
            sep = headerSeparatorIndex(buf)
        }
        let headerSectionEnd = sep + 4
        let headerText = String.fromUtf8(sliceList(buf, 0, sep))

        let chunked = headerIsChunked(headerText)
        if (chunked && headerHasContentLength(headerText)) {
            // Both Transfer-Encoding and Content-Length present: ambiguous
            // framing and a classic request-smuggling vector (RFC 7230 §3.3.3).
            throw BadRequestException()
        }
        if (chunked) {
            return readChunked(headerSectionEnd)
        }

        let contentLength = headerContentLength(headerText)
        if (contentLength > maxBodySize) {
            throw PayloadTooLargeException()
        }
        while (buf.size < headerSectionEnd + contentLength) {
            if (!fill()) {
                return None
            }
        }
        let total = headerSectionEnd + contentLength
        let msg = sliceList(buf, 0, total)
        dropFront(buf, total)
        return Some(msg)
    }

    // Decode a chunked body and rebuild "header section + decoded body" so the
    // rest of the pipeline sees a plain Content-Length-style message.
    func readChunked(headerSectionEnd: Int64): ?Array<UInt8> {
        let body = ArrayList<UInt8>()
        var pos = headerSectionEnd
        while (true) {
            var lineEnd = findCRLF(buf, pos)
            while (lineEnd < 0) {
                if (!fill()) {
                    return None
                }
                lineEnd = findCRLF(buf, pos)
            }
            let size = parseHexLen(String.fromUtf8(sliceList(buf, pos, lineEnd)))
            pos = lineEnd + 2
            if (size == 0) {
                // Final chunk: consume the trailing CRLF (trailers unsupported).
                var endLine = findCRLF(buf, pos)
                while (endLine < 0) {
                    if (!fill()) {
                        break
                    }
                    endLine = findCRLF(buf, pos)
                }
                if (endLine >= 0) {
                    pos = endLine + 2
                }
                break
            }
            if (body.size + size > maxBodySize) {
                throw PayloadTooLargeException()
            }
            while (buf.size < pos + size + 2) {
                if (!fill()) {
                    return None
                }
            }
            var i = 0
            while (i < size) {
                body.add(buf[pos + i])
                i += 1
            }
            pos += size + 2
        }
        let headerSection = sliceList(buf, 0, headerSectionEnd)
        dropFront(buf, pos)
        let result = ArrayList<UInt8>()
        for (b in headerSection) {
            result.add(b)
        }
        for (b in body) {
            result.add(b)
        }
        return Some(result.toArray())
    }
}

// Index of the "\r\n\r\n" header/body separator, or -1.
func headerSeparatorIndex(buf: ArrayList<UInt8>): Int64 {
    var i = 0
    while (i + 3 < buf.size) {
        if (buf[i] == UInt8(13) && buf[i + 1] == UInt8(10) &&
            buf[i + 2] == UInt8(13) && buf[i + 3] == UInt8(10)) {
            return i
        }
        i += 1
    }
    return -1
}

// Index of the next "\r\n" at or after `from`, or -1.
func findCRLF(buf: ArrayList<UInt8>, from: Int64): Int64 {
    var i = if (from < 0) {
        0
    } else {
        from
    }
    while (i + 1 < buf.size) {
        if (buf[i] == UInt8(13) && buf[i + 1] == UInt8(10)) {
            return i
        }
        i += 1
    }
    return -1
}

// Copy buf[start..end) into a fresh Array<UInt8>.
func sliceList(buf: ArrayList<UInt8>, start: Int64, end: Int64): Array<UInt8> {
    if (end <= start) {
        return Array<UInt8>()
    }
    let out = Array<UInt8>(end - start, repeat: 0)
    var i = start
    while (i < end) {
        out[i - start] = buf[i]
        i += 1
    }
    return out
}

// Drop the first `n` bytes from `buf`, keeping the remainder.
func dropFront(buf: ArrayList<UInt8>, n: Int64): Unit {
    if (n <= 0) {
        return
    }
    if (n >= buf.size) {
        buf.clear()
        return
    }
    let rest = ArrayList<UInt8>()
    var i = n
    while (i < buf.size) {
        rest.add(buf[i])
        i += 1
    }
    buf.clear()
    for (b in rest) {
        buf.add(b)
    }
}

// Content-Length header value, or 0 if absent.
func headerContentLength(headerText: String): Int64 {
    for (line in headerText.split("\r\n")) {
        let (k, v) = splitOnce(line, ":")
        if (k.toAsciiLower().trimAscii() == "content-length") {
            return parseInt(v.trimAscii())
        }
    }
    return 0
}

// Whether the header block declares a Content-Length.
func headerHasContentLength(headerText: String): Bool {
    for (line in headerText.split("\r\n")) {
        let (k, _) = splitOnce(line, ":")
        if (k.toAsciiLower().trimAscii() == "content-length") {
            return true
        }
    }
    return false
}

// Whether the request declares a chunked transfer encoding.
func headerIsChunked(headerText: String): Bool {
    for (line in headerText.split("\r\n")) {
        let (k, v) = splitOnce(line, ":")
        if (k.toAsciiLower().trimAscii() == "transfer-encoding") {
            return v.toAsciiLower().contains("chunked")
        }
    }
    return false
}

// Parse a hex chunk-size line (ignoring any ";ext" suffix).
func parseHexLen(s: String): Int64 {
    var result = 0
    for (c in s.toArray()) {
        var d = -1
        if (c >= UInt8(48) && c <= UInt8(57)) {
            d = Int64(c) - 48
        } else if (c >= UInt8(65) && c <= UInt8(70)) {
            d = Int64(c) - 55
        } else if (c >= UInt8(97) && c <= UInt8(102)) {
            d = Int64(c) - 87
        } else {
            break
        }
        result = result * 16 + d
    }
    return result
}

// Parse a query string ("a=1&b=2") into a map, URL-decoding keys and values.
public func parseQuery(qs: String, into: HashMap<String, String>): Unit {
    if (qs.isEmpty()) {
        return
    }
    for (pair in qs.split("&")) {
        if (pair.isEmpty()) {
            continue
        }
        let (k, v) = splitOnce(pair, "=")
        into[urlDecode(k)] = urlDecode(v)
    }
}

// A best-effort base-10 integer parse that ignores trailing junk.
public func parseInt(s: String): Int64 {
    var result = 0
    let bytes = s.toArray()
    var i = 0
    var any = false
    while (i < bytes.size) {
        let b = bytes[i]
        if (b >= UInt8(48) && b <= UInt8(57)) {
            result = result * 10 + (Int64(b) - 48)
            any = true
        } else {
            break
        }
        i += 1
    }
    if (any) {
        return result
    }
    return 0
}

func hexVal(b: UInt8): Int64 {
    if (b >= UInt8(48) && b <= UInt8(57)) {
        return Int64(b) - 48
    }
    if (b >= UInt8(65) && b <= UInt8(70)) {
        return Int64(b) - 65 + 10
    }
    if (b >= UInt8(97) && b <= UInt8(102)) {
        return Int64(b) - 97 + 10
    }
    return 0
}

// Decode percent-encoding and '+' in URL components. Decoded bytes are
// accumulated and interpreted as UTF-8 only at the end, so a multi-byte
// sequence (e.g. "%E4%B8%AD" -> "中") is reassembled intact instead of being
// corrupted by decoding each byte on its own.
public func urlDecode(s: String): String {
    let bytes = s.toArray()
    let out = ArrayList<UInt8>()
    var i = 0
    while (i < bytes.size) {
        let c = bytes[i]
        if (c == UInt8(37) && i + 2 < bytes.size) {        // '%'
            let code = hexVal(bytes[i + 1]) * 16 + hexVal(bytes[i + 2])
            out.add(UInt8(code))
            i += 3
        } else if (c == UInt8(43)) {                       // '+'
            out.add(UInt8(32))                             // space
            i += 1
        } else {
            out.add(c)
            i += 1
        }
    }
    return String.fromUtf8(out.toArray())
}
