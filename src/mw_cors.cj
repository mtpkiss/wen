package wen


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

// 只允许某一个明确指定的来源。传入的 origin 会被原样写进
// Access-Control-Allow-Origin 头（不做校验或多来源匹配）。
public func cors(origin: String): Middleware {
    return { req: HttpRequest, res: HttpResponse, next: Next =>
        res.set("Access-Control-Allow-Origin", origin)
        res.set("Access-Control-Allow-Methods", "GET, POST, PUT, DELETE, PATCH, OPTIONS")
        res.set("Access-Control-Allow-Headers", "Content-Type, Authorization")

        // 预检请求在这里已被完整应答（204 + 上面设置好的 CORS 头），
        // 因此直接 return，不再调用 next() 把它传给下游。
        if (req.method == HttpMethod.OPTIONS) {
            res.status(204).end()
            return
        }

        next()
    }
}
