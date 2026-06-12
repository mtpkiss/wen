package wen

import std.collection.*
import std.sync.*

/*
 * 限流中间件(固定时间窗口,按客户端 IP 计数)。
 *
 * 在 windowSeconds 长度的时间窗口内,同一客户端最多允许 max 次请求;超出则直接回
 * 429 Too Many Requests,并带上 Retry-After(距窗口重置的秒数)。每个响应都会带上
 * X-RateLimit-Limit / X-RateLimit-Remaining 两个头,方便客户端自我节流。
 *
 * 计数存于进程内存(用 Mutex 保护,因服务器多线程处理连接),并在跨入新窗口时顺手
 * 清理过期条目以免无限增长。客户端 IP 取自 req.clientIp()(开启 trustProxy 时会采信
 * 代理头)。仅适合单实例;多实例需共享存储(如 Redis),可仿此实现一个新中间件。
 *
 * 注意:基于「当前时间」的固定窗口存在边界突发(窗口交界处可能短时放行至多 2*max),
 * 这是固定窗口算法的固有特性;需要更平滑可改用滑动窗口/令牌桶。
 */

// 限流计数存储:键 -> (窗口序号, 该窗口内已计数)。把可变状态封装进类,以便被中间件
// 闭包以 let 形式捕获(闭包不能直接捕获可变局部变量)。
class RateLimitStore {
    let lock = Mutex()
    let hits = HashMap<String, (Int64, Int64)>()
    var lastSweep: Int64 = -1

    // 记一次命中,返回 (是否放行, 本窗口剩余配额, 距窗口重置秒数)。
    func hit(key: String, nowSec: Int64, max: Int64, windowSec: Int64): (Bool, Int64, Int64) {
        lock.lock()
        try {
            let curWindow = nowSec / windowSec
            // 跨入新窗口时,清掉所有仍停留在更早窗口的条目。
            if (curWindow != lastSweep) {
                lastSweep = curWindow
                let stale = ArrayList<String>()
                for ((k, wv) in hits) {
                    let (w, _) = wv
                    if (w < curWindow) {
                        stale.add(k)
                    }
                }
                for (k in stale) {
                    hits.remove(k)
                }
            }

            var count = 1
            match (hits.get(key)) {
                case Some(entry) =>
                    let (w, c) = entry
                    if (w == curWindow) {
                        count = c + 1
                    }
                case None => ()
            }
            hits[key] = (curWindow, count)

            let allowed = count <= max
            let remaining = if (max - count > 0) {
                max - count
            } else {
                0
            }
            let resetIn = windowSec - (nowSec % windowSec)
            return (allowed, remaining, resetIn)
        } finally {
            lock.unlock()
        }
    }
}

// 构造限流中间件:每个客户端在 windowSeconds 秒内最多 max 次请求。
public func rateLimit(max!: Int64 = 60, windowSeconds!: Int64 = 60): Middleware {
    let store = RateLimitStore()
    return { req: HttpRequest, res: HttpResponse, next: Next =>
        let key = req.clientIp()
        let (allowed, remaining, resetIn) = store.hit(key, nowUnixSeconds(), max, windowSeconds)
        res.headers["X-RateLimit-Limit"] = "${max}"
        res.headers["X-RateLimit-Remaining"] = "${remaining}"
        if (!allowed) {
            res.headers["Retry-After"] = "${resetIn}"
            res.status(429).send("Too Many Requests")
            return
        }
        next()
    }
}
