package wen

import std.collection.*
import std.fs.*

/**
 * 一个待发出的 HTTP 响应对象。
 *
 * 工作方式:各方法只是不断在对象上累积状态(状态码、响应头、响应体等),真正把一个
 * "已完成"的响应序列化并写入 socket 的工作由服务端统一完成。大量设置类方法都返回
 * `this`,从而支持链式调用,风格对应 Express 的
 * `res.status(201).set(...).send(...)`。
 */
public class HttpResponse {
    public var statusCode: Int64 = 200
    public var statusMessage: String = "OK"
    // 响应头存储:按"用户提供的原始大小写"为 key 存值,序列化时直接迭代输出 —
    // 这样 `Content-Type` / `WWW-Authenticate` / `ETag` 等头保留惯例大小写,不会
    // 被强制 prettify。同时 headersLookup(lowercase → 原始 key)做 case-insensitive
    // 去重:`set("X-Foo", "a")` 后 `set("x-foo", "b")` 视为同一头(覆盖,而非双发)。
    //
    // 字段同包可见(buildHeadBlock 等需迭代),包外只能通过 set/get/append/remove/has
    // 访问器读写 — 把大小写一致性纳入 API 契约,杜绝同名头大小写双发。
    let headers: HashMap<String, String>
    let headersLookup: HashMap<String, String>
    // 每个 Cookie 都需要一行独立的 Set-Cookie 响应头,而 headers 是"一个键对应
    // 一个值"的映射,无法表达同名头出现多次的情形。因此待发出的 Cookie 不放进
    // headers,而是单独存到这个列表里,序列化时逐条输出为多行 Set-Cookie。
    public let setCookies: ArrayList<String>
    public var body: String = ""
    // 一旦设置了该字段,响应体就以这份原始字节为准(用于二进制负载),此时上面的
    // 文本字段 `body` 会被忽略。这使得中间件 / 处理器能够输出图片、gzip 压缩数据
    // 等二进制内容,而不必经过字符串编码。默认 None,表示使用文本 `body`。
    public var bodyBytes: ?Array<UInt8> = None
    public var finished: Bool = false

    // 指向本次响应所对应的请求对象(对应 Express 的 res.req),由 app.handle 在
    // 派发时设置。sendFile 等方法借它读取条件请求(If-None-Match)与 Range 头,
    // 从而支持 304 缓存协商与 206 分片下载。未经 app.handle 驱动(如直接构造 res
    // 的测试场景)时为 None,此时文件类方法退化为发送完整内容。
    public var req: ?HttpRequest = None

    // 用于流式响应的实时连接,由服务端在处理请求时挂接上来。当响应不是经由真实
    // 连接、而是直接通过 app.handle 驱动时(例如测试场景),没有底层连接可挂,
    // 此字段为 None。
    public var conn: ?ResponseConnection = None
    // 标记位:一旦某个处理器"接管"了连接以进行流式输出,就把它置为 true。此后
    // 服务端会跳过其常规的"序列化整个响应再一次性写出"步骤,把写入主动权交给
    // 处理器自己(见 stream/sse)。
    public var hijacked: Bool = false

    // 标记响应头是否已发送给客户端。对应 Express 的 res.headersSent。
    // 两种情况下会变为 true:
    //   1. 流式响应(stream/sse):StreamWriter.begin() 把状态行和响应头直接写入底层连接时。
    //   2. 普通响应:serializeResponse 将整个响应序列化写出时(由 server 在写入 socket 前设置)。
    // 错误处理中间件可用此属性判断是否还能修改响应头,若已为 true 则只能向上冒泡错误。
    public var headersSent: Bool = false

    // 独立于 MIME 类型的字符集设置,对应 Express 的 res.charset。设为非空字符串(如
    // "utf-8")后,在响应序列化前框架会自动把它拼到 Content-Type 上:若现有
    // Content-Type 已显式带 "charset=" 则保持原值不动,否则追加 "; charset=<charset>"。
    // 因此可以在任意时刻设置(包括 send/json 之后),都能影响最终发出的 Content-Type。
    public var charset: String = ""

    // 为 true 时,序列化阶段仍会保留 Content-Length 响应头(声明本应有的长度),
    // 但不实际写出响应体。用于自动处理 HEAD 请求的响应:HEAD 要求返回与 GET
    // 相同的头部、却不带正文。
    public var suppressBody: Bool = false

