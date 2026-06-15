package wen

import std.time.*

/*
 * 请求日志中间件。
 *
 * 入站打一行 `--> METHOD path …`,出站再打一行 `<-- METHOD path status …ms`。
 * 出站行的状态码与耗时都在 `next()` 返回之后读取,保证拿到的是整条链跑完后
 * 下游最终设置的值。所有附加字段都是可选的,默认仅打开 `duration`。
 */
public func logger(
    duration!: Bool = true,
    ip!: Bool = false,
    userAgent!: Bool = false,
    referer!: Bool = false,
    requestId!: Bool = false,
    slow!: Int64 = -1,
    colorize!: Bool = false
): Middleware {
    return { req: HttpRequest, res: HttpResponse, next: Next =>
        var inLine = "--> ${req.method} ${req.path}"
        if (ip) {
            inLine += "  ip=${req.clientIp()}"
        }
        if (requestId) {
            match (req.requestId()) {
                case Some(rid) => inLine += "  rid=${rid}"
                case None => ()
            }
        }
        if (userAgent) {
            match (req.header("user-agent")) {
                case Some(v) => inLine += "  ua=\"${v}\""
                case None => ()
            }
        }
        if (referer) {
            match (req.header("referer")) {
                case Some(v) => inLine += "  referer=\"${v}\""
                case None => ()
            }
        }
        println(inLine)

        let start = DateTime.now()
        next()
        let elapsedMs = (DateTime.now() - start).toMilliseconds()

        let statusStr = if (colorize) {
            colorStatus(res.statusCode)
        } else {
            res.statusCode.toString()
        }
        var outLine = "<-- ${req.method} ${req.path} ${statusStr}"
        if (duration) {
            outLine += "  ${elapsedMs}ms"
        }
        if (slow >= 0 && elapsedMs > slow) {
            outLine += "  [SLOW]"
        }
        println(outLine)
    }
}

// 给 HTTP 状态码套上 ANSI 颜色:2xx 绿 / 3xx 青 / 4xx 黄 / 5xx 红。
func colorStatus(code: Int64): String {
    let color = if (code >= 500) {
        "31"
    } else if (code >= 400) {
        "33"
    } else if (code >= 300) {
        "36"
    } else if (code >= 200) {
        "32"
    } else {
        "0"
    }
    return "\u{001b}[${color}m${code}\u{001b}[0m"
}
