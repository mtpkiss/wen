package wen_contrib


import wen.*
/*
 * CORS（跨域资源共享）插件。
 *
 * 给响应加上 Access-Control-Allow-* 系列响应头，让浏览器放行跨域请求。
 * 设置的头包括：允许的来源（Origin）、允许的请求方法（GET/POST/PUT/DELETE/
 * PATCH/OPTIONS）、以及允许的请求头（Content-Type、Authorization）。
 *
 * 对预检请求（preflight，即方法为 OPTIONS 的请求）会就地直接回应
 * `204 No Content` 并结束，**不**再调用 next()，因此预检请求永远不会落到
 * 下游的业务处理器上——这正是 CORS 协议期望的行为。
 */

// 允许任意来源（"*"）。这是最宽松的配置，等价于调用 cors("*")。
public func cors(): Middleware {
    return cors("*")
}

// 只允许某一个明确指定的来源,并可细化 CORS 策略。origin 原样写进 Access-Control-Allow-Origin
// (不做校验或多来源匹配)。可选具名参数:
//   methods       允许的方法(默认 "GET, POST, PUT, DELETE, PATCH, OPTIONS")
//   headers       允许的请求头(默认 "Content-Type, Authorization")
//   credentials   是否允许带凭据(Cookie / Authorization);为 true 时发 Access-Control-Allow-Credentials。
//                 注意:浏览器规范禁止 credentials 与 origin="*" 并用,此时应指定具体 origin(框架不强制校验)。
//   maxAge        预检结果缓存秒数;>=0 时发 Access-Control-Max-Age。
//   exposeHeaders 允许 JS 读取的响应头(默认空,不发 Access-Control-Expose-Headers)。
public func cors(origin: String, methods!: String = "GET, POST, PUT, DELETE, PATCH, OPTIONS",
    headers!: String = "Content-Type, Authorization", credentials!: Bool = false, maxAge!: Int64 = -1,
    exposeHeaders!: String = ""): Middleware {
    // 在中间件构造期主动拒绝危险配置:CORS 规范禁止 credentials=true 与 origin="*" 同用
    // (浏览器会拒,但服务端仍会处理请求,可能造成意料外的状态改变)。这里宁可让应用启动
    // 时立刻报错,也好过把误配带到生产再被攻击者利用。
    if (credentials && origin.trimAscii() == "*") {
        throw Exception("CORS 配置错误:credentials=true 时 origin 不能为 \"*\",请指定具体的 origin")
    }
    return {
        req: HttpRequest, res: HttpResponse, next: Next =>
            res.set("Access-Control-Allow-Origin", origin)
            res.set("Access-Control-Allow-Methods", methods)
            res.set("Access-Control-Allow-Headers", headers)
            if (credentials) {
                res.set("Access-Control-Allow-Credentials", "true")
            }
            if (!exposeHeaders.isEmpty()) {
                res.set("Access-Control-Expose-Headers", exposeHeaders)
            }
            if (maxAge >= 0) {
                res.set("Access-Control-Max-Age", maxAge.toString())
            }

            // 预检请求在这里已被完整应答(204 + 上面设置好的 CORS 头),
            // 因此直接 return,不再调用 next() 把它传给下游。
            if (req.method == HttpMethod.OPTIONS) {
                res.status(204).end()
                return
            }

            next()
    }
}