    /**
     * 响应级别的、带类型的数据存储区,作用域限定在单次响应内,用于在同一响应的
     * 各中间件 / 处理器之间传递数据。它对应 Express 的 `res.locals`。值类型为
     * Any,可存任意对象。
     *
     * **并发模型 — 与 [Application.locals] 同名但语义完全不同**:
     *   - `res.locals`(本字段):**按请求隔离**,与 `HttpResponse` 实例同生命周期,
     *     仅被当前请求的中间件链上下文访问。不会被多个协程同时操作,因此 **无需
     *     加锁**;
     *   - [Application.locals]:**跨请求共享**,所有 worker 协程并发读写,任何
     *     写入都需要调用方自行加锁。
     *
     * 请求间临时上下文(认证后的用户对象、解析出的资源句柄等)应该放这里,而不
     * 是 `app.locals` — 后者会跨请求泄漏并触发数据竞争。
     */
    public let locals: HashMap<String, Any> = HashMap<String, Any>()

    public init() {
        this.headers = HashMap<String, String>()
        this.headersLookup = HashMap<String, String>()
        this.setCookies = ArrayList<String>()
        // 初始 Content-Type 走访问器,触发 lookup 注册,确保后续 set("content-type", ...)
        // 不会再插一份导致大小写双发。
        this.set("Content-Type", "text/plain; charset=utf-8")
    }

    public func status(code: Int64): HttpResponse {
        // finished 后改 status 会让"状态码已改 + body 改不了"形成无意义的混乱响应。
        // 与 send/sendBytes/stream 同款警告并跳过,而非默默吞改。
        if (warnIfFinished("status")) {
            return this
        }
        this.statusCode = code
        this.statusMessage = reasonPhrase(code)
        return this
    }

    // 设置响应头(case-insensitive 去重)。`set("X-Foo", "a")` 后 `set("x-foo", "b")`
    // 视为同一头,后者覆盖前者;输出时保留**最后一次**写入提供的原始大小写。
    //
    // 注意:与 status / send 等不同,set **不**在 finished 后告警 — 因为 server 层
    // 序列化阶段 (ensureDateHeader / 自动补 Content-Length / charset) 仍需要在
    // res.finished 之后写头部。用户在 finished 后调 set 写入,header 也会出现在最终
    // 字节流(因为序列化在 finished=true 后才跑),所以不算 no-op。
    public func set(name: String, value: String): HttpResponse {
        checkHeaderSafe(name)
        checkHeaderSafe(value)
        let low = name.toAsciiLower()
        // 已存在对应大小写无关的头:先删旧 key,避免序列化时输出两份。
        match (this.headersLookup.get(low)) {
            case Some(oldKey) => this.headers.remove(oldKey)
            case None => ()
        }
        this.headersLookup[low] = name
        this.headers[name] = value
        return this
    }

    // 读回之前在本响应上设置过的某个响应头的值,case-insensitive。
    public func get(name: String): ?String {
        match (this.headersLookup.get(name.toAsciiLower())) {
            case Some(key) => return this.headers.get(key)
            case None => return None
        }
    }

    // 判断响应头是否已设置(case-insensitive)。
    public func has(name: String): Bool {
        return this.headersLookup.contains(name.toAsciiLower())
    }

    // 移除一个响应头(case-insensitive)。
    public func remove(name: String): HttpResponse {
        let low = name.toAsciiLower()
        match (this.headersLookup.get(low)) {
            case Some(oldKey) =>
                this.headers.remove(oldKey)
                this.headersLookup.remove(low)
            case None => ()
        }
        return this
    }

    // 从一个映射中一次性设置多个响应头,对应 Express 的 `res.set({...})`。
    public func set(headers: HashMap<String, String>): HttpResponse {
        for ((k, v) in headers) {
            this.set(k, v)
        }
        return this
    }

    public func contentType(value: String): HttpResponse {
        return this.set("Content-Type", value)
    }

    // 设置 Content-Type,并把诸如 "json"/"html"/"text" 之类的简写展开成完整的
    // MIME 类型,对应 Express 的 res.type()。若传入的值本身已包含 "/"(即已是
    // 完整 MIME 类型),则原样使用、不做转换。
    public func mimeType(value: String): HttpResponse {
        return this.set("Content-Type", contentTypeFor(value))
    }

    // 设置 Location 响应头(仅设置头部,并不结束响应)。与 redirect 不同:
    // redirect 会同时设状态码并标记响应完成,而本方法只改一个头、可继续链式调用。
    public func location(url: String): HttpResponse {
        return this.set("Location", url)
    }

    // 向某个响应头追加一个值:若该头已存在,则以 ", " 拼接到原值之后;若不存在,
    // 则直接以该值创建。特例:名为 Set-Cookie 的头(大小写无关)会被转交到专门的
    // setCookies 列表,以便保留多个 Cookie(headers 这种单值映射无法表达同名多值)。
    public func append(name: String, value: String): HttpResponse {
        if (name.toAsciiLower() == "set-cookie") {
            checkHeaderSafe(name)
            checkHeaderSafe(value)
            this.setCookies.add(value)
            return this
        }
        match (this.get(name)) {
            case Some(existing) => return this.set(name, "${existing}, ${value}")
            case None => return this.set(name, value)
        }
    }

