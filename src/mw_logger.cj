package wen

import std.time.*

/*
 * 请求日志中间件。
 *
 * 每个请求**完成后**打一行。默认格式为 "METHOD path status durationMs"。
 *
 * 需要别的字段(IP / User-Agent / 请求 ID / 上色 / 只打慢请求……)时,不必为每种可能各塞
 * 一个开关——传入一个 format 函数即可:它拿到 (请求, 响应, 处理耗时毫秒),返回要打印的
 * 整行字符串。req / res 的字段都是 public,想打什么、怎么排版、要不要 ANSI 颜色,全由你决定。
 * 这样核心保持极简,定制能力却是完全开放的。
 */

// 默认日志:每个请求完成后打 "METHOD path status durationMs"。
public func logger(): Middleware {
    return logger({
        req: HttpRequest, res: HttpResponse, ms: Int64 => "${req.method} ${req.path} ${res.statusCode} ${ms}ms"
    })
}

// 自定义日志:format 拿到 (请求, 响应, 处理耗时毫秒),返回要打印的一整行。
public func logger(format: (HttpRequest, HttpResponse, Int64) -> String): Middleware {
    return {
        req: HttpRequest, res: HttpResponse, next: Next =>
            let start = DateTime.now()
            next()
            let elapsedMs = (DateTime.now() - start).toMilliseconds()
            println(format(req, res, elapsedMs))
    }
}
