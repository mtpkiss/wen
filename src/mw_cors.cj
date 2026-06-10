package wen


/*
 * CORS plugin.
 *
 * Adds the Access-Control-Allow-* response headers so browsers permit
 * cross-origin calls. Preflight `OPTIONS` requests are answered immediately
 * with `204 No Content` and never reach the downstream handlers.
 */

// Allow any origin ("*").
public func cors(): Middleware {
    return cors("*")
}

// Allow a single, explicit origin.
public func cors(origin: String): Middleware {
    return { req: HttpRequest, res: HttpResponse, next: Next =>
        res.set("Access-Control-Allow-Origin", origin)
        res.set("Access-Control-Allow-Methods", "GET, POST, PUT, DELETE, PATCH, OPTIONS")
        res.set("Access-Control-Allow-Headers", "Content-Type, Authorization")

        // A preflight request is fully answered here; do not call next().
        if (req.method == HttpMethod.OPTIONS) {
            res.status(204).end()
            return
        }

        next()
    }
}