    // 排入一条 Set-Cookie 响应头(加入 setCookies 列表,响应时输出)。各项属性都是
    // 可选的具名参数,按需拼接到 Cookie 串上:
    //   path     —— Path 属性,默认 "/";为空串时不输出 Path。
    //   maxAge   —— Max-Age(秒),默认 -1 表示不设置;>=0 时才输出。
    //   httpOnly —— 为 true 时附加 HttpOnly,禁止脚本读取该 Cookie。
    //   secure   —— 为 true 时附加 Secure,仅在 HTTPS 下回传。**注意**:当
    //               sameSite="None" 时,即使 secure=false 也会自动补 Secure,以满足
    //               现代浏览器对跨站 Cookie 的强制要求(Chrome 80+ / Firefox / Safari)。
    //   sameSite —— SameSite 策略(如 "Lax"/"Strict"/"None");为空串时不输出。
    //   domain   —— Domain 属性(跨子域共享 Cookie 时用);为空串时不输出。
    //   expires  —— Expires 属性(HTTP 日期字符串)。为空串时:若设了 maxAge(>=0),
    //               则据 maxAge 自动推导一个 Expires(兼容不识别 Max-Age 的旧浏览器),
    //               与 Express 行为一致。
    //   signed   —— 为 true 时对值做 HMAC 签名(形如 "<value>.<sig>"),使客户端无法
    //               篡改;需先设置 app.cookieSecret,否则抛异常。读取时用
    //               req.signedCookie(name) 验签。
    public func cookie(name: String, value: String, path!: String = "/", maxAge!: Int64 = -1, httpOnly!: Bool = false,
        secure!: Bool = false, sameSite!: String = "", domain!: String = "", expires!: String = "",
        signed!: Bool = false): HttpResponse {
        // 防 HTTP 响应分割 + 防 cookie attribute 注入:cookie 的 name 与 value 都
        // 必须严格落在 RFC 6265 cookie-octet 范围内,attributes 至少要挡 CR/LF/NUL。
        // 若 value 放任分号 / 空格 / 引号通过,攻击者就能用 `xxx; Domain=evil.com`
        // 这种形态把恶意属性塞进 Set-Cookie 头,让浏览器把 cookie 跨域投递。
        checkCookieOctet(name)
        checkCookieOctet(value)
        checkHeaderSafe(path)
        checkHeaderSafe(domain)
        checkHeaderSafe(expires)
        checkHeaderSafe(sameSite)
        let actualValue = if (signed) {
            let secret = cookieSecretOrThrow()
            "${value}.${hmacSha256Hex(secret, value)}"
        } else {
            value
        }
        // Set-Cookie 串用 StringBuilder 累积,免去逐属性 `+=` 的中间字符串拷贝
        // (次热路径:每设一个 Cookie 调一次,属性最多七八段)。
        let sb = StringBuilder()
        sb.append(name)
        sb.append("=")
        sb.append(actualValue)
        if (!path.isEmpty()) {
            sb.append("; Path=")
            sb.append(path)
        }
        if (!domain.isEmpty()) {
            sb.append("; Domain=")
            sb.append(domain)
        }
        if (maxAge >= 0) {
            sb.append("; Max-Age=")
            sb.append(maxAge.toString())
        }
        // Expires:显式传入优先;否则若设了 maxAge,则据此自动推导。
        let exp = if (!expires.isEmpty()) {
            expires
        } else if (maxAge >= 0) {
            httpDateAfter(maxAge)
        } else {
            ""
        }
        if (!exp.isEmpty()) {
            sb.append("; Expires=")
            sb.append(exp)
        }
        if (httpOnly) {
            sb.append("; HttpOnly")
        }
        // SameSite=None 必须配 Secure,否则现代浏览器(Chrome 80+ / Firefox / Safari)
        // 会直接拒绝该 Cookie。自动补 Secure 是防呆——与其让用户的跨站 Cookie 静默失效,
        // 不如代他补上。显式传 secure: true 时也只输出一次。
        let sameSiteNone = !sameSite.isEmpty() && sameSite.toAsciiLower() == "none"
        if (secure || sameSiteNone) {
            sb.append("; Secure")
        }
        if (!sameSite.isEmpty()) {
            sb.append("; SameSite=")
            sb.append(sameSite)
        }
        this.setCookies.add(sb.toString())
        return this
    }

