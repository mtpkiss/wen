package wen

import std.net.*
import std.collection.*
import std.sync.*

// 当请求体的字节数超过服务器配置的上限（maxBodySize）时抛出此异常。
// 服务器在 handleConnection 的 catch 中捕获它，并向客户端返回 413
// Payload Too Large 响应。把"体积超限"建模成专门的异常，是为了和
// 普通的解析错误（400）、未知错误（500）区分开，从而映射到正确的状态码。
public class PayloadTooLargeException <: Exception {
    public init() {
        super("Payload Too Large")
    }
}

// 当请求的消息分帧（framing）非法时抛出此异常，最典型的情形是同一请求里
// 同时出现 Content-Length 和 Transfer-Encoding 两个互相冲突的报文头——这种
// 二义性正是 HTTP 请求走私（request smuggling）攻击的经典手法：前后端代理
// 对"以哪个头为准"理解不一致，攻击者就能把一个请求伪装成两个。服务器一律
// 拒绝这类请求，捕获该异常后返回 400 Bad Request。
public class BadRequestException <: Exception {
    public init() {
        super("Bad Request")
    }
}

/*
 * 一个直接构建在 TCP 套接字之上的极简 HTTP/1.1 服务器。它的工作流程是：
 * 从套接字读取原始请求字节并解析出 HttpRequest，再配一个空白的
 * HttpResponse，把这对 (HttpRequest, HttpResponse) 交给应用的中间件链
 * 处理，最后把处理完成的响应序列化成字节写回套接字。
 *
 * 每条连接都通过 `spawn` 在各自独立的轻量线程上处理，互不阻塞。
 */
// SocketConnection 把底层的 TcpSocket 适配成 ResponseConnection 接口。
// 这样流式处理器（streaming handler）可以脱离常规的"先攒响应再一次性序列化"
// 流程，直接往这条活动连接上写字节（例如分块推送、Server-Sent Events），
// 而无需感知底层套接字的具体类型。
class SocketConnection <: ResponseConnection {
    let sock: TcpSocket

    init(sock: TcpSocket) {
        this.sock = sock
    }

    public func write(data: Array<UInt8>): Unit {
        sock.write(data)
    }

    public func close(): Unit {
        sock.close()
    }
}

public class HttpServer {
    let app: Application

    // 允许接收的请求体最大字节数（默认 1 MiB = 1048576 字节）。超过此值会抛出
    // PayloadTooLargeException，从而拒绝过大的请求体，防止单个请求耗尽内存。
    public var maxBodySize: Int64 = 1048576
    // 单次套接字读操作的超时时间（毫秒）。它用于防御慢速/空闲的对端：如果一个
    // 客户端建立连接后迟迟不发数据（典型的 Slowloris 慢速攻击），读操作会在
    // 超时后失败，连接随即被放弃，避免线程被长期占住。
    public var readTimeoutMs: Int64 = 15000
    // 同时并发处理的连接数上限（默认 1024）。它通过信号量限制在途连接的数量，
    // 从而间接限制了 spawn 出来的线程数：当连接洪水（大量并发连接）涌入时，
    // 多出来的连接会在 accept 之前被挡住，不会无限制地创建线程而把资源耗尽。
    public var maxConnections: Int64 = 1024

    public init(app: Application) {
        this.app = app
    }

    public func listen(port: Int64): Unit {
        let server = TcpServerSocket(bindAt: UInt16(port))
        server.bind()
        // 用信号量给并发量设上限：accept 循环每次循环前先 acquire 一个槽位，
        // 当 maxConnections 个连接都在处理中（槽位耗尽）时，acquire 会阻塞，
        // 整个 accept 循环随之暂停——此时尚未被 accept 的连接会暂存在操作系统的
        // listen backlog 队列里等待。每个处理线程结束时在 finally 里 release
        // 归还槽位，循环便恢复继续 accept。这样无论涌入多少连接，同时存活的
        // 处理线程数都不会超过 maxConnections，杜绝了线程被无限 spawn 的风险。
        let slots = Semaphore(maxConnections)
        while (true) {
            slots.acquire()
            let client = server.accept()
            spawn {
                try {
                    handleConnection(client)
                } finally {
                    slots.release()
                }
            }
        }
    }

