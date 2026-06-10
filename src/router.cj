package wen

import std.collection.*
import std.regex.*

/*
 * Routing core.
 *
 * A compiled path pattern is a list of segments. Each segment is one of:
 *   - Literal("users")  : must match exactly
 *   - Param("id")       : matches any single segment, captured as a parameter
 *   - Wildcard          : "*" matches the remaining path (greedy tail match)
 *
 * Patterns support two matching modes:
 *   - exact   : used by route handlers (get/post/...), the whole path must match
 *   - prefix  : used by mounted middleware (use(path, mw)), the pattern must be
 *               a leading prefix of the request path
 */

enum SegKind {
    | Literal
    | Param
    | Wildcard
}

class Segment {
    let kind: SegKind
    let value: String           // literal text, or parameter name
    let constraint: ?Regex      // optional anchored regex for Param segments

    init(kind: SegKind, value: String) {
        this.kind = kind
        this.value = value
        this.constraint = None
    }

    init(kind: SegKind, value: String, constraint: ?Regex) {
        this.kind = kind
        this.value = value
        this.constraint = constraint
    }
}

public class PathPattern {
    let segments: ArrayList<Segment>
    let hasWildcard: Bool

    init(segments: ArrayList<Segment>, hasWildcard: Bool) {
        this.segments = segments
        this.hasWildcard = hasWildcard
    }

    public static func compile(path: String): PathPattern {
        let segs = ArrayList<Segment>()
        var wildcard = false
        for (raw in pathSegments(path)) {
            if (raw == "*") {
                segs.add(Segment(Wildcard, "*"))
                wildcard = true
            } else if (raw.startsWith(":")) {
                // ":name" or ":name(pattern)" — the optional parenthesised regex
                // constrains that single segment (Express-style). The pattern is
                // anchored so it must match the whole segment.
                let spec = raw[1..raw.size]
                match (spec.indexOf("(")) {
                    case Some(p) =>
                        if (spec.endsWith(")")) {
                            let name = spec[0..p]
                            let pat = spec[(p + 1)..(spec.size - 1)]
                            segs.add(Segment(Param, name, Some(Regex("^(?:" + pat + ")$"))))
                        } else {
                            segs.add(Segment(Param, spec))
                        }
                    case None =>
                        segs.add(Segment(Param, spec))
                }
            } else {
                segs.add(Segment(Literal, raw))
            }
        }
        return PathPattern(segs, wildcard)
    }

    // Exact match. Returns captured params on success, None on failure.
    public func matchExact(path: String): ?HashMap<String, String> {
        return doMatch(pathSegments(path), false)
    }

    // Prefix match used for mounted middleware.
    public func matchPrefix(path: String): ?HashMap<String, String> {
        return doMatch(pathSegments(path), true)
    }

    private func doMatch(parts: Array<String>, prefix: Bool): ?HashMap<String, String> {
        let params = HashMap<String, String>()
        var i = 0
        while (i < segments.size) {
            let seg = segments[i]
            match (seg.kind) {
                case Wildcard =>
                    // Wildcard consumes everything that remains.
                    return params
                case _ => ()
            }
            if (i >= parts.size) {
                return None
            }
            let part = parts[i]
            match (seg.kind) {
                case Literal =>
                    if (seg.value != part) {
                        return None
                    }
                case Param =>
                    match (seg.constraint) {
                        case Some(rx) =>
                            if (!rx.matches(part)) {
                                return None
                            }
                        case None => ()
                    }
                    // Captured params are URL-decoded (e.g. "john%20doe" -> "john doe").
                    params[seg.value] = urlDecode(part)
                case Wildcard => ()
            }
            i += 1
        }
        // All pattern segments consumed.
        if (prefix) {
            // Extra request segments are allowed when mounting middleware.
            return params
        }
        if (parts.size == segments.size) {
            return params
        }
        return None
    }
}

