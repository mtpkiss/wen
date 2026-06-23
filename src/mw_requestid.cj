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

// 构造请求 ID 中间件。headerName 为读取/写回所用的头名(默认 X-Request-Id);generator 决定
// 新 ID 的生成方式(默认 64 位随机十六进制),可换成 UUID 等自定义格式——上游已注入该头时
// 沿用上游值,仅在需要新建时调用 generator。
//
// 安全:上游传入的 X-Request-Id 不被无条件信任 —— 须满足 isValidRequestId 字符白名单
// (长度 ≤ 128;字符限于 [A-Za-z0-9_-])。不合规的值被丢弃、按新请求重新生成。这能挡掉
// 日志注入(攻击者塞 CR/LF 污染日志行)、控制字符欺骗等。其它字符集需求请自行包装 generator。
public func requestId(headerName!: String = "X-Request-Id",
    generator!: () -> String = defaultRequestIdGen()): Middleware {
    return {
        req: HttpRequest, res: HttpResponse, next: Next =>
            let id = match (req.header(headerName)) {
                case Some(v) =>
                    let trimmed = v.trimAscii()
                    if (isValidRequestId(trimmed)) {
                        trimmed
                    } else {
                        generator()
                    }
                case None => generator()
            }
            req.attributes["requestId"] = id
            res.set(headerName, id)
            next()
    }
}

// 请求 ID 白名单:非空、长度 ≤ 128、仅 [A-Za-z0-9_-]。常见格式(64 位 hex、UUID、
// nanoid 等)都满足该约束。
func isValidRequestId(s: String): Bool {
    if (s.isEmpty() || s.size > 128) {
        return false
    }
    for (b in s.toArray()) {
        let alnum = (b >= UInt8(48) && b <= UInt8(57))    // 0-9
            || (b >= UInt8(65) && b <= UInt8(90))         // A-Z
            || (b >= UInt8(97) && b <= UInt8(122))        // a-z
        if (!alnum && b != UInt8(45) && b != UInt8(95)) { // - _
            return false
        }
    }
    return true
}

// 默认的请求 ID 生成器:每次构造中间件时返回一个捕获了独立 RequestIdGen 的闭包,因此同一个
// requestId() 中间件实例内共享一个线程安全的生成器(RequestIdGen 内部用 Mutex 保护 Random)。
func defaultRequestIdGen(): () -> String {
    let gen = RequestIdGen()
    return { => gen.next() }
}
