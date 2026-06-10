package wen


/*
 * Request logger plugin.
 *
 * Prints a one-line trace for every request: an arrow on the way in with the
 * method and path, and a matching arrow on the way out carrying the final
 * status code. The status is read after `next()` returns, so it reflects
 * whatever the downstream handlers ultimately set.
 */

// Builds a logging Middleware.
public func logger(): Middleware {
    return { req: HttpRequest, res: HttpResponse, next: Next =>
        println("--> ${req.method} ${req.path}")
        next()
        // Read statusCode only after the chain has run so it is up to date.
        println("<-- ${req.method} ${req.path} ${res.statusCode}")
    }
}
