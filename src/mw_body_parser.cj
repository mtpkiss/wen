package wen


/*
 * Body-parsing middleware factories.
 *
 * These inspect the request's Content-Type and decode the raw `body` into a
 * form middleware downstream can consume. The framework has no JSON value type,
 * so JSON bodies are kept as the raw string; url-encoded forms are exploded
 * into per-field attributes. Both always advance the chain.
 */

// Parses application/x-www-form-urlencoded bodies, exposing each form field as
// a request attribute. Non-matching requests pass through untouched.
public func urlencodedParser(): Middleware {
    return { req: HttpRequest, _: HttpResponse, next: Next =>
        // Option header lookup: only parse when the type actually matches.
        match (req.header("content-type")) {
            case Some(ct) =>
                if (ct.contains("application/x-www-form-urlencoded")) {
                    parseQuery(req.body, req.attributes)
                }
            case None => ()
        }
        next()
    }
}

// Marks application/json bodies by storing the raw JSON under attribute "json".
// We keep the raw text because the framework lacks a JSON value type.
public func jsonParser(): Middleware {
    return { req: HttpRequest, _: HttpResponse, next: Next =>
        match (req.header("content-type")) {
            case Some(ct) =>
                if (ct.contains("application/json") && !req.body.isEmpty()) {
                    req.setAttribute("json", req.body)
                }
            case None => ()
        }
        next()
    }
}
