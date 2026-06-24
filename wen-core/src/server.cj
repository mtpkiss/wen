package wen

import std.net.*
import std.collection.*
import std.sync.*

/**
 * 当请求体的字节数超过服务器配置的上限(`maxBodySize`)时抛出此异常。
 *
 * 服务器在 `handleConnection` 的 catch 中捕获它,并向客户端返回 413 Payload Too
 * Large 响应。把"体积超限"建模成专门的异常,是为了和普通的解析错误(400)、未知
 * 错误(500)区分开,从而映射到正确的状态码。继承自 [[HttpException]]。
 */
public class PayloadTooLargeException <: HttpException {
    public init() {
        super(413, "Payload Too Large")
    }
}

/**
 * 当请求的消息分帧(framing)非法时抛出此异常。
 *
 * 最典型的情形是同一请求里同时出现 `Content-Length` 和 `Transfer-Encoding` 两个互
 * 相冲突的报文头——这种二义性正是 HTTP 请求走私(request smuggling)攻击的经典手
 * 法:前后端代理对"以哪个头为准"理解不一致,攻击者就能把一个请求伪装成两个。服务
 * 器一律拒绝这类请求,捕获该异常后返回 400 Bad Request。继承自 [[HttpException]]。
 */
public class BadRequestException <: HttpException {
    public init() {
        super(400, "Bad Request")
    }
}

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

/**
 * 一个直接构建在 TCP 套接字之上的极简 HTTP/1.1 服务器。
 *
 * 工作流程:从套接字读取原始请求字节并解析出 [[HttpRequest]],再配一个空白的
 * [[HttpResponse]],把这对 `(req, res)` 交给 [[Application]] 的中间件链处理,最
 * 后把处理完成的响应序列化成字节写回套接字。
 *
 * 每条连接都通过 `spawn` 在各自独立的轻量线程上处理,互不阻塞。
 *
 * **不建议直接构造**:应用代码通过 [[Application]].listen 间接启动 HttpServer。可
 * 调参数(maxBodySize / readTimeoutMs / maxConnections / maxHeaderBytes)统一在
 * Application 上设置,Application 启动前会一次性同步过来。
 */
public class HttpServer {
    let app: Application

    // 服务器可调参数。**1.0 锁定决定(P0-L)**:这 4 个字段降为同包可见(去 public),
    // 用户配置统一走 Application(app.maxBodySize / app.readTimeoutMs / app.maxConnections
    // / app.maxHeaderBytes)— 单一入口,避免 double-source 锁死("到底 Application
    // 上设的值与 HttpServer 上设的值哪个生效")。Application.buildServer() 在 listen()
    // 启动前把 4 个值一次性拷到这里,运行期不再可写。
    //
    // 允许接收的请求体最大字节数(默认 1 MiB = 1048576 字节)。超过此值会抛出
    // PayloadTooLargeException,从而拒绝过大的请求体,防止单个请求耗尽内存。
    var maxBodySize: Int64 = 1048576
    // 单次套接字读操作的超时时间(毫秒)。它用于防御慢速/空闲的对端:如果一个
    // 客户端建立连接后迟迟不发数据(典型的 Slowloris 慢速攻击),读操作会在
    // 超时后失败,连接随即被放弃,避免线程被长期占住。
    var readTimeoutMs: Int64 = 15000
    // 同时并发处理的连接数上限(默认 1024)。它通过信号量限制在途连接的数量,
    // 从而间接限制了 spawn 出来的线程数:当连接洪水(大量并发连接)涌入时,
    // 多出来的连接会在 accept 之前被挡住,不会无限制地创建线程而把资源耗尽。
    var maxConnections: Int64 = 1024
    // 请求头部块(状态行 + 全部头)的最大字节数,默认 64 KiB。早先头部仅靠
    // `maxBodySize + 65536` 这个组合上限挡 — 当 body 上限被调到几十 MB 时,header
    // 也跟着可以膨胀到几十 MB,单条 Cookie 头都能把内存撑爆。独立设置头部上限是
    // 标准实践(参考 nginx 8 KiB / Apache 8 KiB / Go 1 MiB)。
    var maxHeaderBytes: Int64 = 65536

    // ---- 优雅关闭相关状态 ----
    // 关闭信号:置 true 后,accept 循环退出,handleConnection 不再复用 keep-alive。
    let shutdownRequested: AtomicBool = AtomicBool(false)
    // 当前在途的连接数(每条 TCP 连接一个,无论它处理了几次 keep-alive 请求)。
    // shutdown() 会等到它降为 0 或超时为止。
    let inflight: AtomicInt64 = AtomicInt64(0)
    // drain 完成 / 超时的通知闸门(manual-reset event 模式)。仓颉 std.sync.Semaphore(N)
    // 的 N 既是初始 permits 也是**容量上限**:release() 若让 permits 超过 N 即抛
    // IllegalArgumentException("Invalid amount to release.")。因此容量必须 ≥ 1,并在
    // 构造期 acquire() 拿掉初始 permit,使后续 signalDrainOnce 的 release(+1) 合法,
    // 同时 shutdown() 中的 acquire 真正能阻塞至 release 发生。
    let drainGate: Semaphore = Semaphore(1)
    let drainSignaled: AtomicBool = AtomicBool(false)
    // 当前监听的 server socket;listen 期间存在,shutdown 时关闭以中断阻塞的 accept。
    var serverSocket: ?TcpServerSocket = None

    public init(app: Application) {
        this.app = app
        // 立即拿掉初始 permit;此后 drainGate.acquire() 会阻塞,signalDrainOnce
        // 的 release() 才能唤醒它。
        drainGate.acquire()
    }

