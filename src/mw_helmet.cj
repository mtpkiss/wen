package wen

/*
 * 安全响应头中间件(对标 Node 生态里的 helmet)。
 *
 * 它本身不做任何「处理」,只是在响应上批量加一组有助于防御常见 Web 攻击的安全头,
 * 然后照常 next() 继续。应尽量靠前注册(在路由之前),这样每个响应都带上这些头。
 *
 * 默认下发的头:
 *   - Content-Security-Policy          : 内容安全策略,限制资源来源,缓解 XSS/注入。
 *   - X-Content-Type-Options: nosniff  : 禁止浏览器对响应做 MIME 嗅探。
 *   - X-Frame-Options: SAMEORIGIN      : 限制被 <iframe> 嵌入,防点击劫持。
 *   - Strict-Transport-Security        : HSTS,强制后续走 HTTPS。
 *   - Referrer-Policy: no-referrer      : 不携带 Referer,减少信息泄露。
 *   - Cross-Origin-Opener-Policy        : 跨源打开隔离。
 *   - Cross-Origin-Resource-Policy      : 限制资源被跨源站点读取。
 *
 * 常用定制通过具名参数完成(都有合理默认);把某个字符串参数设为空串、或把布尔设为
 * false,即表示「不发送该头」。需要更细的策略时,也可在 helmet 之后再用普通中间件
 * 覆盖具体的头。
 */
public func helmet(
    csp!: String = "default-src 'self'; object-src 'none'; frame-ancestors 'self'",
    hsts!: Bool = true,
    frameOptions!: String = "SAMEORIGIN",
    referrerPolicy!: String = "no-referrer",
    noSniff!: Bool = true
): Middleware {
    return { _: HttpRequest, res: HttpResponse, next: Next =>
        if (!csp.isEmpty()) {
            res.headers["Content-Security-Policy"] = csp
        }
        if (noSniff) {
            res.headers["X-Content-Type-Options"] = "nosniff"
        }
        if (!frameOptions.isEmpty()) {
            res.headers["X-Frame-Options"] = frameOptions
        }
        if (!referrerPolicy.isEmpty()) {
            res.headers["Referrer-Policy"] = referrerPolicy
        }
        if (hsts) {
            // max-age 约 180 天,并涵盖子域名。
            res.headers["Strict-Transport-Security"] = "max-age=15552000; includeSubDomains"
        }
        res.headers["Cross-Origin-Opener-Policy"] = "same-origin"
        res.headers["Cross-Origin-Resource-Policy"] = "same-origin"

        next()
    }
}