    // 让客户端删除某个 Cookie:发送一条值为空、且 Max-Age=0 的同名 Set-Cookie,
    // 浏览器据此立即将其过期。path 需与当初设置该 Cookie 时一致(默认 "/"),
    // 否则浏览器会因路径不匹配而无法删除目标 Cookie。
    public func clearCookie(name: String, path!: String = "/"): HttpResponse {
        checkHeaderSafe(name)
        checkHeaderSafe(path)
        this.setCookies.add("${name}=; Path=${path}; Max-Age=0")
        return this
    }

    // 从磁盘读取一个文件并作为响应体发送,Content-Type 依据文件扩展名推断。
    // 行为细节:
    //   - 若路径以 "./" 开头,会先剥掉该前缀再使用。
    //   - 文件不存在时抛出异常,交由错误处理管线接手(可注册一个错误中间件把它
    //     转换成合适的响应,例如 404),而不是在此静默处理。
    //   - 文件以原始字节发送,从而保证二进制资源(图片、字体等)原样送达,
    //     不会因为经过 UTF-8 编解码往返而被破坏。
    //   - 经由 applyFileResponse 统一附带 ETag 与 Accept-Ranges,并在请求带
    //     If-None-Match / Range 时分别给出 304 / 206(详见 file_response.cj)。
    public func sendFile(path: String, root!: ?String = None): Unit {
        // 沙箱:传了 root 时,把 path 解析为 root 之内的绝对路径;含 ".." 或显式跨出
        // root 一律抛异常。建议任何「path 直接或间接来自客户端输入」的调用都显式传 root。
        // 未传 root 时:出于安全考虑,默认拒绝含 ".." 路径段的 path(防止 path 直接
        // 来自 req.params/query 时被用作路径穿越任意文件读)。需要读 root 之外文件时,
        // 显式传 root 才有可控的沙箱边界。
        let p = match (root) {
            case Some(r) => resolveWithinRoot(r, path)
            case None =>
                let stripped = if (path.startsWith("./")) {
                    path[2..path.size]
                } else {
                    path
                }
                rejectDotDotPath(stripped)
                stripped
        }
        if (!exists(p)) {
            // 抛异常前清掉用户钩子(如 staticFiles 的 setHeaders)已写的头部 —
            // 默认错误处理会把 status 改成 500,残留的 "Content-Type: image/png" / Cache-Control
            // 等可能误导客户端缓存"500 + image/png"或继续按缓存策略持有错误响应。
            this.remove("Content-Type")
            this.remove("Cache-Control")
            this.remove("Content-Length")
            this.remove("ETag")
            this.remove("Last-Modified")
            throw Exception("sendFile: file not found: ${path}")
        }
        applyFileResponse(this, File.readFrom(p), mimeFor(p), httpDateForFile(p))
    }

    // 把响应标记为「附件下载」:设置 Content-Disposition 头,浏览器收到后会弹出
    // 保存对话框而非内联显示。无参版本只声明 attachment;带文件名版本额外给出建议
    // 的保存文件名,并据其扩展名推断 Content-Type(对应 Express 的 res.attachment)。
    public func attachment(): HttpResponse {
        this.set("Content-Disposition", "attachment")
        return this
    }

    public func attachment(filename: String): HttpResponse {
        this.set("Content-Disposition", contentDispositionFor(filename))
        this.set("Content-Type", mimeFor(filename))
        return this
    }

    // 以「附件下载」的方式发送一个文件(对应 Express 的 res.download)。先写好
    // Content-Disposition(下载文件名默认取路径的 basename,也可显式指定),再交给
    // sendFile 发送文件字节——因此同样具备二进制安全、ETag 与 Range 支持。
    // 注意:Content-Type 以文件实际扩展名为准(sendFile 内设置),下载文件名只影响
    // 保存时的建议名,二者互不冲突。
    public func download(path: String, root!: ?String = None): Unit {
        download(path, basename(path), root: root)
    }

    public func download(path: String, filename: String, root!: ?String = None): Unit {
        this.set("Content-Disposition", contentDispositionFor(filename))
        sendFile(path, root: root)
    }

    // 发送一段文本响应体(纯文本或 HTML)并结束响应。
    // 不改动 Content-Type,沿用当前已设置的值(默认是 text/plain);如需指定为
    // HTML 等类型,请在调用前用 contentType/mimeType 设置好。
    public func send(text: String): Unit {
        if (warnIfFinished("send")) {
            return
        }
        this.body = text
        this.finished = true
    }