    func handleConnection(client: TcpSocket): Unit {
        client.readTimeout = Duration.millisecond * readTimeoutMs
        let reader = ConnReader(client, maxBodySize)
        try {
            while (true) {
                // readMessage 返回 None 表示对端正常关闭了连接（读到流末尾）
                // 或读操作超时——这两种都属于"没有更多请求了"的正常收尾，而非
                // 错误。因此直接 break 退出循环、安静地结束这条连接的服务，
                // 不向客户端写任何错误响应。
                let raw = match (reader.readMessage()) {
                    case Some(m) => m
                    case None => break
                }
                let req = parseRequest(raw)
                req.ip = remoteIp(client)
                let res = HttpResponse()
                res.conn = Some(SocketConnection(client))
                app.handle(req, res)
                if (!res.finished) {
                    res.status(404).send("Not Found")
                }
                // res.hijacked 为真，说明某个流式处理器已经"劫持"了连接，
                // 绕过常规序列化流程直接往套接字写了数据。这类流（如长连接推送）
                // 是以"连接关闭"作为数据结束标志的（connection-delimited），
                // 无法再在同一连接上复用，所以处理完后直接 break 关闭连接。
                if (res.hijacked) {
                    break
                }
                let keepAlive = shouldKeepAlive(req)
                res.headers["Connection"] = if (keepAlive) {
                    "keep-alive"
                } else {
                    "close"
                }
                client.write(serializeResponse(res))
                if (!keepAlive) {
                    break
                }
            }
        } catch (_: PayloadTooLargeException) {
            writeError(client, 413, "Payload Too Large")
        } catch (_: BadRequestException) {
            writeError(client, 400, "Bad Request")
        } catch (_: Exception) {
            writeError(client, 500, "Internal Server Error")
        } finally {
            client.close()
        }
    }

    // 判断本次请求处理完后是否应保持连接（keep-alive）以复用同一条 TCP 连接
    // 服务后续请求。规则遵循 HTTP 协议约定：HTTP/1.1 默认保持长连接，HTTP/1.0
    // 默认处理完即关闭；而请求里显式的 Connection 报文头优先级最高，可覆盖默认
    // 行为——含 "close" 则关闭，含 "keep-alive" 则保持。
    func shouldKeepAlive(req: HttpRequest): Bool {
        match (req.header("connection")) {
            case Some(v) =>
                let lv = v.toAsciiLower()
                if (lv.contains("close")) {
                    return false
                }
                if (lv.contains("keep-alive")) {
                    return true
                }
            case None => ()
        }
        return req.httpVersion.trimAscii().contains("1.1")
    }

    func writeError(client: TcpSocket, code: Int64, message: String): Unit {
        try {
            let res = HttpResponse()
            res.status(code).send(message)
            client.write(serializeResponse(res))
        } catch (_: Exception) {
            ()
        }
    }

    // 取得对端（客户端）的 IP 地址，不含端口号；若无法获取则返回空串 ""。
    // 地址字符串通常形如 "host:port"，这里把端口部分剥掉只留主机部分。
    // 对于带方括号的 IPv6 字面量 "[::1]:p"，返回方括号内的 "::1"——因为 IPv6
    // 地址本身含有冒号，必须靠方括号来区分地址与端口，不能简单按冒号切分。
    // 任何异常（例如连接已断、地址不可用）都被吞掉并返回空串，保证不影响主流程。
    func remoteIp(client: TcpSocket): String {
        try {
            let s = client.remoteAddress.toString()
            if (s.startsWith("[")) {
                match (s.indexOf("]")) {
                    case Some(i) => return s[1..i]
                    case None => return s
                }
            }
            let (host, _) = splitOnce(s, ":")
            return host
        } catch (_: Exception) {
            return ""
        }
    }

