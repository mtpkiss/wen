package wen

import std.collection.*

/*
 * 流式响应（Server-Sent Events 背后的底层原语）。
 *
 * 默认的响应模型是“缓冲整个响应体、最后一次性写出”。而流式响应则会
 * “劫持（hijack）”这条连接：处理器先把状态行和响应头刷出去，然后在保持
 * socket 打开的情况下，随着时间不断推送一块块数据。服务端会识别出某个响应
 * 已被劫持，从而跳过它默认的序列化步骤（不再去拼装、整体写出响应体）。
 *
 * 当没有真实连接时（例如单元测试里直接调用 app.handle 来驱动），写入会退化
 * 成把数据追加到 res.body 上，这样测试就能对写出的内容做断言。
 */

/**
 * 服务端交给流式处理器使用的一条真实(活动)连接的抽象接口。
 *
 * 由 [[StreamWriter]] / [[SseWriter]] 使用;wen 内置的实现把它适配到底层
 * `TcpSocket`。测试场景下可注入自定义实现以捕获写出的字节。
 */
public interface ResponseConnection {
    func write(data: Array<UInt8>): Unit
    func close(): Unit
}

/**
 * 流式响应的增量写入器。
 *
 * 第一次写入时会先把状态行和响应头刷出去(仅一次),之后每次写入都直接把原始数据块
 * 转发到连接上。由 `res.stream` 取得;当没有真实连接时(单元测试场景),写入退化成
 * 追加到 `res.body`,便于断言。
 */
public class StreamWriter {
    let res: HttpResponse
    var started: Bool = false

    init(res: HttpResponse) {
        this.res = res
    }

    // 把状态行和响应头恰好刷出一次（仅在存在真实连接时才发送）。
    // 借助 started 标志保证幂等：重复调用 begin() 不会重复发送响应头。
    // 这里手工拼装 "HTTP/1.1 状态码 状态消息" 起始行、逐条写出普通响应头，
    // 再逐条写出 Set-Cookie 头，最后用一个空行（\r\n）结束头部。
    func begin(): Unit {
        if (started) {
            return
        }
        started = true
        res.headersSent = true
        ensureDateHeader(res)
        applyCharsetIfSet(res)
        match (res.conn) {
            case Some(c) => c.write(buildHeadBlock(res))
            case None => ()
        }
    }

    // 写入一块文本数据（按 UTF-8 编码成字节后写出）。
    public func write(text: String): Unit {
        writeRaw(text.toArray())
    }

    // 写入一块原始二进制数据。
    public func writeBytes(data: Array<UInt8>): Unit {
        writeRaw(data)
    }

    func writeRaw(data: Array<UInt8>): Unit {
        match (res.conn) {
            case Some(c) => c.write(data)
            case None => res.body += String.fromUtf8(data)
        }
    }
}

/**
 * Server-Sent Events(SSE)写入器。
 *
 * 在 [[StreamWriter]] 之上负责把数据格式化成符合 SSE 规范的帧
 * (`event` / `data` / `id` / `retry` / 注释等行),再交由底层写出。由 `res.sse` 取
 * 得。
 */
public class SseWriter {
    let w: StreamWriter

    init(w: StreamWriter) {
        this.w = w
    }

    // 发送一个带名字的事件：先写出 "event: 名称" 行，再写出数据。
    // 客户端可用 addEventListener(name, ...) 监听这个具名事件。
    // 事件名一旦含 CR/LF/NUL 即可注入新的 SSE 帧(向同会话客户端推送伪造事件,
    // 如把 name 设成 "logout" 让 UI 退出),入口必须拒。
    public func event(name: String, data: String): Unit {
        checkSseFieldSafe(name)
        w.write("event: ${name}\n")
        emitData(data)
    }

    // 发送一个默认（不具名）事件，只携带数据。
    // 客户端通过默认的 onmessage 回调即可收到。
    public func send(data: String): Unit {
        emitData(data)
    }

    // 为接下来的事件设置 id。客户端会记住它，并在断线重连时通过
    // Last-Event-ID 请求头回传，从而支持断点续传式的事件恢复。
    // 同 event,id 值含 CR/LF/NUL 即可注入新帧 — 业务把外部用户名直接喂进来
    // (`sse.id(req.attribute("userId"))`)是常见写法,入口必须拒。
    public func id(value: String): Unit {
        checkSseFieldSafe(value)
        w.write("id: ${value}\n")
    }

    // 建议客户端在断线后等待多少毫秒再重连（写出 "retry: 毫秒数" 帧）。
    public func retry(ms: Int64): Unit {
        w.write("retry: ${ms}\n\n")
    }

    // 写出一行 SSE 注释（以 ":" 开头的行，客户端会忽略其内容）。
    // 它常被用作保活心跳（keep-alive ping），用来防止中间代理或连接因长时间
    // 无数据而超时断开。注释内容含 CR/LF/NUL 同样能注入下一帧,入口拒。
    public func comment(text: String): Unit {
        checkSseFieldSafe(text)
        w.write(": ${text}\n\n")
    }

    // 按 SSE 规范输出数据：把 data 按换行拆成多行，每一行都加上 "data: " 前缀
    // 单独写出（这样多行文本能被正确表达），最后再写一个空行来标记本次事件结束。
    // 行尾按 SSE 规范同时识别 \r\n、\n、\r 三种 — 只按 \n 切的话,含 \r 的 data
    // 在浏览器端会被当作"新行"再次拆分,等同于注入新字段名。
    func emitData(data: String): Unit {
        for (line in splitSseLines(data)) {
            w.write("data: ${line}\n")
        }
        w.write("\n")
    }
}

// 拒 SSE 字段值含 CR/LF/NUL — 任一字符落进 event/id/comment 都能让攻击者凭空向
// 同会话客户端推送伪造事件。同 checkHeaderSafe 风格,违反就抛。
func checkSseFieldSafe(s: String): Unit {
    for (b in s.toArray()) {
        if (b == UInt8(0) || b == UInt8(10) || b == UInt8(13)) {
            throw Exception("SSE 字段含 CR/LF/NUL,拒绝写入以防事件帧注入")
        }
    }
}

// 按 SSE 行尾(CR / LF / CRLF 任一)切。emitData 用之确保浏览器侧的行划分与
// wen 输出一致。
func splitSseLines(s: String): Array<String> {
    let out = ArrayList<String>()
    let bytes = s.toArray()
    var start = 0
    var i = 0
    while (i < bytes.size) {
        let b = bytes[i]
        if (b == UInt8(13)) {
            out.add(String.fromUtf8(bytes[start..i]))
            if (i + 1 < bytes.size && bytes[i + 1] == UInt8(10)) {
                i += 2
            } else {
                i += 1
            }
            start = i
        } else if (b == UInt8(10)) {
            out.add(String.fromUtf8(bytes[start..i]))
            i += 1
            start = i
        } else {
            i += 1
        }
    }
    out.add(String.fromUtf8(bytes[start..bytes.size]))
    return out.toArray()
}