    // bind 成功后(端口已可被连接)再触发 onReady;Express 的 listen(port, cb) 语义。
    // 在进入 accept 循环之前调用,因此 onReady 抛异常会让 server 不开始接受连接(自然
    // 关闭 socket)。onReady 默认 None,调用 `listen(port)` 即不带回调。
    public func listen(port: Int64, onReady!: ?(() -> Unit) = None): Unit {
        let server = TcpServerSocket(bindAt: UInt16(port))
        // 先把 serverSocket 挂上去再 bind:其它线程若在 bind 期间提前调用 shutdown(),
        // 能拿到这把 socket 关掉它,免得 bind 完成后再自检 — 关闭路径更可预测。
        // 反过来若先 bind 再赋值,bind 与赋值之间的窗口内 shutdown() 找不到 socket,
        // 只能依赖 bind 完成后自检退出,期间端口短暂被占用又释放,对外可见性不稳定。
        this.serverSocket = Some(server)
        server.bind()
        // bind 已成功,端口对外可见;先触发 onReady。若 onReady 抛异常,将 socket 关掉
        // 再向上冒,避免泄漏。
        match (onReady) {
            case Some(cb) => try {
                cb()
            } catch (e: Exception) {
                try {
                    server.close()
                } catch (_: Exception) {
                    ()
                }
                throw e
            }
            case None => ()
        }
        // 若 shutdown() 在 listen() 之前或 onReady 期间被调用,这里立即退出。
        if (shutdownRequested.load()) {
            try {
                server.close()
            } catch (_: Exception) {
                ()
            }
            return
        }
        // 用信号量给并发量设上限：accept 循环每次循环前先 acquire 一个槽位，
        // 当 maxConnections 个连接都在处理中（槽位耗尽）时，acquire 会阻塞，
        // 整个 accept 循环随之暂停——此时尚未被 accept 的连接会暂存在操作系统的
        // listen backlog 队列里等待。每个处理线程结束时在 finally 里 release
        // 归还槽位，循环便恢复继续 accept。这样无论涌入多少连接，同时存活的
        // 处理线程数都不会超过 maxConnections，杜绝了线程被无限 spawn 的风险。
        let slots = Semaphore(maxConnections)
        while (!shutdownRequested.load()) {
            slots.acquire()
            // 第二次检查:acquire 阻塞期间可能进入 shutdown。
            if (shutdownRequested.load()) {
                slots.release()
                break
            }
            // shutdown 期间 server.close() 会让阻塞的 accept 抛异常,这里 break;
            // 非 shutdown 期间的 accept 异常则视为致命,跳出循环。
            let client = try {
                server.accept()
            } catch (_: Exception) {
                slots.release()
                break
            }
            inflight.fetchAdd(1)
            spawn {
                try {
                    handleConnection(client)
                } finally {
                    slots.release()
                    // 关键:在 shutdown 且 inflight 降至 0 时通知 drain 闸门。
                    // fetchSub 的返回值是 *修改前* 的旧值,旧值 1 即对应新值 0。
                    let prev = inflight.fetchSub(1)
                    if (prev == 1 && shutdownRequested.load()) {
                        signalDrainOnce()
                    }
                }
            }
        }
        // 走出 accept 循环:如果是 shutdown 触发,且 inflight 已经为 0,
        // shutdown() 那边可能还在 acquire 上阻塞,这里兜一次。
        if (shutdownRequested.load() && inflight.load() == 0) {
            signalDrainOnce()
        }
    }

    // 优雅关闭:停止接受新连接,等待在途连接处理完当前请求(并断开 keep-alive),
    // 至多等 timeoutMs 毫秒;timeoutMs <= 0 表示不等(立即返回,留着进程兜底)。
    //
    // 关闭语义:
    //   1. shutdownRequested 置 true:accept 循环退出;keep-alive 连接处理完
    //      当前这次请求后不再复用,响应自动加 `Connection: close`。
    //   2. 关闭 server socket,让阻塞在 accept 上的 listen 协程立即退出。
    //   3. 等 drainGate:在「inflight 降至 0」或「timeoutMs 到」两种事件中谁先发生
    //      谁先唤醒。第一种=优雅完成;第二种=超时强退(在途连接会随进程终结)。
    //
    // 重复调用幂等:已 shutdown 时立即返回 0(无需等待)。
    public func shutdown(timeoutMs!: Int64 = 5000): Unit {
        let already = shutdownRequested.swap(true)
        if (already) {
            return
        }
        // 关 server socket -> accept 异常 -> listen 退出。
        match (this.serverSocket) {
            case Some(s) => try {
                s.close()
            } catch (_: Exception) {
                ()
            }
            case None => ()
        }
        // 立即就绪:目前 inflight=0,无需等待。
        if (inflight.load() == 0) {
            return
        }
        if (timeoutMs <= 0) {
            return
        }
        // watchdog:正常 drain 路径(inflight==0)也会 signalDrainOnce,所以这里把
        // 总 timeoutMs 切成多段 sleep,每段后 check drainSignaled — 一旦 drain 已通知
        // 就立即退出,而不是傻等满超时(P1-I:消除 watchdog 协程泄漏)。100ms 片段
        // 在最坏情况下让 watchdog 延迟退出 < 100ms,对资源占用可忽略。
        spawn {
            let slice: Int64 = 100
            var remaining = timeoutMs
            while (remaining > 0) {
                let step = if (remaining < slice) {
                    remaining
                } else {
                    slice
                }
                sleep(Duration.millisecond * step)
                if (drainSignaled.load()) {
                    return
                }
                remaining -= step
            }
            signalDrainOnce()
        }
        drainGate.acquire()
    }

    // 让 drainGate 只 release 一次:防止 watchdog 与 inflight==0 两条路径都触发,
    // 把 Semaphore 计数推到 > 0 而影响后续语义(虽然本 server 实例一般只 shutdown 一次)。
    func signalDrainOnce(): Unit {
        if (!drainSignaled.swap(true)) {
            drainGate.release()
        }
    }