    func parseRequest(raw: Array<UInt8>): HttpRequest {
        // 以 "\r\n\r\n"（连续两个 CRLF，即头部与正文之间的空行）为界，
        // 把整段原始字节切成"头部字节"与"正文字节"两部分。这是 HTTP 报文
        // 头与体的标准分隔符；找不到分隔符时按"全是头部、无正文"处理。
        let sep = indexOfHeaderEndArr(raw)
        let headerEnd = match (sep) {
            case Some(p) => p
            case None => raw.size
        }
        let bodyStart = match (sep) {
            case Some(p) => p + 4
            case None => raw.size
        }
        let headerPart = String.fromUtf8(subArray(raw, 0, headerEnd))
        let bodyBytes = subArray(raw, bodyStart, raw.size)

        let lines = headerPart.split("\r\n")
        let requestLine = lines[0]

        let (method, afterMethod) = splitOnce(requestLine, " ")
        let (target, version) = splitOnce(afterMethod, " ")

        let req = HttpRequest(method, target)
        req.httpVersion = version

        let (path, queryString) = splitOnce(target, "?")
        req.path = path
        parseQuery(queryString, req.query)

        var i = 1
        while (i < lines.size) {
            let line = lines[i]
            if (!line.isEmpty()) {
                let (key, value) = splitOnce(line, ":")
                req.headers[key.toAsciiLower().trimAscii()] = value.trimAscii()
            }
            i += 1
        }

        req.bodyBytes = bodyBytes
        req.body = String.fromUtf8(bodyBytes)
        return req
    }

    // headerSeparatorIndex 的 Array 版本：在原始字节数组里扫描头/体分隔符
    // "\r\n\r\n"（字节 13,10,13,10），返回其起始下标；找不到则返回 None。
    // 之所以单独有个数组版本，是因为这里处理的是已经读全的 Array<UInt8>，
    // 而 ConnReader 里那个同名逻辑作用在边读边攒的 ArrayList<UInt8> 上。
    func indexOfHeaderEndArr(buf: Array<UInt8>): ?Int64 {
        var i = 0
        while (i + 3 < buf.size) {
            if (buf[i] == UInt8(13) && buf[i + 1] == UInt8(10) &&
                buf[i + 2] == UInt8(13) && buf[i + 3] == UInt8(10)) {
                return Some(i)
            }
            i += 1
        }
        return None
    }

    // 把 src 的 [start, end) 半开区间复制到一个全新的 Array<UInt8> 并返回。
    // 返回的是独立副本而非视图，因此后续修改原数组不会影响它。当 end <= start
    // 时返回空数组（视为空区间）。
    func subArray(src: Array<UInt8>, start: Int64, end: Int64): Array<UInt8> {
        if (end <= start) {
            return Array<UInt8>()
        }
        let out = Array<UInt8>(end - start, repeat: 0)
        var i = start
        while (i < end) {
            out[i - start] = src[i]
            i += 1
        }
        return out
    }