// One registered routing layer: a method filter, a compiled pattern, the
// handler to run, and whether it is a mounted (prefix) middleware.
class Layer {
    let method: ?String        // None matches any method
    let pattern: PathPattern
    let handler: Middleware
    let isPrefix: Bool
    let isError: Bool
    let errorHandler: ?ErrorHandler

    init(method: ?String, path: String, handler: Middleware, isPrefix: Bool) {
        this.method = method
        this.pattern = PathPattern.compile(path)
        this.handler = handler
        this.isPrefix = isPrefix
        this.isError = false
        this.errorHandler = None
    }

    // Error-handling layer: matches any request but only runs while an error is
    // in flight (see Router.dispatch).
    init(errorHandler: ErrorHandler) {
        this.method = None
        this.pattern = PathPattern.compile("/")
        this.handler = { _: HttpRequest, _: HttpResponse, _: Next => () }
        this.isPrefix = false
        this.isError = true
        this.errorHandler = Some(errorHandler)
    }

    // If this layer matches the request, return captured params; else None.
    func tryMatch(req: HttpRequest): ?HashMap<String, String> {
        if (this.isError) {
            // Error layers are method/path agnostic; selection happens in dispatch.
            return Some(HashMap<String, String>())
        }
        match (this.method) {
            case Some(m) =>
                if (m != HttpMethod.ALL && m != req.method) {
                    return None
                }
            case None => ()
        }
        if (this.isPrefix) {
            return this.pattern.matchPrefix(req.path)
        }
        return this.pattern.matchExact(req.path)
    }
}

public class Router {
    let layers: ArrayList<Layer> = ArrayList<Layer>()

    public init() {}

    func add(method: ?String, path: String, handler: Middleware, isPrefix: Bool): Unit {
        layers.add(Layer(method, path, handler, isPrefix))
    }

    // Global middleware (runs for every request).
    public func use(handler: Middleware): Unit {
        add(None, "/", handler, true)
    }

    // Mounted middleware (runs for requests under `path`).
    public func use(path: String, handler: Middleware): Unit {
        add(None, path, handler, true)
    }

    public func get(path: String, handler: Middleware): Unit { add(Some(HttpMethod.GET), path, handler, false) }
    public func post(path: String, handler: Middleware): Unit { add(Some(HttpMethod.POST), path, handler, false) }
    public func put(path: String, handler: Middleware): Unit { add(Some(HttpMethod.PUT), path, handler, false) }
    public func delete(path: String, handler: Middleware): Unit { add(Some(HttpMethod.DELETE), path, handler, false) }
    public func patch(path: String, handler: Middleware): Unit { add(Some(HttpMethod.PATCH), path, handler, false) }
    public func head(path: String, handler: Middleware): Unit { add(Some(HttpMethod.HEAD), path, handler, false) }
    public func options(path: String, handler: Middleware): Unit { add(Some(HttpMethod.OPTIONS), path, handler, false) }
    public func all(path: String, handler: Middleware): Unit { add(Some(HttpMethod.ALL), path, handler, false) }

    // Terminal Handler form (no `next`), mirroring Application's overloads.
    public func get(path: String, handler: Handler): Unit { add(Some(HttpMethod.GET), path, wrap(handler), false) }
    public func post(path: String, handler: Handler): Unit { add(Some(HttpMethod.POST), path, wrap(handler), false) }
    public func put(path: String, handler: Handler): Unit { add(Some(HttpMethod.PUT), path, wrap(handler), false) }
    public func delete(path: String, handler: Handler): Unit { add(Some(HttpMethod.DELETE), path, wrap(handler), false) }
    public func patch(path: String, handler: Handler): Unit { add(Some(HttpMethod.PATCH), path, wrap(handler), false) }
    public func head(path: String, handler: Handler): Unit { add(Some(HttpMethod.HEAD), path, wrap(handler), false) }
    public func options(path: String, handler: Handler): Unit { add(Some(HttpMethod.OPTIONS), path, wrap(handler), false) }
    public func all(path: String, handler: Handler): Unit { add(Some(HttpMethod.ALL), path, wrap(handler), false) }