    func handleConnection(client: TcpSocket): Unit {
        client.readTimeout = Duration.millisecond * readTimeoutMs
        let reader = ConnReader(client, maxBodySize, maxHeaderBytes)
        // 当前这条请求的响应是否已开始写出(响应头已发或连接已被流式劫持)。
        // catch 块据此决定是否再写错误响应 — 已发过字节再写错误响应会让客户端把两份
        // 响应拼起来解析(协议混乱)。每条新请求开始时重置为 false。
        var responseStarted = false
        try {
            while (true) {
                responseStarted = false
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
                // 流式响应已经在 stream/sse 内部写出过响应头;此后无论是否 finished,
                // 都不能再写额外错误响应。
                if (res.headersSent || res.hijacked) {
                    responseStarted = true
                }
                if (!res.finished) {
                    // P0-3:server 兜底 404 对 HEAD 也必须 suppress body。
                    if (req.method == HttpMethod.HEAD) {
                        res.suppressBody = true
                    }
                    res.status(404).send("Not Found")
                }
                // res.hijacked 为真，说明某个流式处理器已经"劫持"了连接，
                // 绕过常规序列化流程直接往套接字写了数据。这类流（如长连接推送）
                // 是以"连接关闭"作为数据结束标志的（connection-delimited），
                // 无法再在同一连接上复用，所以处理完后直接 break 关闭连接。
                if (res.hijacked) {
                    break
                }
                // shutdown 期间不再续 keep-alive:让客户端干脆切到新连接(它会落到
                // 已关闭的 accept 上、被 OS 拒绝;客户端通常会 fallback 到别的实例)。
                let keepAlive = shouldKeepAlive(req) && !shutdownRequested.load()
                let connHeader = if (keepAlive) {
                    "keep-alive"
                } else {
                    "close"
                }
                res.set("Connection", connHeader)
                res.headersSent = true
                responseStarted = true
                client.write(serializeResponse(res))
                if (!keepAlive) {
                    break
                }
            }
        } catch (he: HttpException) {
            // 仅在本条请求的响应头尚未写出时才回错误响应;否则保持沉默,让连接关闭。
            if (!responseStarted) {
                writeError(client, he.status, he.message, he.headers)
            }
        } catch (_: Exception) {
            if (!responseStarted) {
                writeError(client, 500, "Internal Server Error", HashMap<String, String>())
            }
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
        // P1-1:精确匹配 "HTTP/1.1",不能用 contains("1.1") 子串 — 客户端发
        // "HTTP/2.1.1" 等含 1.1 子串的版本不应被当作 HTTP/1.1 默认 keep-alive。
        return req.httpVersion.trimAscii() == "HTTP/1.1"
    }

    func writeError(client: TcpSocket, code: Int64, message: String, headers: HashMap<String, String>): Unit {
        try {
            let res = HttpResponse()
            res.status(code)
            // P0-D:HttpException 携带的响应头(如 Retry-After / WWW-Authenticate /
            // Allow)在底层写错误时也要套上。普通 catch(_)路径传空 map 即可。
            for ((k, v) in headers) {
                res.set(k, v)
            }
            res.send(message)
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
        // 头部块整体 UTF-8 解码:严格拒非法字节(裸 0x80–0xFF 等)。RFC 7230 头值
        // 允许 obs-text(0x80–0xFF),但实践上主流客户端不发,放任高位字节会让
        // headerHasContentLength 等的子串校验出现编码歧义。fromUtf8 抛通用 Exception
        // 时,我们要把它收口成 BadRequestException → 对外 400,而非落到 catch
        // (_: Exception) 映射的 500(协议层错误本应是 400)。
        let headerPart = try {
            String.fromUtf8(subArray(raw, 0, headerEnd))
        } catch (_: Exception) {
            throw BadRequestException()
        }
        let bodyBytes = subArray(raw, bodyStart, raw.size)

        // 拒绝 LF-only 行结束(RFC 7230 要求 CRLF):某些代理会"宽容"地把 LF 当作行
        // 终止符,而 wen 严格按 CRLF 切分 -> 同一报文不同解读 = 走私通道。
        // 凡是出现 \n 而前面不是 \r 的位置,一律拒绝。
        rejectBareLF(headerPart)

        let lines = headerPart.split("\r\n")
        if (lines.size == 0 || lines[0].isEmpty()) {
            throw BadRequestException()
        }
        let requestLine = lines[0]

        // 请求行的形态必须是 "METHOD SP TARGET SP HTTP/x.y";少于两个空格或方法/URI 缺失
        // 一律 400。早先解析后默默生成空 method / 空 path,会让攻击者绕过日志/审计。
        let firstSp = requestLine.indexOf(" ")
        let method: String
        let afterMethod: String
        match (firstSp) {
            case Some(_) =>
                let (m, rest) = splitOnce(requestLine, " ")
                method = m
                afterMethod = rest
            case None => throw BadRequestException()
        }
        if (method.isEmpty() || !isTokenString(method)) {
            // 方法名必须为 RFC 7230 token(字母/数字/部分符号);非 token 字符抛 400。
            throw BadRequestException()
        }
        let secondSp = afterMethod.indexOf(" ")
        let target: String
        let version: String
        match (secondSp) {
            case Some(_) =>
                let (t, v) = splitOnce(afterMethod, " ")
                target = t
                version = v
            case None => throw BadRequestException()
        }
        if (target.isEmpty()) {
            throw BadRequestException()
        }
        // RFC 3986 不允许 URI 含 CTL(<0x21,含 NUL/CR/LF/HT 等)与 DEL(0x7F)。
        // wen 入口若放行 NUL,C 风格的 fs 调用按 NUL 截断 → 路径解析分歧;CR/LF 嵌
        // 入则与某些代理的"宽容行 / 续行"解读分歧 — 都是走私 / 路径绕过的入口。
        // SP(0x20)已被 splitOnce 切掉,这里挡所有 CTL + DEL。
        for (b in target.toArray()) {
            if (b < UInt8(0x21) || b == UInt8(0x7F)) {
                throw BadRequestException()
            }
        }
        // P1-1:HTTP 版本必须严格 ^HTTP/\d+\.\d+$;早先未校验,客户端发 "xx1.1"
        // 或 "HTTP-1.1" 都被吞下,与上游代理对版本的解读分歧形成走私利用面。
        if (!isValidHttpVersion(version)) {
            throw BadRequestException()
        }
        // 防御性目标 URI 长度上限:8 KiB(同等于 nginx/Apache 默认)。极长 URI 多为攻击。
        if (target.size > 8192) {
            throw PayloadTooLargeException()
        }

        let req = HttpRequest(method, target)
        req.httpVersion = version
        // 保存原始 URL(不受任何中间件重写影响)
        req.originalUrl = target

        let (path, queryString) = splitOnce(target, "?")
        req.path = path
        parseQuery(queryString, req.query)

        var i = 1
        while (i < lines.size) {
            let line = lines[i]
            if (!line.isEmpty()) {
                // 行首空白(SP/HTAB)是 RFC 7230 §3.2.4 已被废弃的 "obs-fold" 续行
                // 形式;主流服务器拒绝以避免与代理解读分歧。
                let firstChar = line.toArray()[0]
                if (firstChar == UInt8(32) || firstChar == UInt8(9)) {
                    throw BadRequestException()
                }
                let colonIdx = line.indexOf(":")
                match (colonIdx) {
                    case None => throw BadRequestException()
                    case Some(_) => ()
                }
                let (key, value) = splitOnce(line, ":")
                let nameLow = key.toAsciiLower().trimAscii()
                if (nameLow.isEmpty() || !isTokenString(nameLow)) {
                    // 头名必须是 token;含空格/控制字符的"Hos:t example"会被切出非法 key。
                    throw BadRequestException()
                }
                let raw = value.trimAscii()
                // 头值不允许含 CR/LF/NUL(响应分割的请求侧对偶问题)。
                for (b in raw.toArray()) {
                    if (b == UInt8(13) || b == UInt8(10) || b == UInt8(0)) {
                        throw BadRequestException()
                    }
                }
                // RFC 7230 §3.2.2:同名头(除 Set-Cookie)按 "," 合并保留多值。
                // 早先后值静默覆盖前值,会让 Cookie / X-Forwarded-For 等多值头丢失。
                //
                // 单值头例外:RFC 7231 §3.1.1 第 5 段明确 Content-Type 必须是单值。允许其合并
                // 会让 "application/json" + "image/png" 被 decodeBodyTextIfApplicable 的
                // startsWith 仍然命中 — body 被当 UTF-8 解码进 req.body,业务据此判定"是
                // JSON"实际是 PNG → 类型混淆。出现第二次 Content-Type 一律 400。
                if (nameLow == "content-type" && req.headers.get(nameLow).isSome()) {
                    throw BadRequestException()
                }
                // P1-2:同理,RFC 7230 §5.4 要求每条请求**有且仅有一个** Host 头。
                // 之前 Host 走通用合并路径(`h1, h2`),vhost 分发场景里攻击者可借
                // `Host: real\r\nHost: evil` 让代理 / wen 看到不同 vhost — 走私利用面。
                if (nameLow == "host" && req.headers.get(nameLow).isSome()) {
                    throw BadRequestException()
                }
                match (req.headers.get(nameLow)) {
                    case Some(existing) => req.headers[nameLow] = "${existing}, ${raw}"
                    case None => req.headers[nameLow] = raw
                }
            }
            i += 1
        }

        req.bodyBytes = bodyBytes
        // 文本 body 视图:仅当 Content-Type 主类型属于文本族(json/xml/x-www-form-
        // urlencoded/text-*)时才进行 UTF-8 解码;二进制负载(图片/protobuf/gzip 等)
        // 跳过解码,避免大请求的无谓 CPU 开销和潜在的 UTF-8 异常波及 parseRequest。
        // 解码本身也用 try-catch 兜底:出现非法 UTF-8 字节时置空串(req.bodyBytes 仍可用)。
        req.body = decodeBodyTextIfApplicable(bodyBytes, req)
        return req
    }

    // 判定 Content-Type 是否是「需要文本视图」的类型 — 仅这些类型才付出 UTF-8 解码代价。
    func decodeBodyTextIfApplicable(bodyBytes: Array<UInt8>, req: HttpRequest): String {
        if (bodyBytes.size == 0) {
            return ""
        }
        let ct = match (req.headers.get("content-type")) {
            case Some(v) => v.toAsciiLower()
            case None => ""
        }
        let needsText = (ct.startsWith("text/")
            || ct.startsWith("application/json")
            || ct.startsWith("application/xml")
            || ct.startsWith("application/x-www-form-urlencoded")
            || ct.startsWith("application/javascript")
            || ct.startsWith("application/ld+json")
            || ct.isEmpty()) // 无 Content-Type 时,保持兼容:尝试解码
        if (!needsText) {
            return ""
        }
        try {
            return String.fromUtf8(bodyBytes)
        } catch (_: Exception) {
            return ""
        }
    }

    // 拒绝裸 LF(无前导 CR)出现在头部块:防止与上游代理对行边界的解读分歧。
    func rejectBareLF(headerPart: String): Unit {
        let bytes = headerPart.toArray()
        var i = 0
        while (i < bytes.size) {
            if (bytes[i] == UInt8(10)) {
                if (i == 0 || bytes[i - 1] != UInt8(13)) {
                    throw BadRequestException()
                }
            }
            i += 1
        }
    }

    // RFC 7230 token 字符集:!#$%&'*+-.^_`|~ 与 ALPHA / DIGIT。用于校验方法名 / 头名。
    func isTokenString(s: String): Bool {
        if (s.isEmpty()) {
            return false
        }
        for (b in s.toArray()) {
            if (!isTokenByte(b)) {
                return false
            }
        }
        return true
    }

    func isTokenByte(b: UInt8): Bool {
        if ((b >= UInt8(65) && b <= UInt8(90)) || (b >= UInt8(97) && b <= UInt8(122))) {
            return true
        }
        if (b >= UInt8(48) && b <= UInt8(57)) {
            return true
        }
        // !#$%&'*+-.^_`|~
        if ((b == UInt8(33) || b == UInt8(35) || b == UInt8(36) || b == UInt8(37) || b == UInt8(38)
            || b == UInt8(39) || b == UInt8(42) || b == UInt8(43) || b == UInt8(45) || b == UInt8(46)
            || b == UInt8(94) || b == UInt8(95) || b == UInt8(96) || b == UInt8(124) || b == UInt8(126))) {
            return true
        }
        return false
    }

    // headerSeparatorIndex 的 Array 版本：在原始字节数组里扫描头/体分隔符
    // "\r\n\r\n"（字节 13,10,13,10），返回其起始下标；找不到则返回 None。
    // 之所以单独有个数组版本，是因为这里处理的是已经读全的 Array<UInt8>，
    // 而 ConnReader 里那个同名逻辑作用在边读边攒的 ArrayList<UInt8> 上。
    func indexOfHeaderEndArr(buf: Array<UInt8>): ?Int64 {
        var i = 0
        while (i + 3 < buf.size) {
            if (buf[i] == UInt8(13) && buf[i + 1] == UInt8(10) && buf[i + 2] == UInt8(13) && buf[i + 3] == UInt8(10)) {
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
        // 补上 Date 响应头(HTTP/1.1 建议服务器发送当前时间)。
        ensureDateHeader(res)
        applyCharsetIfSet(res)
        // 按 RFC 7230 / 7231 规定:
        //   - 1xx(100 Continue / 101 Switching Protocols / 102 / 103):MUST NOT
        //     含 Content-Length,且必须无 body。
        //   - 204 No Content / 304 Not Modified:同 1xx,既不带 body 也不带 CL。
        //   - 205 Reset Content:必须无 body,但 RFC 7231 §6.3.6 要求显式带
        //     "Content-Length: 0"(或 chunked 空块) —— 它不在 §3.3.2 的 MUST NOT
        //     列表里,反而需要明确 framing,否则 keep-alive 连接上的下一个响应
        //     头会被客户端当成上一个响应的 body 读。
        // 所以下面把 1xx/204/205/304 都纳入 bodyless,然后用 mustZeroCL 把 205
        // 单独拎出来强制写 CL: 0;其余仍走"删 CL"路径。
        let bodyless = res.statusCode == 204 || res.statusCode == 205
            || res.statusCode == 304 || (res.statusCode >= 100 && res.statusCode < 200)
        let mustZeroCL = res.statusCode == 205
        // 用户若显式写过 Transfer-Encoding(典型场景:自己实现 chunked / SSE),
        // 框架不能再自动写 Content-Length — 同时声明 TE + CL 违反 RFC 7230
        // §3.3.3,接收方按 chunked 解析 4 字节裸 body 会失败,与上游反代对响应边
        // 界产生分歧(响应方向的 framing 走私 / 缓存污染基底)。尊重用户意图、
        // 跳过自动 CL。
        let userSetTE = res.get("Transfer-Encoding").isSome()
        // res.suppressBody 为真对应 HEAD 请求的响应:HEAD 要求返回与同样的 GET
        // 完全一致的头部(包括那个表示 GET 正文长度的 Content-Length),但绝不
        // 发送正文。所以这里保留已设好的 Content-Length,只把正文置空。其余普通
        // 情况则根据实际正文内容计算并写入 Content-Length。
        let bodyBytes = if (res.suppressBody) {
            Array<UInt8>()
        } else if (bodyless) {
            if (mustZeroCL) {
                res.set("Content-Length", "0")
            } else {
                res.remove("Content-Length")
            }
            Array<UInt8>()
        } else if (userSetTE) {
            let real = match (res.bodyBytes) {
                case Some(raw) => raw
                case None => res.body.toArray()
            }
            res.remove("Content-Length")
            real
        } else {
            let real = match (res.bodyBytes) {
                case Some(raw) => raw
                case None => res.body.toArray()
            }
            res.set("Content-Length", real.size.toString())
            real
        }

        // 状态行 + 响应头 + Set-Cookie 行 + 终止空行(与流式响应共用 buildHeadBlock)。
        let headBytes = buildHeadBlock(res)
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

// 构造 HTTP 响应的头部块字节:状态行 + 各响应头 + 各 Set-Cookie 行(HTTP 不允许把多个
// cookie 合并到一行,故逐条输出)+ 终止空行。serializeResponse 与流式响应的 StreamWriter.begin
// 共用它,避免两处重复拼装。
//
// Perf-1:用 ArrayList<UInt8> 流式追加替代 `head += "..."` 的 O(n²) 字符串拼接。
// 100 头 → 旧实现约 100KB 中间拷贝、1000 头 → 约 10MB。两个调用方原本都立刻
// `.toArray()`,改返字节后省一次 String 中转。
//
// 安全兜底:所有键、值、Set-Cookie 行进入序列化前再次过 checkHeaderSafe;即使有人绕过
// HttpResponse 的 API、直接往 res.headers 写入了含 CR/LF/NUL 的值,这里也会拒绝(抛异常,
// 由上层错误处理流水线兜底),从而彻底堵住 HTTP 响应分割注入。
func buildHeadBlock(res: HttpResponse): Array<UInt8> {
    let out = ArrayList<UInt8>()
    // 状态行写入前校验:statusMessage 不许含 CR/LF/NUL(否则响应字节里夹入伪头,
    // 等同状态行级别的响应分割),statusCode 必须落在 100..999。statusMessage 与
    // statusCode 都是 public var,任何中间件 / 业务代码都能写,框架必须在最后一道
    // 兜底也校验一遍,与 res.set 入口的 checkHeaderSafe 形成对偶。
    checkHeaderSafe(res.statusMessage)
    let code = if (res.statusCode < 100 || res.statusCode > 999) {
        500
    } else {
        res.statusCode
    }
    appendAscii(out, "HTTP/1.1 ")
    appendAscii(out, code.toString())
    appendAscii(out, " ")
    appendAscii(out, res.statusMessage)
    appendAscii(out, "\r\n")
    for ((k, v) in res.headers) {
        checkHeaderSafe(k)
        checkHeaderSafe(v)
        appendAscii(out, k)
        appendAscii(out, ": ")
        appendAscii(out, v)
        appendAscii(out, "\r\n")
    }
    for (c in res.setCookies) {
        checkHeaderSafe(c)
        appendAscii(out, "Set-Cookie: ")
        appendAscii(out, c)
        appendAscii(out, "\r\n")
    }
    appendAscii(out, "\r\n")
    return out.toArray()
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
    let maxHeaderBytes: Int64
    let buf: ArrayList<UInt8> = ArrayList<UInt8>()
    // 缓冲区前端已被「逻辑消费」的字节数。dropFront 仅推进这个指针即可在 O(1)
    // 摊销内完成 keep-alive 之间的字节剪裁,无需把剩余字节整段拷回;真正的物理
    // 压缩(把有效字节搬回 0 位置、释放垃圾)只在累计废字节超过 maxHeaderBytes
    // 时触发一次。早先版本每条 keep-alive 请求结束都要做一次完整 O(n) 拷贝,
    // 高频小请求下退化成 O(n²)。
    var readStart: Int64 = 0
    let tmp: Array<UInt8> = Array<UInt8>(4096, repeat: 0)

    init(sock: TcpSocket, maxBodySize: Int64, maxHeaderBytes: Int64) {
        this.sock = sock
        this.maxBodySize = maxBodySize
        this.maxHeaderBytes = maxHeaderBytes
    }

    // 逻辑可用字节数 = 物理 buf 大小 - 已消费指针。下面的扫描 / 切片均以"逻辑
    // 下标 0 = readStart"为起点。
    func available(): Int64 {
        return buf.size - readStart
    }

    // 取逻辑下标 i 处的字节。等价于 buf[readStart + i],但调用方不必感知物理偏移。
    func byteAt(i: Int64): UInt8 {
        return buf[readStart + i]
    }

    // 从套接字再读一批字节追加到内部缓冲区 buf。读到的字节先落在固定大小的
    // 临时数组 tmp 里，再逐字节搬进 buf。返回 false 表示读取无法继续：可能是
    // 对端关闭连接（read 返回 0，EOF）、读超时，或发生其它异常——这些情况都
    // 被统一当作"没有更多数据可读"处理，由调用方决定如何收尾。返回 true 表示
    // 成功读到了至少一个字节。
    // **P2-E 已知约束**:EOF / 超时 / IO 异常折叠成同一返回值 false,server 层无法
    // 区分"正常关闭""慢速攻击触发上限""对端 reset"。生产观察 timeout 命中率 / reset
    // 频率需要在反代层(nginx 等)做,wen 1.0 不引入 onConnectionError hook。
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

    // 在「逻辑视图」里查找头/体分隔符 "\r\n\r\n"(13,10,13,10),返回其逻辑下标;
    // 找不到返回 -1。物理上从 buf[readStart..] 扫起,但对调用者透明。
    func headerSeparatorIndex(): Int64 {
        let lim = buf.size - 3
        var i = readStart
        while (i < lim) {
            if (buf[i] == UInt8(13) && buf[i + 1] == UInt8(10)
                && buf[i + 2] == UInt8(13) && buf[i + 3] == UInt8(10)) {
                return i - readStart
            }
            i += 1
        }
        return -1
    }

    // 从「逻辑下标 from」起查找下一个 CRLF;找不到返回 -1。from 为负则视为 0。
    func findCRLF(from: Int64): Int64 {
        let logicalStart = if (from < 0) {
            0
        } else {
            from
        }
        let lim = buf.size - 1
        var i = readStart + logicalStart
        while (i < lim) {
            if (buf[i] == UInt8(13) && buf[i + 1] == UInt8(10)) {
                return i - readStart
            }
            i += 1
        }
        return -1
    }

    // 取「逻辑视图」的 [start, end) 半开区间,返回独立 Array<UInt8> 副本。
    func sliceList(start: Int64, end: Int64): Array<UInt8> {
        if (end <= start) {
            return Array<UInt8>()
        }
        let out = Array<UInt8>(end - start, repeat: 0)
        let base = readStart + start
        var i = 0
        let n = end - start
        while (i < n) {
            out[i] = buf[base + i]
            i += 1
        }
        return out
    }

    // 丢弃逻辑视图前 n 个字节。仅推进 readStart;只在累计废字节超过 maxHeaderBytes
    // 阈值时才做一次物理压缩(把剩余有效字节搬到 buf 起点)。n <= 0 不做改动;
    // n >= 可用字节则清空整个缓冲。
    func dropFront(n: Int64): Unit {
        if (n <= 0) {
            return
        }
        let avail = buf.size - readStart
        if (n >= avail) {
            buf.clear()
            readStart = 0
            return
        }
        readStart += n
        // 累计垃圾过多时做一次性 compact:把 [readStart..buf.size) 搬到 [0..rem),
        // 再把尾巴砍掉。摊销代价 O(1)/请求。
        if (readStart >= maxHeaderBytes) {
            let rem = buf.size - readStart
            var i = 0
            while (i < rem) {
                buf[i] = buf[readStart + i]
                i += 1
            }
            // 用 remove(range) 截断尾部;ArrayList.remove 支持 range 半开区间。
            buf.remove(rem..buf.size)
            readStart = 0
        }
    }

    // 读取并返回一个完整请求的重组字节（头部段 + 请求体），形式上等价于一段
    // 定长报文，便于后续 parseRequest 统一处理。当遇到干净的流末尾、或消息读
    // 到一半就断流（不完整）时返回 None，调用方据此结束这条连接。
    func readMessage(): ?Array<UInt8> {
        // 第一步:不断读直到缓冲区里出现头/体分隔符 "\r\n\r\n",确定头部已收全。
        // 头部块有独立上限 maxHeaderBytes(默认 64 KiB),不再混用 maxBodySize 兜底。
        // 早先「maxBodySize + 65536」组合让 body 上限被调高时 header 也跟着无限放宽,
        // 单条 Cookie 头就可耗光内存。
        var sep = headerSeparatorIndex()
        while (sep < 0) {
            if (available() > maxHeaderBytes) {
                throw PayloadTooLargeException()
            }
            if (!fill()) {
                return None
            }
            sep = headerSeparatorIndex()
        }
        let headerSectionEnd = sep + 4
        let headerText = String.fromUtf8(sliceList(0, sep))

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
        while (available() < headerSectionEnd + contentLength) {
            if (!fill()) {
                return None
            }
        }
        let total = headerSectionEnd + contentLength
        let msg = sliceList(0, total)
        dropFront(total)
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
        // P1-3:headerSection 先取出来再立刻 dropFront — 之后循环里每完成一个 chunk
        // 都可以触发物理 compact,buf 不会无限膨胀。早先实现把 pos 单调推进、末尾才
        // dropFront,攻击者用 1 字节 chunk 流可让单条连接 buf 物理 size 远超 maxBodySize
        // (后者只算 body 累积字节,不看 buf 的物理 size)。
        let headerSection = sliceList(0, headerSectionEnd)
        dropFront(headerSectionEnd)
        var pos: Int64 = 0
        while (true) {
            var lineEnd = findCRLF(pos)
            // 单行预算保护:每个 chunk-size 行最多 maxHeaderBytes 字节(规范上只需
            // 几十字节存十六进制大小 + chunk-extension)。若客户端持续灌字符却不发
            // CRLF,fill 会无限把数据搬进 buf,单条恶意连接即可推到 OOM。先于 fill
            // 检查"当前行已累积字节数",超出立刻 413 拒。
            while (lineEnd < 0) {
                if (available() - pos > maxHeaderBytes) {
                    throw PayloadTooLargeException()
                }
                if (!fill()) {
                    return None
                }
                lineEnd = findCRLF(pos)
            }
            let size = parseHexLen(String.fromUtf8(sliceList(pos, lineEnd)))
            // 单块大小本身就不能超过 body 上限,且必须非负。早 reject 比延迟到累加后更稳妥。
            if (size < 0 || size > maxBodySize) {
                throw PayloadTooLargeException()
            }
            pos = lineEnd + 2
            if (size == 0) {
                // 读到大小为 0 的结束块,RFC 7230 §4.1.2 之后是 trailer-part:零或多个
                // header-field 行,最后一行是空行结束。早先实现只消费 size=0 后的紧跟
                // CRLF,把"可能存在的 trailer 字段"留在 buf 里 — 残留字节被下一次
                // readMessage 当作下一个请求的开头解析,构成请求走私(round3 P1-12)。
                //
                // 修复:循环读取行直到看到空行为止。trailer 字段不解析(本实现不支持),
                // 但必须 drain 干净;trailer 累计字节有 maxHeaderBytes 上限,防 DoS。
                // EOF 时返 None(残缺帧不应当作完整请求,修白盒报告 G1)。
                let trailerStart = pos
                while (true) {
                    var endLine = findCRLF(pos)
                    // 同 chunk-size 行的预算保护:trailer 行单行也按 maxHeaderBytes
                    // 截。无此防护时,trailer 段一行不发 CRLF 也能让 buf 无界增长 —
                    // 与 chunk-size 行同款 OOM 路径,只是触发点不同。
                    while (endLine < 0) {
                        if (available() - pos > maxHeaderBytes) {
                            throw PayloadTooLargeException()
                        }
                        if (!fill()) {
                            return None
                        }
                        endLine = findCRLF(pos)
                    }
                    // 空行(CRLF 紧贴当前位置)即 trailer 段终止。
                    if (endLine == pos) {
                        pos += 2
                        break
                    }
                    // 非空行 = 一个 trailer 字段,直接跳过。
                    pos = endLine + 2
                    if (pos - trailerStart > maxHeaderBytes) {
                        throw PayloadTooLargeException()
                    }
                }
                break
            }
            // 用减法形式校验防止 body.size + size 的 Int64 加法溢出绕过检查。
            // 上面已确保 size <= maxBodySize、size >= 0,因此 maxBodySize - size 不会下溢。
            if (body.size > maxBodySize - size) {
                throw PayloadTooLargeException()
            }
            while (available() < pos + size + 2) {
                if (!fill()) {
                    return None
                }
            }
            var i = 0
            while (i < size) {
                body.add(byteAt(pos + i))
                i += 1
            }
            pos += size + 2
            // P1-3:每完成一个 chunk 触发一次 dropFront,让 dropFront 的摊销 compact
            // 在小 chunk 流上正常工作 — pos 推进过 maxHeaderBytes 阈值就会做物理压缩。
            dropFront(pos)
            pos = 0
        }
        // 此处 headerSection 是入口处已取出的副本;buf 内的字节早在循环中陆续被 drop。
        dropFront(pos)
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

// 从头部文本中取出 Content-Length 的数值;不存在该头时返回 0。
//
// 走私防护:
//   1. 多个 Content-Length 头(无论值是否相同)一律视为非法分帧 -> 抛 BadRequest。
//      RFC 7230 §3.3.3 要求拒绝;若仅取第一个,前后代理对"以哪个为准"理解不一致即可
//      实施 CL.CL 走私。
//   2. 值必须严格为十进制数字 [0-9]+,不允许空白、正负号、十六进制前缀或附加字符。
//      parseInt 风格的"宽松正常化"会让 wen 与代理对同一个 Content-Length 给出不同
//      解读,构成走私入口。
func headerContentLength(headerText: String): Int64 {
    var found = -1
    for (line in headerText.split("\r\n")) {
        let (k, v) = splitOnce(line, ":")
        if (k.toAsciiLower().trimAscii() == "content-length") {
            let n = parseContentLengthStrict(v.trimAscii())
            if (found >= 0 && found != n) {
                // 多个 Content-Length 值不一致:典型走私构造。
                throw BadRequestException()
            }
            if (found >= 0) {
                // 多个同值的 Content-Length 也拒绝(RFC 严格要求只有一个)。
                throw BadRequestException()
            }
            found = n
        }
    }
    if (found < 0) {
        return 0
    }
    return found
}

// 严格解析 Content-Length 值:仅接受十进制 [0-9]+,空串 / 含空白 / 负号 / 非数字字符
// 一律抛 BadRequestException。不要复用宽松的 parseInt,后者会把 "5abc"、"-5"、""
// 等都正常化成数字,与上游代理结果不一致 -> 请求走私。
func parseContentLengthStrict(s: String): Int64 {
    if (s.isEmpty()) {
        throw BadRequestException()
    }
    let bytes = s.toArray()
    var result: Int64 = 0
    for (b in bytes) {
        if (b < UInt8(48) || b > UInt8(57)) {
            throw BadRequestException()
        }
        let d = Int64(b) - 48
        // 防 Int64 溢出:result*10+d 大于 Int64.Max 时拒绝。
        if (result > (Int64(0x7FFFFFFFFFFFFFFF) - d) / 10) {
            throw BadRequestException()
        }
        result = result * 10 + d
    }
    return result
}

// 判断头部块中是否存在 Content-Length 头(只看有无,不取值)。专门用于走私防护:
// 与 headerIsChunked 配合,检测"同时声明 chunked 与 Content-Length"这种二义分帧。
//
// obs-fold 续行(行首 SP/HT)不是独立头,而是上一条头 value 的续接;parseRequest 阶段
// 已拒整段含 obs-fold 的请求,但 readMessage 在更早的预扫阶段也会跑这个函数判分帧。
// 这里同样跳过 obs-fold 续行,避免续行内容凑巧形如 "Content-Length: 5" 时被误识为
// 真有 CL 头(合法请求被错拒为走私分帧)。
func headerHasContentLength(headerText: String): Bool {
    for (line in headerText.split("\r\n")) {
        if (line.isEmpty()) {
            continue
        }
        let firstByte = line.toArray()[0]
        if (firstByte == UInt8(32) || firstByte == UInt8(9)) {
            continue
        }
        let (k, _) = splitOnce(line, ":")
        if (k.toAsciiLower().trimAscii() == "content-length") {
            return true
        }
    }
    return false
}

// 判断请求是否声明了 chunked 分块传输编码。
//
// 走私防护:严格按 RFC 7230 §3.3.1 的 token 列表语义解析:
//   1. 收集**全部** Transfer-Encoding 头(可能出现多次),按 "," 拆成 token 序列;
//   2. 任何 token 等于 "chunked"(大小写无关、去空白)则视为 chunked;
//   3. RFC 要求 chunked 若出现必须是**最后一个** transfer-coding;否则拒绝(400)。
//      不满足时返回 false 让调用方按非 chunked 处理 — 此分支配合 CL 校验仍能拦截。
// 早先用 v.toAsciiLower().contains("chunked") 会把 "xchunked" 误判为 chunked,
// 让 wen 与不同代理产生分帧分歧 -> TE.TE 走私。
func headerIsChunked(headerText: String): Bool {
    var anyChunked = false
    var chunkedIsLast = false
    for (line in headerText.split("\r\n")) {
        if (line.isEmpty()) {
            continue
        }
        // 同 headerHasContentLength:跳过 obs-fold 续行,避免续行内容误识为
        // 独立 Transfer-Encoding 头。
        let firstByte = line.toArray()[0]
        if (firstByte == UInt8(32) || firstByte == UInt8(9)) {
            continue
        }
        let (k, v) = splitOnce(line, ":")
        if (k.toAsciiLower().trimAscii() != "transfer-encoding") {
            continue
        }
        let parts = v.split(",")
        var i = 0
        while (i < parts.size) {
            let tok = parts[i].trimAscii().toAsciiLower()
            if (tok == "chunked") {
                anyChunked = true
                chunkedIsLast = (i == parts.size - 1)
            } else if (tok.isEmpty()) {
                ()
            } else {
                chunkedIsLast = false
            }
            i += 1
        }
    }
    if (anyChunked && !chunkedIsLast) {
        // chunked 不是最后一个 transfer-coding,按 RFC 视为非法分帧。
        throw BadRequestException()
    }
    return anyChunked
}

// P1-1:严格校验请求行 HTTP 版本格式:必须形如 HTTP/<digits>.<digits>。早先用
// contains("1.1") 子串匹配 / 不校验格式,客户端发 "HTTP/2.1.1" 或 "xx1.1" 会被
// 当成 1.1,与上游代理对版本的解读分歧形成走私利用面。
func isValidHttpVersion(s: String): Bool {
    if (!s.startsWith("HTTP/")) {
        return false
    }
    let rest = s[5..s.size]
    let dot = rest.indexOf(".")
    let dotIdx = match (dot) {
        case Some(i) => i
        case None => return false
    }
    if (dotIdx == 0 || dotIdx == rest.size - 1) {
        return false
    }
    let major = rest[0..dotIdx]
    let minor = rest[(dotIdx + 1)..rest.size]
    return allAsciiDigits(major) && allAsciiDigits(minor)
}

func allAsciiDigits(s: String): Bool {
    if (s.isEmpty()) {
        return false
    }
    for (b in s.toArray()) {
        if (b < UInt8(48) || b > UInt8(57)) {
            return false
        }
    }
    return true
}

// 解析 chunked 的块大小行:把行首的十六进制数字(0-9、a-f、A-F)解析为长度。
// 块大小行后面可能跟着以分号引导的"块扩展"(chunk extension,形如 "1a;ext=v"),
// 本函数遇到第一个非十六进制字符(如分号)即停止,从而自然忽略掉该扩展后缀。
//
// 走私 / DoS 防护:
//   - 空串(连一位 hex 都没有)抛 BadRequestException — 早先静默返回 0 会把"残缺块"
//     当成"结束块"提前终止解析,body 截断后被当成正常请求传给路由,与代理对同一字节流
//     的解读不一致。
//   - 最多接受 16 位 hex(Int64 表示上限),超出抛 BadRequestException;并在累加过程中
//     检测 Int64 溢出。早先无位数 / 溢出检测会让 size 在 body.size+size > maxBodySize
//     检查里溢出为负,绕过 PayloadTooLarge,继而触发 OOM / 内存放大。
func parseHexLen(s: String): Int64 {
    let bytes = s.toArray()
    var result: Int64 = 0
    var digits = 0
    for (c in bytes) {
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
        digits += 1
        if (digits > 16) {
            // Int64 上限就是 16 个 hex(0x7FFFFFFFFFFFFFFF),超过即溢出。
            throw BadRequestException()
        }
        // 检测 result * 16 + d 是否溢出 Int64.MaxValue。
        if (result > (Int64(0x7FFFFFFFFFFFFFFF) - d) / 16) {
            throw BadRequestException()
        }
        result = result * 16 + d
    }
    if (digits == 0) {
        // 空 chunk-size 行属于残缺分帧,拒绝。
        throw BadRequestException()
    }
    return result
}

// 把查询字符串（如 "a=1&b=2"）解析进 into 这个映射表：先按 "&" 拆成若干
// 键值对，再按第一个 "=" 把每对拆成键与值，并分别做 URL 解码（百分号编码与
// '+' 还原）。空串直接返回；空的键值对片段会被跳过。
// **P2-C 单值语义**:同名键后写覆盖前写(`?tag=a&tag=b` → 只留 `b`)。这是
// HashMap 的写入语义,**与 Express 数组形式不同**。需要多值时,业务请自己解析
// req.url 的查询串部分,或通过额外 API(暂未提供 queryAll)。
func parseQuery(qs: String, into: HashMap<String, String>): Unit {
    if (qs.isEmpty()) {
        return
    }
    for (pair in qs.split("&")) {
        if (pair.isEmpty()) {
            continue
        }
        let (k, v) = splitOnce(pair, "=")
        // key 保留原始字节(不做 urlDecode):防 "?admin=user&%61dmin=root" 这种
        // 携带百分号编码 key 的请求被合并成同一条目(last-wins 后 admin=root,
        // 业务用 wen 看到的与上游 WAF / 反代按字节相等去重的视图不一致 → ACL
        // 绕过)。value 仍正常解码,符合 application/x-www-form-urlencoded 规范。
        into[k] = urlDecode(v)
    }
}

// 尽力而为（best-effort）的十进制整数解析：从字符串开头逐位读取数字，遇到
// 第一个非数字字符就停止，忽略其后的所有"杂质"。若开头一个数字都没有，则返回
// 0。它不抛异常、不报错，适合解析那些可能不规整的报文头数值。
func parseInt(s: String): Int64 {
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

/**
 * 对 URL 组件做解码:还原百分号编码(`%XX`)以及把 `+` 还原成空格。
 *
 * 关键点在于解码出的字节先统统累积到一个字节缓冲里,直到最后才整体按 UTF-8 解释成
 * 字符串。这样一来,一个跨多字节的 UTF-8 序列(例如 `%E4%B8%AD` 对应汉字"中")能
 * 被完整地重新拼接,而不会因为"每解出一个字节就单独转成字符"而被拆坏、产生乱码。
 *
 * **可见性(P0-J)**:benchmark 子项目用它做 URL 解码基准测试。
 */
public func urlDecode(s: String): String {
    let bytes = s.toArray()
    let out = ArrayList<UInt8>()
    var i = 0
    while (i < bytes.size) {
        let c = bytes[i]
        if (c == UInt8(37)) { // '%'
            // 严格百分号解码:必须紧跟两位有效十六进制数字。残缺的 %X / 末尾的 %
            // 或非 hex 字符(%GG)早先静默吞成 NUL 字节或保留 %,与代理对路径的
            // 解读会产生分歧,可被用于路径绕过 / 走私。一律原样保留剩余字节,让
            // 上层(如路径沙箱)按字面拦截。
            if (i + 2 >= bytes.size || !isHexByte(bytes[i + 1]) || !isHexByte(bytes[i + 2])) {
                out.add(c)
                i += 1
                continue
            }
            let code = hexVal(bytes[i + 1]) * 16 + hexVal(bytes[i + 2])
            out.add(UInt8(code))
            i += 3
        } else if (c == UInt8(43)) { // 字节 43 即 '+'
            out.add(UInt8(32)) // 还原为字节 32,即空格
            i += 1
        } else {
            out.add(c)
            i += 1
        }
    }
    return String.fromUtf8(out.toArray())
}