    // 发送一段原始二进制响应体并结束响应。本方法不会自动设置 Content-Type;
    // 如果类型对客户端有意义,请在调用前自行设置(例如 res.contentType("image/png"))。
    public func sendBytes(data: Array<UInt8>): Unit {
        if (warnIfFinished("sendBytes")) {
            return
        }
        this.bodyBytes = Some(data)
        this.finished = true
    }

    // 已 finished / hijacked 的响应再次调用终结方法是错误用法。打一条 stderr 警告
    // 并直接返回,不覆盖已有 body — 早先 send("a"); send("b") 会让 body 变成 "b" 而
    // 用户毫无察觉。返回 true 表示调用方应跳过后续写入。
    private func warnIfFinished(method: String): Bool {
        if (this.finished || this.hijacked) {
            eprintln("[wen] 警告: res.${method} 在响应已结束(finished/hijacked)后被再次调用,本次写入已忽略")
            return true
        }
        return false
    }

    // 以流式方式发送响应:先把状态行和响应头刷出(因此所有头部必须在调用前设好),
    // 随后在回调 `body` 运行期间,通过传入的 StreamWriter 不断推送数据块。
    // 流式响应不带 Content-Length(长度未知);当 `body` 返回时连接随之关闭。
    // 方法内部会把 hijacked 与 finished 都置为 true,以接管连接并跳过服务端的
    // 常规序列化写出流程。需要设置的头(如 Content-Type)请务必在调用前设好。
    public func stream(body: (StreamWriter) -> Unit): Unit {
        if (warnIfFinished("stream")) {
            return
        }
        this.hijacked = true
        this.finished = true
        let writer = StreamWriter(this)
        writer.begin()
        // body 抛异常时,响应头已写出 — 不能再回一个 5xx 错误响应(客户端会把两份响应
        // 拼起来解析)。这里吞掉异常,只能依赖 hijacked=true 让上层关闭连接。
        // 但运营态要看得见:stderr 打一行带 message(与 warnIfFinished 同款风格),
        // 否则"SSE 莫名断流"问题完全无线索。
        try {
            body(writer)
        } catch (e: Exception) {
            eprintln("[wen] stream/sse body 抛异常: ${e.message}")
        }
        // 无连接路径(单元测试)下,把 writer 攒下的字节一次性刷进 res.body。
        // 放在 try/catch 之后:即便回调中途抛异常,已写出的块也要落盘可见。
        writer.flushSink()
    }

    // 建立一个 Server-Sent Events(SSE,服务器推送事件)流。先设置好 SSE 所需的
    // 响应头(Content-Type 为 text/event-stream、Cache-Control 为 no-cache、
    // Connection 为 keep-alive),然后基于底层的 stream 机制,把一个 SseWriter
    // 交给回调 `body` 用于逐条推送事件。当 `body` 返回时连接关闭;此时浏览器的
    // EventSource 通常会自动发起重连。
    public func sse(body: (SseWriter) -> Unit): Unit {
        this.set("Content-Type", "text/event-stream; charset=utf-8")
        this.set("Cache-Control", "no-cache")
        this.set("Connection", "keep-alive")
        this.stream({w: StreamWriter => body(SseWriter(w))})
    }

    // 发送一个 JSON 响应体(传入的是已经序列化好的 JSON 字符串)并结束响应。
    // 会把 Content-Type 设为 application/json; charset=utf-8。
    public func json(payload: String): Unit {
        this.set("Content-Type", "application/json; charset=utf-8")
        this.body = payload
        this.finished = true
    }

    // 将一个 JsonValue 序列化为字符串,并按 JSON 响应体发送(转调上面的 json(String))。
    public func json(value: JsonValue): Unit {
        json(value.toJsonString())
    }

    // 便捷重载:直接发送用 JsonObj 构建器搭建出来的 JSON 对象(序列化后转调 json(String))。
    public func json(value: JsonObj): Unit {
        json(value.toJsonString())
    }

    // 以当前已有的状态码和响应体结束响应,不再追加任何新内容。
    // 适用于状态码 / 头部 / 主体都已设置妥当,只需标记"完成"的场景。
    public func end(): Unit {
        this.finished = true
    }

    // 仅发送一个状态码:把响应体设为该状态码对应的标准原因短语(reason phrase),
    // 例如 404 -> "Not Found",并结束响应。对应 Express 的 res.sendStatus()。
    public func sendStatus(code: Int64): Unit {
        status(code)
        this.body = this.statusMessage
        this.finished = true
    }

    // 设置一个重定向响应:状态码置为 302,写入 Location 头指向目标地址,清空响应体,
    // 并结束响应。
    public func redirect(location: String): Unit {
        status(302)
        this.set("Location", location)
        this.body = ""
        this.finished = true
    }

