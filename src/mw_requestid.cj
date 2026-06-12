package wen

import std.sync.*
import std.random.*

/*
 * 请求 ID(关联 ID)中间件。
 *
 * 为每个请求关联一个唯一 ID,贯穿日志/链路:若请求已带该头(常见于上游网关注入),
 * 则沿用它;否则生成一个新的随机 ID。ID 既存到 req(经 req.requestId() 读取),也写回
 * 同名响应头,方便客户端与日志关联。
 *
 * ID 生成用 std.random,并用 Mutex 保护(服务器多线程处理连接,Random 实例非线程安全)。
 */

// 线程安全的随机 ID 生成器(可变状态封进类,便于被中间件闭包以 let 捕获)。
class RequestIdGen {
    let lock = Mutex()
    let rng = Random()

    func next(): String {
        lock.lock()
        try {
            return toHex64(rng.nextUInt64())
        } finally {
            lock.unlock()
        }
    }
}

// 构造请求 ID 中间件。headerName 为读取/写回所用的头名(默认 X-Request-Id)。
public func requestId(headerName!: String = "X-Request-Id"): Middleware {
    let gen = RequestIdGen()
    return { req: HttpRequest, res: HttpResponse, next: Next =>
        let id = match (req.header(headerName)) {
            case Some(v) => if (v.trimAscii().isEmpty()) { gen.next() } else { v.trimAscii() }
            case None => gen.next()
        }
        req.attributes["requestId"] = id
        res.headers[headerName] = id
        next()
    }
}