    private func wrap(handler: Handler): Middleware {
        return { req: HttpRequest, res: HttpResponse, _: Next => handler(req, res) }
    }

    // Register an error-handling middleware. It runs only while an exception is
    // in flight; register it after the routes whose errors it should catch.
    public func useError(handler: ErrorHandler): Unit {
        layers.add(Layer(handler))
    }

    // Run the middleware/route chain for a request. When nothing finishes the
    // response: a path with no routes at all -> 404; a path that exists for
    // other methods -> 405 (or 204 for OPTIONS) with an Allow header. A HEAD
    // request with no HEAD route falls back to the GET route, headers only.
    public func handle(req: HttpRequest, res: HttpResponse): Unit {
        if (req.method == HttpMethod.HEAD && !hasMethodForPath(HttpMethod.HEAD, req.path) &&
            hasMethodForPath(HttpMethod.GET, req.path)) {
            req.method = HttpMethod.GET
            dispatchTop(req, res)
            req.method = HttpMethod.HEAD
            if (res.finished && !res.hijacked) {
                let len = match (res.bodyBytes) {
                    case Some(b) => b.size
                    case None => res.body.toArray().size
                }
                res.headers["Content-Length"] = len.toString()
                res.body = ""
                res.bodyBytes = None
                res.suppressBody = true
            }
            return
        }
        dispatchTop(req, res)
    }

    private func dispatchTop(req: HttpRequest, res: HttpResponse): Unit {
        let onExhausted: Next = { =>
            if (!res.finished) {
                let methods = methodsForPath(req.path)
                if (methods.isEmpty()) {
                    res.status(404).send("Cannot ${req.method} ${req.path}")
                } else if (req.method == HttpMethod.OPTIONS) {
                    res.set("Allow", allowHeader(req.path)).status(204).end()
                } else {
                    res.set("Allow", allowHeader(req.path)).status(405).send("Method Not Allowed")
                }
            }
        }
        let onError: (Exception) -> Unit = { _: Exception =>
            if (!res.finished) {
                res.status(500).send("Internal Server Error")
            }
        }
        runChain(req, res, onExhausted, onError)
    }

    // Distinct explicit methods of route layers whose path matches (excludes
    // middleware, error layers and wildcard-method `all` routes).
    func methodsForPath(path: String): ArrayList<String> {
        let out = ArrayList<String>()
        for (layer in layers) {
            if (layer.isError || layer.isPrefix) {
                continue
            }
            match (layer.method) {
                case Some(m) =>
                    if (m == HttpMethod.ALL) {
                        continue
                    }
                    match (layer.pattern.matchExact(path)) {
                        case Some(_) =>
                            if (!listContains(out, m)) {
                                out.add(m)
                            }
                        case None => ()
                    }
                case None => ()
            }
        }
        return out
    }

    func hasMethodForPath(method: String, path: String): Bool {
        for (layer in layers) {
            if (layer.isError || layer.isPrefix) {
                continue
            }
            match (layer.method) {
                case Some(m) =>
                    if (m == method || m == HttpMethod.ALL) {
                        match (layer.pattern.matchExact(path)) {
                            case Some(_) => return true
                            case None => ()
                        }
                    }
                case None => ()
            }
        }
        return false
    }

    // Allow header value: registered methods plus implicit OPTIONS (and HEAD
    // when GET is present).
    func allowHeader(path: String): String {
        let methods = methodsForPath(path)
        if (!listContains(methods, HttpMethod.OPTIONS)) {
            methods.add(HttpMethod.OPTIONS)
        }
        if (listContains(methods, HttpMethod.GET) && !listContains(methods, HttpMethod.HEAD)) {
            methods.add(HttpMethod.HEAD)
        }
        var s = ""
        var first = true
        for (m in methods) {
            if (first) {
                s += m
                first = false
            } else {
                s += ", " + m
            }
        }
        return s
    }

