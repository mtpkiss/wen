package wen_contrib

import wen.*
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

// 默认日志:每个请求完成后打 "METHOD path status durationMs"。可选 sink 改变输出去向
// (默认 println 到 stdout),例如写入文件 / stderr / 结构化日志系统。
public func logger(sink!: (String) -> Unit = {line: String => println(line)}): Middleware {
    return logger({
        req: HttpRequest, res: HttpResponse, ms: Int64 => "${req.method} ${req.path} ${res.statusCode} ${ms}ms"
    }, sink: sink)
}

// 自定义日志:format 拿到 (请求, 响应, 处理耗时毫秒),返回要打印的一整行;sink 决定这一行
// 输出到哪里(默认 println 到 stdout)。format 管「打什么」、sink 管「打到哪」,两者都开放。
public func logger(format: (HttpRequest, HttpResponse, Int64) -> String,
    sink!: (String) -> Unit = {line: String => println(line)}): Middleware {
    return {
        req: HttpRequest, res: HttpResponse, next: Next =>
            let start = DateTime.now()
            // try/finally 包 next。否则 next 抛(下游 handler 抛、上游错误流水线
            // 接管)的请求不会留下任何日志记录 — 运维盲区。finally 里只读 res 的当前
            // 状态(errorHandler 已写入了 statusCode/headers)和 elapsed,纯只读不影响
            // 错误传播。format/sink 若再抛会盖住原异常,因此 sink 错误本身静默掉。
            try {
                next()
            } finally {
                let elapsedMs = (DateTime.now() - start).toMilliseconds()
                try {
                    sink(format(req, res, elapsedMs))
                } catch (_: Exception) {
                    ()
                }
            }
    }
}