    func serializeResponse(res: HttpResponse): Array<UInt8> {
        // 按 RFC 7230 规定，204 No Content 与 304 Not Modified 这两类响应
        // 既不携带响应体，也不能带 Content-Length 头。因此下面对这两个状态码
        // 特殊处理：清空响应体并移除已设置的 Content-Length。
        let bodyless = res.statusCode == 204 || res.statusCode == 304
        // res.suppressBody 为真对应 HEAD 请求的响应：HEAD 要求返回与同样的 GET
        // 完全一致的头部（包括那个表示 GET 正文长度的 Content-Length），但绝不
        // 发送正文。所以这里保留已设好的 Content-Length，只把正文置空。其余普通
        // 情况则根据实际正文内容计算并写入 Content-Length。
        let bodyBytes = if (res.suppressBody) {
            Array<UInt8>()
        } else if (bodyless) {
            res.headers.remove("Content-Length")
            Array<UInt8>()
        } else {
            let real = match (res.bodyBytes) {
                case Some(raw) => raw
                case None => res.body.toArray()
            }
            res.headers["Content-Length"] = real.size.toString()
            real
        }

        var head = "HTTP/1.1 ${res.statusCode} ${res.statusMessage}\r\n"
        for ((k, v) in res.headers) {
            head += "${k}: ${v}\r\n"
        }
        // 每个待发送的 cookie 都单独占一行 Set-Cookie 头。HTTP 不允许把多个
        // cookie 合并到一个 Set-Cookie 头里，故逐个输出独立的报文头行。
        for (c in res.setCookies) {
            head += "Set-Cookie: ${c}\r\n"
        }
        head += "\r\n"

        let headBytes = head.toArray()
        let total = Array<UInt8>(headBytes.size + bodyBytes.size, repeat: 0)
        var i = 0
        while (i < headBytes.size) {
            total[i] = headBytes[i]
            i += 1
        }
        var j = 0
        while (j < bodyBytes.size) {
            total[headBytes.size + j] = bodyBytes[j]
            j += 1
        }
        return total
    }
}

/*
 * 带缓冲的连接读取器：每次从套接字中提取出一个完整的 HTTP 消息。它的关键之处
 * 在于会把"读多了"的剩余字节保留在内部缓冲区 buf 里——因为一次 socket.read
 * 可能跨越多个请求的边界（尤其在 keep-alive 长连接上，后一个请求的开头字节
 * 常常和前一个请求一起被读进来）。保留这些剩余字节，下一次 readMessage 就能
 * 接着用，使同一条连接得以连续服务多个请求。
 * 它同时支持两种请求体分帧方式：Content-Length 定长体，以及 chunked 分块体。
 */
class ConnReader {
    let sock: TcpSocket
    let maxBodySize: Int64
    let buf: ArrayList<UInt8> = ArrayList<UInt8>()
    let tmp: Array<UInt8> = Array<UInt8>(4096, repeat: 0)

    init(sock: TcpSocket, maxBodySize: Int64) {
        this.sock = sock
        this.maxBodySize = maxBodySize
    }

    // 从套接字再读一批字节追加到内部缓冲区 buf。读到的字节先落在固定大小的
    // 临时数组 tmp 里，再逐字节搬进 buf。返回 false 表示读取无法继续：可能是
    // 对端关闭连接（read 返回 0，EOF）、读超时，或发生其它异常——这些情况都
    // 被统一当作"没有更多数据可读"处理，由调用方决定如何收尾。返回 true 表示
    // 成功读到了至少一个字节。
    func fill(): Bool {
        try {
            let n = sock.read(tmp)
            if (n <= 0) {
                return false
            }
            var i = 0
            while (i < n) {
                buf.add(tmp[i])
                i += 1
            }
            return true
        } catch (_: Exception) {
            return false
        }
    }

