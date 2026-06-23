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
// HSTS 三档可调:
//   hstsMaxAge            : 秒数(默认 180 天 = 15552000)。生产 + preload 申请前应改为 31536000(1 年)。
//   hstsIncludeSubDomains : 是否带 includeSubDomains(默认 true,与之前行为一致)。
//   hstsPreload           : 是否带 preload 指令(默认 false)。preload 申请被浏览器接受后**不可撤销**
//                           (撤销可能需要 1 年以上),且要求 max-age ≥ 31536000 且 includeSubDomains
//                           为真——框架不替你强制校验,但默认关闭以免误开。
public func helmet(
    csp!: String = "",
    hsts!: Bool = true,
    hstsMaxAge!: Int64 = 15552000,
    hstsIncludeSubDomains!: Bool = true,
    hstsPreload!: Bool = false,
    frameOptions!: String = "SAMEORIGIN",
    referrerPolicy!: String = "no-referrer",
    noSniff!: Bool = true,
    coop!: String = "",
    corp!: String = ""
): Middleware {
    return {
        _: HttpRequest, res: HttpResponse, next: Next =>
            if (!csp.isEmpty()) {
                res.set("Content-Security-Policy", csp)
            }
            if (noSniff) {
                res.set("X-Content-Type-Options", "nosniff")
            }
            if (!frameOptions.isEmpty()) {
                res.set("X-Frame-Options", frameOptions)
            }
            if (!referrerPolicy.isEmpty()) {
                res.set("Referrer-Policy", referrerPolicy)
            }
            if (hsts) {
                var hdr = "max-age=${hstsMaxAge}"
                if (hstsIncludeSubDomains) {
                    hdr += "; includeSubDomains"
                }
                if (hstsPreload) {
                    hdr += "; preload"
                }
                res.set("Strict-Transport-Security", hdr)
            }
            if (!coop.isEmpty()) {
                res.set("Cross-Origin-Opener-Policy", coop)
            }
            if (!corp.isEmpty()) {
                res.set("Cross-Origin-Resource-Policy", corp)
            }

            next()
    }
}
