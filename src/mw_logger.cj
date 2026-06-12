package wen


/*
 * 请求日志插件。
 *
 * 为每个请求打印一对单行轨迹：进入时打一行“-->”，带上请求方法和路径；
 * 处理完成、即将返回时再打一行“<--”，带上最终的响应状态码。
 *
 * 关键点在于状态码是在 `next()` 返回**之后**才读取的——也就是说要等整条
 * 中间件链与处理器都执行完毕，res.statusCode 才会反映出下游最终设置的那个
 * 值，这样日志记录到的状态码才是准确的。
 */

// 构造一个用于打印请求日志的 Middleware。
public func logger(): Middleware {
    return { req: HttpRequest, res: HttpResponse, next: Next =>
        println("--> ${req.method} ${req.path}")
        next()
        // 只在 next() 执行完、整条链跑过之后再读取 statusCode，
        // 以保证此时拿到的是最新、最终的状态码。
        println("<-- ${req.method} ${req.path} ${res.statusCode}")
    }
}