    // 读取并返回一个完整请求的重组字节（头部段 + 请求体），形式上等价于一段
    // 定长报文，便于后续 parseRequest 统一处理。当遇到干净的流末尾、或消息读
    // 到一半就断流（不完整）时返回 None，调用方据此结束这条连接。
    func readMessage(): ?Array<UInt8> {
        // 第一步：不断读直到缓冲区里出现头/体分隔符 "\r\n\r\n"，确定头部已收全。
        var sep = headerSeparatorIndex(buf)
        while (sep < 0) {
            // 防御：若迟迟读不到头部结束符，且累积字节已远超请求体上限再加 64 KiB
            // 的头部余量，说明对端在发送畸形或恶意的超长头部，直接判为体积超限，
            // 避免缓冲区无限增长把内存撑爆。
            if (buf.size > maxBodySize + 65536) {
                throw PayloadTooLargeException()
            }
            if (!fill()) {
                return None
            }
            sep = headerSeparatorIndex(buf)
        }
        let headerSectionEnd = sep + 4
        let headerText = String.fromUtf8(sliceList(buf, 0, sep))

        let chunked = headerIsChunked(headerText)
        if (chunked && headerHasContentLength(headerText)) {
            // 同时出现 Transfer-Encoding: chunked 与 Content-Length 两个头：
            // 这是二义的分帧，也是 RFC 7230 §3.3.3 明确指出的请求走私经典向量。
            // 不去猜测以哪个为准，而是直接拒绝（400），从源头消除走私风险。
            throw BadRequestException()
        }
        if (chunked) {
            // 声明了 chunked，则走分块解码分支，由 readChunked 负责拼出完整体。
            return readChunked(headerSectionEnd)
        }

        // 非 chunked：按 Content-Length 读取定长请求体。缺省（无该头）时为 0。
        let contentLength = headerContentLength(headerText)
        if (contentLength > maxBodySize) {
            // 声明的体长已超过上限，无需真的把它读完，立刻判定体积超限。
            throw PayloadTooLargeException()
        }
        // 持续读取，直到缓冲区里的字节足够覆盖"头部段 + 完整请求体"。中途断流
        // （fill 返回 false）说明请求只发了一半，返回 None 放弃这条连接。
        while (buf.size < headerSectionEnd + contentLength) {
            if (!fill()) {
                return None
            }
        }
        let total = headerSectionEnd + contentLength
        let msg = sliceList(buf, 0, total)
        dropFront(buf, total)
        return Some(msg)
    }

    // 解码 chunked（分块传输）请求体，并重新拼装成"头部段 + 已解码的完整体"。
    // 这样做的目的是：让流水线后续环节（parseRequest 等）只需面对一段普通的、
    // 等价于定长 Content-Length 的消息，完全不必感知分块编码的存在，从而把
    // 分块的复杂性彻底封装在这里。
    // chunked 编码格式为：每个分块以一行十六进制的块大小开头，紧跟该大小的数据
    // 字节，再以 CRLF 收尾；如此重复，直到出现大小为 0 的"结束块"。
    func readChunked(headerSectionEnd: Int64): ?Array<UInt8> {
        let body = ArrayList<UInt8>()
        var pos = headerSectionEnd
        while (true) {
            var lineEnd = findCRLF(buf, pos)
            while (lineEnd < 0) {
                if (!fill()) {
                    return None
                }
                lineEnd = findCRLF(buf, pos)
            }
            let size = parseHexLen(String.fromUtf8(sliceList(buf, pos, lineEnd)))
            pos = lineEnd + 2
            if (size == 0) {
                // 读到大小为 0 的结束块，表示请求体到此结束。这里消费掉结束块后
                // 那个收尾的 CRLF（即结束块与可选 trailer 之间的空行）。注意：本
                // 实现不支持 trailer（结束块之后附带的尾部报文头），仅吃掉这一个
                // CRLF 即认定结束；若对端发了 trailer，会被后续处理忽略。
                var endLine = findCRLF(buf, pos)
                while (endLine < 0) {
                    if (!fill()) {
                        break
                    }
                    endLine = findCRLF(buf, pos)
                }
                if (endLine >= 0) {
                    pos = endLine + 2
                }
                break
            }
            if (body.size + size > maxBodySize) {
                throw PayloadTooLargeException()
            }
            while (buf.size < pos + size + 2) {
                if (!fill()) {
                    return None
                }
            }
            var i = 0
            while (i < size) {
                body.add(buf[pos + i])
                i += 1
            }
            pos += size + 2
        }
        let headerSection = sliceList(buf, 0, headerSectionEnd)
        dropFront(buf, pos)
        let result = ArrayList<UInt8>()
        for (b in headerSection) {
            result.add(b)
        }
        for (b in body) {
            result.add(b)
        }
        return Some(result.toArray())
    }
}

