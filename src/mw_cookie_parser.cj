package wen

/*
 * Cookie 解析中间件。
 *
 * 读取请求中的 `Cookie` 头，按浏览器发送 Cookie 的格式把它拆解成一个个
 * name=value 键值对，存入 `req.cookies`，下游处理器即可通过 `req.cookie(name)`
 * 读取某个具体 Cookie 的值。其行为对标 Express 的 cookie-parser。
 *
 * 解析细节：Cookie 头里各项以分号 ";" 分隔；每一项都会去除首尾空白，跳过
 * 拆分后产生的空项（例如末尾多余的分号）；键和值以第一个 "=" 为界切开
 * （借助 splitOnce，因此值里若再含 "=" 不会被错误截断），键、值两侧的空白
 * 也都会被裁掉。若请求没有 Cookie 头，则什么都不做。
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