    // 指定状态码的重定向(如 301 永久重定向)。
    public func redirect(status: Int64, location: String): Unit {
        this.status(status)
        this.set("Location", location)
        this.body = ""
        this.finished = true
    }

    // 往 Vary 头追加一个字段(已存在则不重复),对应 Express 的 res.vary。
    // RFC 7231 §7.1.4:Vary 值为逗号分隔的字段名列表,字段名大小写不敏感。每次追加
    // 时统一 trim 所有片段、去重、用单一 ", " 分隔符拼接,避免 "field1, field2 , field3"
    // 这种不规范形式。输出保留原始大小写。
    public func vary(field: String): HttpResponse {
        let want = field.toAsciiLower()
        match (this.get("Vary")) {
            case Some(v) =>
                // 拆已有值,trim + 大小写无关去重——不仅挡住与新字段重复,也收敛已有值彼此
                // 之间的重复(如直接 `set("Vary", "Accept, ACCEPT")` 进来的形态会被合并成
                // 首次出现的那个)。保留原始大小写:HTTP 字段名大小写不敏感,但输出不强行改写
                // 用户写法。因可能收敛已有重复,这里总是重写 Vary。
                let parts = ArrayList<String>() // 去重后,保留首现的原始大小写
                let lowers = ArrayList<String>() // 对应小写,供比较
                var seen = false
                for (part in v.split(",")) {
                    let trimmed = part.trimAscii()
                    if (trimmed.isEmpty()) {
                        continue
                    }
                    let lower = trimmed.toAsciiLower()
                    if (lower == want) {
                        seen = true
                    }
                    if (!lowers.contains(lower)) {
                        parts.add(trimmed)
                        lowers.add(lower)
                    }
                }
                if (!seen) {
                    parts.add(field) // 新字段用传入的原样
                }
                // 拼接:统一 ", " 分隔。
                var joined = ""
                for (i in 0..parts.size) {
                    if (i > 0) {
                        joined += ", "
                    }
                    joined += parts[i]
                }
                this.set("Vary", joined)
            case None => this.set("Vary", field)
        }
        return this
    }

    // 渲染一个视图模板并作为 HTML 响应发送(对应 Express 的 res.render)。视图定位、
    // 引擎选择等逻辑都委托给所属 Application.renderView;这里只负责设好 Content-Type、
    // 写入渲染结果并结束响应。data 为传给模板的数据(用 JsonValue 表示)。
    // 需要经由 app.handle 派发(从而 res 关联到请求与应用);否则抛异常。
    public func render(name: String, data: JsonValue): Unit {
        let app = resolveApp()
        this.set("Content-Type", "text/html; charset=utf-8")
        this.body = app.renderView(name, data)
        this.finished = true
    }

    // 便捷重载:用 JsonObj 构建器传数据。
    public func render(name: String, data: JsonObj): Unit {
        render(name, data.build())
    }

    // 便捷重载:不传数据(模板中的占位符都将解析为空串)。
    public func render(name: String): Unit {
        render(name, JsonObj().build())
    }

    // 内容协商分发(对应 Express 的 res.format)。传入若干「类型 -> 回调」条目,框架
    // 依据请求的 Accept 头从中挑出客户端最偏好、且服务端能提供的类型,设好对应的
    // Content-Type 后调用其回调来产生响应;并自动加上 Vary: Accept(告诉缓存该响应
    // 随 Accept 而变)。类型用简写(如 "html"/"json")或完整 MIME 均可。
    // 特殊条目 "default" 作为兜底:当没有任何类型可接受时调用它;若也没有 default,
    // 则回 406 Not Acceptable。
    // 用法示例:
    //   res.format([
    //       ("html", { => res.send("<h1>Hi</h1>") }),
    //       ("json", { => res.json("{\"hi\":true}") })
    //   ])
    public func format(handlers: Array<(String, () -> Unit)>): Unit {
        // 收集可供选择的类型(排除特殊的 "default")。
        let offered = ArrayList<String>()
        for ((t, _) in handlers) {
            if (t != "default") {
                offered.add(t)
            }
        }
        // 该响应随 Accept 头而变,补上 Vary 以利缓存正确性。
        match (this.get("Vary")) {
            case Some(v) =>
                // 大小写不敏感检查是否已含 Accept。
                var hasAccept = false
                for (part in v.split(",")) {
                    if (part.trimAscii().toAsciiLower() == "accept") {
                        hasAccept = true
                        break
                    }
                }
                if (!hasAccept) {
                    // 规范化拼接:trim v + ", Accept"
                    this.set("Vary", "${v.trimAscii()}, Accept")
                }
            case None => this.set("Vary", "Accept")
        }
        var chosen: ?String = None
        match (this.req) {
            case Some(r) => chosen = r.accepts(offered.toArray())
            case None =>
                if (offered.size > 0) {
                    chosen = Some(offered[0])
                }
        }
        match (chosen) {
            case Some(t) =>
                this.set("Content-Type", contentTypeFor(t))
                callFormat(handlers, t)
            case None =>
                if (hasFormat(handlers, "default")) {
                    callFormat(handlers, "default")
                } else {
                    this.status(406).send("Not Acceptable")
                }
        }
    }

