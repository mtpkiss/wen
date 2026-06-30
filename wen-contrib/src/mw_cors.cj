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
//   reflectRequestHeaders 为 true 时,把预检请求里的 Access-Control-Request-Headers 原样反射到
//                 Access-Control-Allow-Headers(而非用上面的 headers 默认值)。**部署须知 / 信任边界**:
//                 这等于把「允许哪些请求头」的控制权完全交给调用方 —— 任何能通过预检的来源都能让
//                 服务器声明接受其自定义头。**仅在你确知所有跨域调用方都可信(如自家前端)时开启**;
//                 面向公开 / 不可信来源时应保持 false,并用 headers 显式列举白名单。默认 false。
public func cors(origin: String, methods!: String = "GET, POST, PUT, DELETE, PATCH, OPTIONS",
    headers!: String = "Content-Type, Authorization", credentials!: Bool = false, maxAge!: Int64 = -1,
    exposeHeaders!: String = "", reflectRequestHeaders!: Bool = false): Middleware {
    // 在中间件构造期主动拒绝危险配置:CORS 规范禁止 credentials=true 与 origin="*" 同用
    // (浏览器会拒,但服务端仍会处理请求,可能造成意料外的状态改变)。这里宁可让应用启动
    // 时立刻报错,也好过把误配带到生产再被攻击者利用。
    if (credentials && origin.trimAscii() == "*") {
        throw Exception("CORS 配置错误:credentials=true 时 origin 不能为 \"*\",请指定具体的 origin")
    }
    return {
        req: HttpRequest, res: HttpResponse, next: Next =>
            // Vary: Origin 总是发,无论 origin 是 "*" 还是具体值。原因:CDN /
            // 反代缓存层会按响应内容缓存,如果不告知"这个响应随 Origin 头不同而不同",
            // 同一 URL 在 A 站点的 CORS 响应可能被发给 B 站点,跨域策略形同虚设。
            // 即使 origin="*" 也建议发,以便后续切换到精确 origin 时缓存能自动 invalidate。
            res.vary("Origin")
            res.set("Access-Control-Allow-Origin", origin)
            res.set("Access-Control-Allow-Methods", methods)
            // reflectRequestHeaders=true 时,把预检的
            // Access-Control-Request-Headers 原样反射到 Allow-Headers,避免默认值
            // ("Content-Type, Authorization") 漏掉客户端实际需要的自定义头(浏览器
            // 拒绝实际请求 → "已配 CORS"假象)。注意:开启反射等于把客户端控制权交给
            // Allow-Headers,**仅在你确知所有调用方是可信前端时使用**。
            if (reflectRequestHeaders) {
                let acrh = match (req.header("access-control-request-headers")) {
                    case Some(v) => v.trimAscii()
                    case None => ""
                }
                if (acrh.isEmpty()) {
                    res.set("Access-Control-Allow-Headers", headers)
                } else {
                    res.set("Access-Control-Allow-Headers", acrh)
                    res.vary("Access-Control-Request-Headers")
                }
            } else {
                res.set("Access-Control-Allow-Headers", headers)
            }
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
