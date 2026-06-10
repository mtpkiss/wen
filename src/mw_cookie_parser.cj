package wen

/*
 * Cookie parser middleware.
 *
 * Reads the `Cookie` request header and splits it into individual name=value
 * pairs, storing them on `req.cookies` for downstream handlers to read via
 * `req.cookie(name)`. Mirrors Express's cookie-parser.
 */

public func cookieParser(): Middleware {
    return { req: HttpRequest, _: HttpResponse, next: Next =>
        match (req.header("cookie")) {
            case Some(raw) =>
                for (pair in raw.split(";")) {
                    let p = pair.trimAscii()
                    if (p.isEmpty()) {
                        continue
                    }
                    let (k, v) = splitOnce(p, "=")
                    req.cookies[k.trimAscii()] = v.trimAscii()
                }
            case None => ()
        }
        next()
    }
}
