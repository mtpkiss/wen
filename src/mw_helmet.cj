package wen

/*
 * 安全响应头中间件(对标 Node 生态里的 helmet)。
 *
 * 设计取向:**默认只发「部署无关、且不会误伤业务」的头**;凡是会因部署 / 内容而把页面
 * 打挂的策略类头一律改为 opt-in(显式传值才发)——框架不替应用决定它的安全策略。
 *
 * 默认开(无参 helmet() 即发):
 *   - X-Content-Type-Options: nosniff   : 禁止浏览器对响应做 MIME 嗅探。
 *   - X-Frame-Options: SAMEORIGIN       : 限制被 <iframe> 嵌入,防点击劫持。
 *   - Referrer-Policy: no-referrer        : 不携带 Referer,减少信息泄露。
 *   - Strict-Transport-Security(HSTS)   : 强制后续走 HTTPS(仅在 HTTPS 下对浏览器生效)。
 *
 * 默认关(易误伤,需显式传值才开启):
 *   - Content-Security-Policy(csp)        : 限制资源来源;配错会挡掉外部脚本 / 样式 / 字体 / 图片。
 *   - Cross-Origin-Opener-Policy(coop)     : 隔离跨源窗口;会破坏 OAuth 弹窗等跨窗口通信。
 *   - Cross-Origin-Resource-Policy(corp)   : 取 same-origin 时会挡住别的站点加载你的资源(CDN / 嵌图)。
 *
 * 定制:任意字符串参数传空串、或把布尔设为 false,即表示「不发送该头」。需要更细的策略时,
 * 也可在 helmet 之后再用普通中间件覆盖具体的头。
 */
public func helmet(
    csp!: String = "",
    hsts!: Bool = true,
    frameOptions!: String = "SAMEORIGIN",
    referrerPolicy!: String = "no-referrer",
    noSniff!: Bool = true,
    coop!: String = "",
    corp!: String = ""
): Middleware {
    return {
        _: HttpRequest, res: HttpResponse, next: Next =>
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
            if (!coop.isEmpty()) {
                res.headers["Cross-Origin-Opener-Policy"] = coop
            }
            if (!corp.isEmpty()) {
                res.headers["Cross-Origin-Resource-Policy"] = corp
            }

            next()
    }
}
