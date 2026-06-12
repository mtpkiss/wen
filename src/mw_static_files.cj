package wen

import std.fs.*

/*
 * Static file server middleware.
 *
 * Serves files from a `root` directory for GET/HEAD requests. When the request
 * path maps to an existing regular file under root, the file is sent with a
 * Content-Type guessed from its extension and the response is finished; any
 * other case calls next() so normal routing can take over. Path traversal
 * ("..") is rejected so requests can never escape `root`.
 */

// Builds a middleware that serves files out of `root`.
public func staticFiles(root: String): Middleware {
    // Cangjie's std.fs does not resolve a leading "./"; strip it so callers can
    // pass either "public" or "./public".
    let base = if (root.startsWith("./")) {
        root[2..root.size]
    } else {
        root
    }
    return { req: HttpRequest, res: HttpResponse, next: Next =>
        // Only static GET/HEAD are handled here; everything else continues.
        if (req.method != HttpMethod.GET && req.method != HttpMethod.HEAD) {
            next()
            return
        }

        var rel = if (req.path.startsWith("/")) {
            req.path[1..req.path.size]
        } else {
            req.path
        }
        if (rel.isEmpty()) {
            rel = "index.html"
        }

        // SECURITY: never allow traversal outside the served root.
        if (rel.contains("..")) {
            next()
            return
        }

        let path = "${base}/${rel}"

        // `exists` checks the path; reject directories / missing files.
        if (!exists(path)) {
            next()
            return
        }

        // Send the file's raw bytes so binary assets (images, fonts, ...) are
        // served verbatim instead of being corrupted by a UTF-8 round-trip.
        res.contentType(mimeFor(rel)).sendBytes(File.readFrom(path))
    }
}

// Guess a Content-Type from the file name's extension; falls back to a generic
// binary type for anything unrecognised.
func mimeFor(name: String): String {
    let n = name.toAsciiLower()
    if (n.endsWith(".html")) {
        return "text/html; charset=utf-8"
    } else if (n.endsWith(".css")) {
        return "text/css"
    } else if (n.endsWith(".js")) {
        return "application/javascript"
    } else if (n.endsWith(".json")) {
        return "application/json"
    } else if (n.endsWith(".png")) {
        return "image/png"
    } else if (n.endsWith(".jpg") || n.endsWith(".jpeg")) {
        return "image/jpeg"
    } else if (n.endsWith(".gif")) {
        return "image/gif"
    } else if (n.endsWith(".svg")) {
        return "image/svg+xml"
    } else if (n.endsWith(".txt")) {
        return "text/plain; charset=utf-8"
    } else {
        return "application/octet-stream"
    }
}