// 在缓冲区里查找头/体分隔符 "\r\n\r\n"（字节序列 13,10,13,10）的起始下标；
// 找不到则返回 -1。它作用在边读边攒的 ArrayList<UInt8> 上，用 -1 而非 None
// 表示"尚未出现"，便于调用方在循环里用 < 0 判断是否需要继续读取更多字节。
func headerSeparatorIndex(buf: ArrayList<UInt8>): Int64 {
    var i = 0
    while (i + 3 < buf.size) {
        if (buf[i] == UInt8(13) && buf[i + 1] == UInt8(10) &&
            buf[i + 2] == UInt8(13) && buf[i + 3] == UInt8(10)) {
            return i
        }
        i += 1
    }
    return -1
}

// 从下标 `from` 起（含 from 本身）查找下一个 "\r\n"（字节 13,10）的位置，
// 返回其起始下标；找不到返回 -1。chunked 解码时用它来定位每行块大小、以及
// 各分块末尾的 CRLF。若传入的 from 为负，则从头（下标 0）开始扫描。
func findCRLF(buf: ArrayList<UInt8>, from: Int64): Int64 {
    var i = if (from < 0) {
        0
    } else {
        from
    }
    while (i + 1 < buf.size) {
        if (buf[i] == UInt8(13) && buf[i + 1] == UInt8(10)) {
            return i
        }
        i += 1
    }
    return -1
}

// 把 ArrayList 缓冲区的 [start, end) 半开区间复制成一个全新的 Array<UInt8>。
// 返回独立副本，与原缓冲区互不影响；当 end <= start 时返回空数组。
func sliceList(buf: ArrayList<UInt8>, start: Int64, end: Int64): Array<UInt8> {
    if (end <= start) {
        return Array<UInt8>()
    }
    let out = Array<UInt8>(end - start, repeat: 0)
    var i = start
    while (i < end) {
        out[i - start] = buf[i]
        i += 1
    }
    return out
}

// 从缓冲区 `buf` 头部丢弃前 `n` 个字节，原地保留其余部分。这是 keep-alive
// 的关键操作：一个请求消费完后，把它占用的字节从缓冲区前端移除，剩下的字节
// （可能是下一个请求的开头）留待后续 readMessage 继续处理。n <= 0 时不做任何
// 改动；n 大于等于缓冲区长度时直接清空。
func dropFront(buf: ArrayList<UInt8>, n: Int64): Unit {
    if (n <= 0) {
        return
    }
    if (n >= buf.size) {
        buf.clear()
        return
    }
    let rest = ArrayList<UInt8>()
    var i = n
    while (i < buf.size) {
        rest.add(buf[i])
        i += 1
    }
    buf.clear()
    for (b in rest) {
        buf.add(b)
    }
}

// 从头部文本中取出 Content-Length 的数值；不存在该头时返回 0。逐行扫描、
// 对头名做小写化与去空白后再比较，以兼容大小写不同的写法。
func headerContentLength(headerText: String): Int64 {
    for (line in headerText.split("\r\n")) {
        let (k, v) = splitOnce(line, ":")
        if (k.toAsciiLower().trimAscii() == "content-length") {
            return parseInt(v.trimAscii())
        }
    }
    return 0
}

// 判断头部块中是否存在 Content-Length 头（只看有无，不取值）。它专门用于
// 走私防护：与 headerIsChunked 配合，检测"同时声明 chunked 与 Content-Length"
// 这种二义分帧。同样对头名做小写化与去空白以兼容各种大小写写法。
func headerHasContentLength(headerText: String): Bool {
    for (line in headerText.split("\r\n")) {
        let (k, _) = splitOnce(line, ":")
        if (k.toAsciiLower().trimAscii() == "content-length") {
            return true
        }
    }
    return false
}

// 判断请求是否声明了 chunked 分块传输编码，即查找 Transfer-Encoding 头并看
// 其值（小写后）是否包含 "chunked"。用 contains 而非全等比较，是为了兼容形如
// "gzip, chunked" 这种带多个编码、chunked 出现在列表中的写法。
func headerIsChunked(headerText: String): Bool {
    for (line in headerText.split("\r\n")) {
        let (k, v) = splitOnce(line, ":")
        if (k.toAsciiLower().trimAscii() == "transfer-encoding") {
            return v.toAsciiLower().contains("chunked")
        }
    }
    return false
}