    // Run this router as a piece of mounted middleware (a "mini-app"). If no
    // internal layer finishes the response, control passes to `next` so the
    // parent chain continues; an uncaught error is re-thrown so the parent's
    // error pipeline can handle it.
    func handleAsMiddleware(req: HttpRequest, res: HttpResponse, next: Next): Unit {
        let onError: (Exception) -> Unit = { e: Exception => throw e }
        runChain(req, res, next, onError)
    }

    private func runChain(req: HttpRequest, res: HttpResponse, onExhausted: Next, onError: (Exception) -> Unit): Unit {
        let matched = ArrayList<Layer>()
        for (layer in layers) {
            match (layer.tryMatch(req)) {
                case Some(_) => matched.add(layer)
                case None => ()
            }
        }
        dispatch(matched, 0, req, res, onExhausted, onError, None)
    }

    func dispatch(matched: ArrayList<Layer>, index: Int64, req: HttpRequest, res: HttpResponse,
                  onExhausted: Next, onError: (Exception) -> Unit, err: ?Exception): Unit {
        if (res.finished) {
            return
        }
        if (index >= matched.size) {
            match (err) {
                case Some(e) => onError(e)
                case None => onExhausted()
            }
            return
        }
        let layer = matched[index]
        match (err) {
            case Some(e) =>
                // Error mode: skip ordinary layers, run only error handlers.
                if (!layer.isError) {
                    dispatch(matched, index + 1, req, res, onExhausted, onError, err)
                    return
                }
                let next: Next = { => dispatch(matched, index + 1, req, res, onExhausted, onError, Some(e)) }
                try {
                    match (layer.errorHandler) {
                        case Some(h) => h(e, req, res, next)
                        case None => next()
                    }
                } catch (e2: Exception) {
                    dispatch(matched, index + 1, req, res, onExhausted, onError, Some(e2))
                }
            case None =>
                // Normal mode: skip error handlers, run ordinary layers.
                if (layer.isError) {
                    dispatch(matched, index + 1, req, res, onExhausted, onError, None)
                    return
                }
                runNormal(matched, index, layer, req, res, onExhausted, onError)
        }
    }

    private func runNormal(matched: ArrayList<Layer>, index: Int64, layer: Layer, req: HttpRequest, res: HttpResponse,
                           onExhausted: Next, onError: (Exception) -> Unit): Unit {
        // Re-apply this layer's captured params (each layer may capture different ones).
        match (layer.tryMatch(req)) {
            case Some(params) =>
                for ((k, v) in params) {
                    req.params[k] = v
                }
            case None => ()
        }
        // Mounted middleware (use(path, mw)) sees the path with its mount prefix
        // stripped, mirroring Express. The original path is restored before the
        // rest of the chain runs, so downstream routes still match in full.
        if (layer.isPrefix && layer.pattern.segments.size > 0) {
            let savedPath = req.path
            req.path = stripMountPath(req.path, layer.pattern.segments.size)
            let next: Next = { =>
                req.path = savedPath
                dispatch(matched, index + 1, req, res, onExhausted, onError, None)
            }
            try {
                layer.handler(req, res, next)
            } catch (ex: Exception) {
                req.path = savedPath
                dispatch(matched, index + 1, req, res, onExhausted, onError, Some(ex))
                return
            }
            req.path = savedPath
        } else {
            let next: Next = { => dispatch(matched, index + 1, req, res, onExhausted, onError, None) }
            try {
                layer.handler(req, res, next)
            } catch (ex: Exception) {
                dispatch(matched, index + 1, req, res, onExhausted, onError, Some(ex))
            }
        }
    }

    // Drop the first `mountSegments` path segments and rebuild the remainder,
    // e.g. stripMountPath("/static/css/app.css", 1) -> "/css/app.css".
    func stripMountPath(path: String, mountSegments: Int64): String {
        let parts = pathSegments(path)
        if (parts.size <= mountSegments) {
            return "/"
        }
        var rebuilt = ""
        var i = mountSegments
        while (i < parts.size) {
            rebuilt += "/" + parts[i]
            i += 1
        }
        return rebuilt
    }
}
