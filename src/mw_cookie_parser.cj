package wen

/*
 * Cookie 解析中间件(兼容保留)。
 *
 * Cookie 解析现在是**内置**的——首次通过 req.cookie(name) / req.signedCookie(name) 读取时,
 * 框架会自动从 `Cookie` 头解析填充 req.cookies(见 HttpRequest.ensureCookies)。因此本中间件
 * 已**非必需**:保留它只是为了「提前解析」或显式表达意图,内部仅调用 req.ensureCookies()。
 */

public func cookieParser(): Middleware {
    return { req: HttpRequest, _: HttpResponse, next: Next =>
        req.ensureCookies()
        next()
    }
}
