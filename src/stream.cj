package wen

/*
 * Streaming responses (the primitive behind Server-Sent Events).
 *
 * The default response model buffers a whole body and writes it once. Streaming
 * instead "hijacks" the connection: the handler flushes status + headers, then
 * pushes chunks over time while the socket stays open. The server detects a
 * hijacked response and skips its normal serialize step.
 *
 * When there is no live connection (e.g. unit tests driving app.handle directly)
 * the writer falls back to appending payload to res.body so it can be asserted.
 */

// A live connection handed to a streaming handler by the server.
public interface ResponseConnection {
    func write(data: Array<UInt8>): Unit
    func close(): Unit
}

// Incremental writer for a streaming response. Flushes status + headers on the
// first write, then forwards raw chunks to the connection.
public class StreamWriter {
    let res: HttpResponse
    var started: Bool = false

    init(res: HttpResponse) {
        this.res = res
    }

    // Flush the status line and headers exactly once (live connection only).
    func begin(): Unit {
        if (started) {
            return
        }
        started = true
        match (res.conn) {
            case Some(c) =>
                var head = "HTTP/1.1 ${res.statusCode} ${res.statusMessage}\r\n"
                for ((k, v) in res.headers) {
                    head += "${k}: ${v}\r\n"
                }
                for (ck in res.setCookies) {
                    head += "Set-Cookie: ${ck}\r\n"
                }
                head += "\r\n"
                c.write(head.toArray())
            case None => ()
        }
    }

    // Write a text chunk.
    public func write(text: String): Unit {
        writeRaw(text.toArray())
    }

    // Write a raw binary chunk.
    public func writeBytes(data: Array<UInt8>): Unit {
        writeRaw(data)
    }

    func writeRaw(data: Array<UInt8>): Unit {
        match (res.conn) {
            case Some(c) => c.write(data)
            case None => res.body += String.fromUtf8(data)
        }
    }
}

// Server-Sent Events writer: formats SSE frames on top of a StreamWriter.
public class SseWriter {
    let w: StreamWriter

    init(w: StreamWriter) {
        this.w = w
    }

    // A named event carrying `data`.
    public func event(name: String, data: String): Unit {
        w.write("event: ${name}\n")
        emitData(data)
    }

    // A default (unnamed) event carrying `data`.
    public func send(data: String): Unit {
        emitData(data)
    }

    // Set the event id for the next event (clients echo it as Last-Event-ID).
    public func id(value: String): Unit {
        w.write("id: ${value}\n")
    }

    // Suggest a client reconnection delay in milliseconds.
    public func retry(ms: Int64): Unit {
        w.write("retry: ${ms}\n\n")
    }

    // A comment line (also serves as a keep-alive ping).
    public func comment(text: String): Unit {
        w.write(": ${text}\n\n")
    }

    // Each data line is prefixed with "data: "; a blank line terminates the event.
    func emitData(data: String): Unit {
        for (line in data.split("\n")) {
            w.write("data: ${line}\n")
        }
        w.write("\n")
    }
}