    private func callFormat(handlers: Array<(String, () -> Unit)>, key: String): Unit {
        for ((t, fn) in handlers) {
            if (t == key) {
                fn()
                return
            }
        }
    }

    private func hasFormat(handlers: Array<(String, () -> Unit)>, key: String): Bool {
        for ((t, _) in handlers) {
            if (t == key) {
                return true
            }
        }
        return false
    }

    // 取回本响应所属的 Application(经 req.app)。渲染依赖应用上的视图设置与引擎表,
    // 因此必须是经 app.handle 派发的响应;直接构造的 res 没有该关联,抛异常提示。
    private func resolveApp(): Application {
        match (this.req) {
            case Some(r) => match (r.app) {
                case Some(a) => return a
                case None => throw Exception("render: 响应未关联 Application")
            }
            case None => throw Exception("render: 响应未关联请求/Application")
        }
    }

    // 取签名 Cookie 用的密钥(app.cookieSecret);未设置则抛异常。同时,首次发现密钥
    // 强度不足(< 32 字节)时打一条 stderr 警告(由 warnIfWeakCookieSecret 保证一进程一次)。
    private func cookieSecretOrThrow(): String {
        let app = resolveApp()
        warnIfWeakCookieSecret(Some(app), app.cookieSecret)
        if (app.cookieSecret.isEmpty()) {
            throw Exception("签名 Cookie 需要先设置 app.cookieSecret")
        }
        return app.cookieSecret
    }
}

// 拦截显式含 ".." 路径段的相对路径:即便目标文件存在,也拒绝读取,避免 sendFile
// 在未传 root 时被攻击者用作任意文件读漏洞。检查的是「路径段」,因此 "a..b"(段内
// 含点点)是合法的,只有独立段 ".." 才被禁。同时把反斜杠归一为正斜杠以兼容 Windows。
func rejectDotDotPath(p: String): Unit {
    let normalized = p.replace("\\", "/")
    for (seg in normalized.split("/")) {
        if (seg == "..") {
            throw Exception(
                "sendFile: 路径含 '..' 段被拒绝;若需读取上级目录文件,请显式传 root 参数:sendFile(path, root: ...)")
        }
    }
}

// 按 RFC 6266 / 5987 构造 Content-Disposition 头值。同时输出两份文件名:
//   - filename="<safe>"   :传统参数,把非 ASCII / 引号 / 控制字符替换为 "_"(回退兼容)
//   - filename*=UTF-8''<percent-encoded>  :RFC 5987 编码,保留原始 UTF-8 字符
// 现代浏览器(Chrome/Firefox/Safari)在两者都存在时优先用 filename*,从而既能
// 提示原始文件名,又彻底杜绝 `"`/CR/LF 等字符破坏头部结构(攻击者把恶意文件名
// 塞进 download 参数注入额外响应头/Set-Cookie 的经典手法)。
func contentDispositionFor(filename: String): String {
    let safe = asciiFallbackFilename(filename)
    let encoded = percentEncodeFilename(filename)
    return "attachment; filename=\"${safe}\"; filename*=UTF-8''${encoded}"
}

// 把文件名替换成 ASCII 安全的回退版本:任何非 ASCII / 控制字符 / 引号 / 反斜杠 /
// 分号 等可能破坏头部结构的字符,统一替换为下划线。
func asciiFallbackFilename(s: String): String {
    let bytes = s.toArray()
    let out = ArrayList<UInt8>()
    for (b in bytes) {
        if (b < UInt8(0x20) || b == UInt8(0x7f) || b > UInt8(0x7e) || b == UInt8(34) || b == UInt8(92) || b == UInt8(13) ||
            b == UInt8(10) || b == UInt8(0) || b == UInt8(59)) {
            // 不可打印 ASCII / 高位字节 / 双引号 / 反斜杠 / CR / LF / NUL / 分号
            out.add(UInt8(95)) // '_'
        } else {
            out.add(b)
        }
    }
    return String.fromUtf8(out.toArray())
}