// 解析 chunked 的块大小行：把行首的十六进制数字（0-9、a-f、A-F）解析为长度。
// 块大小行后面可能跟着以分号引导的"块扩展"（chunk extension，形如 "1a;ext=v"），
// 本函数遇到第一个非十六进制字符（如分号）即停止，从而自然忽略掉该扩展后缀。
func parseHexLen(s: String): Int64 {
    var result = 0
    for (c in s.toArray()) {
        var d = -1
        if (c >= UInt8(48) && c <= UInt8(57)) {
            d = Int64(c) - 48
        } else if (c >= UInt8(65) && c <= UInt8(70)) {
            d = Int64(c) - 55
        } else if (c >= UInt8(97) && c <= UInt8(102)) {
            d = Int64(c) - 87
        } else {
            break
        }
        result = result * 16 + d
    }
    return result
}

// 把查询字符串（如 "a=1&b=2"）解析进 into 这个映射表：先按 "&" 拆成若干
// 键值对，再按第一个 "=" 把每对拆成键与值，并分别做 URL 解码（百分号编码与
// '+' 还原）。空串直接返回；空的键值对片段会被跳过。
public func parseQuery(qs: String, into: HashMap<String, String>): Unit {
    if (qs.isEmpty()) {
        return
    }
    for (pair in qs.split("&")) {
        if (pair.isEmpty()) {
            continue
        }
        let (k, v) = splitOnce(pair, "=")
        into[urlDecode(k)] = urlDecode(v)
    }
}

// 尽力而为（best-effort）的十进制整数解析：从字符串开头逐位读取数字，遇到
// 第一个非数字字符就停止，忽略其后的所有"杂质"。若开头一个数字都没有，则返回
// 0。它不抛异常、不报错，适合解析那些可能不规整的报文头数值。
public func parseInt(s: String): Int64 {
    var result = 0
    let bytes = s.toArray()
    var i = 0
    var any = false
    while (i < bytes.size) {
        let b = bytes[i]
        if (b >= UInt8(48) && b <= UInt8(57)) {
            result = result * 10 + (Int64(b) - 48)
            any = true
        } else {
            break
        }
        i += 1
    }
    if (any) {
        return result
    }
    return 0
}

func hexVal(b: UInt8): Int64 {
    if (b >= UInt8(48) && b <= UInt8(57)) {
        return Int64(b) - 48
    }
    if (b >= UInt8(65) && b <= UInt8(70)) {
        return Int64(b) - 65 + 10
    }
    if (b >= UInt8(97) && b <= UInt8(102)) {
        return Int64(b) - 97 + 10
    }
    return 0
}

// 对 URL 组件做解码：还原百分号编码（%XX）以及把 '+' 还原成空格。关键点在于
// 解码出的字节先统统累积到一个字节缓冲里，直到最后才整体按 UTF-8 解释成字符串。
// 这样一来，一个跨多字节的 UTF-8 序列（例如 "%E4%B8%AD" 对应汉字 "中"）能被
// 完整地重新拼接，而不会因为"每解出一个字节就单独转成字符"而被拆坏、产生乱码。
public func urlDecode(s: String): String {
    let bytes = s.toArray()
    let out = ArrayList<UInt8>()
    var i = 0
    while (i < bytes.size) {
        let c = bytes[i]
        if (c == UInt8(37) && i + 2 < bytes.size) {        // 字节 37 即 '%'，后面跟两位十六进制
            let code = hexVal(bytes[i + 1]) * 16 + hexVal(bytes[i + 2])
            out.add(UInt8(code))
            i += 3
        } else if (c == UInt8(43)) {                       // 字节 43 即 '+'
            out.add(UInt8(32))                             // 还原为字节 32，即空格
            i += 1
        } else {
            out.add(c)
            i += 1
        }
    }
    return String.fromUtf8(out.toArray())
}