// RFC 5987 percent-encoding:把字符串的 UTF-8 字节编码,unreserved 字符
// (A-Z, a-z, 0-9, - _ . ~)原样输出,其余以 %XX 表示。
func percentEncodeFilename(s: String): String {
    let hex = "0123456789ABCDEF"
    let bytes = s.toArray()
    var out = ""
    for (b in bytes) {
        let unreserved = (b >= UInt8(0x41) && b <= UInt8(0x5a)) || // A-Z
            (b >= UInt8(0x61) && b <= UInt8(0x7a)) || // a-z
            (b >= UInt8(0x30) &&
            b <= UInt8(0x39)) || // 0-9
                b == UInt8(0x2d) || b == UInt8(0x5f) || b == UInt8(0x2e) || b == UInt8(0x7e) // - _ . ~
        if (unreserved) {
            let arr = Array<UInt8>(1, repeat: b)
            out += String.fromUtf8(arr)
        } else {
            let hi = Int64((b >> 4) & UInt8(0x0F))
            let lo = Int64(b & UInt8(0x0F))
            out += "%"
            out += hex[hi..(hi + 1)]
            out += hex[lo..(lo + 1)]
        }
    }
    return out
}

// 防 HTTP 响应分割(Response Splitting):响应头的「名」与「值」均不允许含 CR / LF / NUL
// 等可能破坏头部帧结构的字节。一旦发现立即抛异常,由错误处理流水线兜底(默认回 500)——
// 静默剥离同样可破坏语义,直接拒绝最稳妥。所有面向用户的写头接口(set/cookie/redirect/
// location/append/vary 等)进入时调用;server.cj 的 buildHeadBlock 在序列化最终一刻
// 再校验一次,使任何绕过 API 直接写 `res.headers["..."] = ...` 的途径也无法成功。
func checkHeaderSafe(v: String): Unit {
    for (b in v.toArray()) {
        if (b == UInt8(13) || b == UInt8(10) || b == UInt8(0)) {
            throw Exception("响应头值含非法控制字符(CR/LF/NUL),拒绝写入以防 HTTP 响应分割")
        }
    }
}

// 防 cookie attribute 注入:cookie 的 name 与 value 都必须严格落在 RFC 6265 §4.1.1
// cookie-octet 范围内 — 0x21、0x23-0x2B、0x2D-0x3A、0x3C-0x5B、0x5D-0x7E。
// 排除字符:CTL(<0x21)、SP(0x20)、DQUOTE(0x22)、","(0x2C)、";"(0x3B)、
// "\\"(0x5C)、DEL(0x7F)。一旦放任分号 / 空格 / 引号通过,就出现了 cookie attribute
// 注入面 — 业务把外部串当 value(常见写法)会让攻击者拼出
// `xxx; Domain=evil.com` 这类形态,浏览器解析后把 cookie 跨域投递。比 percent-encode
// 更稳的做法是直接抛,让调用方先把外部输入清洗或显式编码。
func checkCookieOctet(v: String): Unit {
    for (b in v.toArray()) {
        let bad = b < UInt8(0x21) || b == UInt8(0x22) || b == UInt8(0x2C) || b == UInt8(0x3B)
            || b == UInt8(0x5C) || b > UInt8(0x7E)
        if (bad) {
            throw Exception("cookie 字段含 RFC 6265 cookie-octet 范围外字符(0x${b}),拒绝写入以防 attribute 注入")
        }
    }
}

/**
 * 把内容类型的简写(如 "json"、"html"、"text" 等)展开为完整的 MIME 类型。
 *
 * 规则:
 *
 * - 若传入值本身已含 "/"(已是完整 MIME),原样返回,不做转换。
 * - 否则按小写匹配已知简写,返回对应的完整类型(文本类还带 `charset=utf-8`)。
 * - 无法识别的简写一律回退为 `application/octet-stream`(通用二进制流)。
 *
 * 该函数同时被请求侧(`isType` / `accepts` 的类型比较)和响应侧(`mimeType` 设头)
 * 复用。
 */
public func contentTypeFor(value: String): String {
    if (value.contains("/")) {
        return value
    }
    let n = value.toAsciiLower()
    // 用户经 app.mime / registerMimeType 注册的映射优先(使 res.type("webp") 等在
    // 注册后与 mimeFor 一致地命中);未注册时落到下面的内置简写表,行为不变。
    match (lookupUserMime(n)) {
        case Some(t) => return t
        case None => ()
    }
    if (n == "json") {
        return "application/json; charset=utf-8"
    } else if (n == "html") {
        return "text/html; charset=utf-8"
    } else if (n == "text" || n == "txt") {
        return "text/plain; charset=utf-8"
    } else if (n == "css") {
        return "text/css"
    } else if (n == "js") {
        return "application/javascript"
    } else if (n == "xml") {
        return "application/xml"
    } else {
        return "application/octet-stream"
    }
}
