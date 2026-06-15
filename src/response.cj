package wen

import std.collection.*
import std.fs.*

/*
 * 一个待发出的 HTTP 响应对象。
 * 工作方式:各方法只是不断在对象上累积状态(状态码、响应头、响应体等),
 * 真正把一个"已完成"的响应序列化并写入 socket 的工作由服务端统一完成。
 * 大量设置类方法都返回 this,从而支持链式调用,风格对应 Express 的
 * `res.status(201).set(...).send(...)`。
 */
public class HttpResponse {
    public var statusCode: Int64 = 200
    public var statusMessage: String = "OK"
    public let headers: HashMap<String, String>
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

    // 响应级别的、带类型的数据存储区,作用域限定在单次响应内,用于在同一响应的
    // 各中间件 / 处理器之间传递数据。它对应 Express 的 res.locals。值类型为 Any,
    // 可存任意对象。
    public let locals: HashMap<String, Any> = HashMap<String, Any>()

    public init() {
        this.headers = HashMap<String, String>()
        this.headers["Content-Type"] = "text/plain; charset=utf-8"
        this.setCookies = ArrayList<String>()
    }

    public func status(code: Int64): HttpResponse {
        this.statusCode = code
        this.statusMessage = reasonPhrase(code)
        return this
    }

    public func set(name: String, value: String): HttpResponse {
        this.headers[name] = value
        return this
    }

    // 读回之前在本响应上设置过的某个响应头的值;不存在则返回 None。
    // 注意:这里按原样的键查找(与请求侧大小写无关的查找不同)。
    public func get(name: String): ?String {
        return this.headers.get(name)
    }

    // 从一个映射中一次性设置多个响应头,对应 Express 的 `res.set({...})`。
    // 逐项写入 headers(同名键会被覆盖),并返回 `this` 以支持链式调用。
    public func set(headers: HashMap<String, String>): HttpResponse {
        for ((k, v) in headers) {
            this.headers[k] = v
        }
        return this
    }

    public func contentType(value: String): HttpResponse {
        this.headers["Content-Type"] = value
        return this
    }

    // 设置 Content-Type,并把诸如 "json"/"html"/"text" 之类的简写展开成完整的
    // MIME 类型,对应 Express 的 res.type()。若传入的值本身已包含 "/"(即已是
    // 完整 MIME 类型),则原样使用、不做转换。
    public func mimeType(value: String): HttpResponse {
        this.headers["Content-Type"] = contentTypeFor(value)
        return this
    }

    // 设置 Location 响应头(仅设置头部,并不结束响应)。与 redirect 不同:
    // redirect 会同时设状态码并标记响应完成,而本方法只改一个头、可继续链式调用。
    public func location(url: String): HttpResponse {
        this.headers["Location"] = url
        return this
    }

    // 向某个响应头追加一个值:若该头已存在,则以 ", " 拼接到原值之后;若不存在,
    // 则直接以该值创建。特例:名为 Set-Cookie 的头(大小写无关)会被转交到专门的
    // setCookies 列表,以便保留多个 Cookie(headers 这种单值映射无法表达同名多值)。
    public func append(name: String, value: String): HttpResponse {
        if (name.toAsciiLower() == "set-cookie") {
            this.setCookies.add(value)
            return this
        }
        match (this.headers.get(name)) {
            case Some(existing) => this.headers[name] = "${existing}, ${value}"
            case None => this.headers[name] = value
        }
        return this
    }

    // 排入一条 Set-Cookie 响应头(加入 setCookies 列表,响应时输出)。各项属性都是
    // 可选的具名参数,按需拼接到 Cookie 串上:
    //   path     —— Path 属性,默认 "/";为空串时不输出 Path。
    //   maxAge   —— Max-Age(秒),默认 -1 表示不设置;>=0 时才输出。
    //   httpOnly —— 为 true 时附加 HttpOnly,禁止脚本读取该 Cookie。
    //   secure   —— 为 true 时附加 Secure,仅在 HTTPS 下回传。
    //   sameSite —— SameSite 策略(如 "Lax"/"Strict"/"None");为空串时不输出。
    //   domain   —— Domain 属性(跨子域共享 Cookie 时用);为空串时不输出。
    //   expires  —— Expires 属性(HTTP 日期字符串)。为空串时:若设了 maxAge(>=0),
    //               则据 maxAge 自动推导一个 Expires(兼容不识别 Max-Age 的旧浏览器),
    //               与 Express 行为一致。
    //   signed   —— 为 true 时对值做 HMAC 签名(形如 "<value>.<sig>"),使客户端无法
    //               篡改;需先设置 app.cookieSecret,否则抛异常。读取时用
    //               req.signedCookie(name) 验签。
    public func cookie(name: String, value: String, path!: String = "/", maxAge!: Int64 = -1,
                       httpOnly!: Bool = false, secure!: Bool = false, sameSite!: String = "",
                       domain!: String = "", expires!: String = "", signed!: Bool = false): HttpResponse {
        let actualValue = if (signed) {
            let secret = cookieSecretOrThrow()
            "${value}.${hmacSha256Hex(secret, value)}"
        } else {
            value
        }
        var c = "${name}=${actualValue}"
        if (!path.isEmpty()) {
            c += "; Path=${path}"
        }
        if (!domain.isEmpty()) {
            c += "; Domain=${domain}"
        }
        if (maxAge >= 0) {
            c += "; Max-Age=${maxAge}"
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
            c += "; Expires=${exp}"
        }
        if (httpOnly) {
            c += "; HttpOnly"
        }
        if (secure) {
            c += "; Secure"
        }
        if (!sameSite.isEmpty()) {
            c += "; SameSite=${sameSite}"
        }
        this.setCookies.add(c)
        return this
    }

    // 让客户端删除某个 Cookie:发送一条值为空、且 Max-Age=0 的同名 Set-Cookie,
    // 浏览器据此立即将其过期。path 需与当初设置该 Cookie 时一致(默认 "/"),
    // 否则浏览器会因路径不匹配而无法删除目标 Cookie。
    public func clearCookie(name: String, path!: String = "/"): HttpResponse {
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
    public func sendFile(path: String): Unit {
        let p = if (path.startsWith("./")) {
            path[2..path.size]
        } else {
            path
        }
        if (!exists(p)) {
            throw Exception("sendFile: file not found: ${path}")
        }
        applyFileResponse(this, File.readFrom(p), mimeFor(p), httpDateForFile(p))
    }

    // 把响应标记为「附件下载」:设置 Content-Disposition 头,浏览器收到后会弹出
    // 保存对话框而非内联显示。无参版本只声明 attachment;带文件名版本额外给出建议
    // 的保存文件名,并据其扩展名推断 Content-Type(对应 Express 的 res.attachment)。
    public func attachment(): HttpResponse {
        this.headers["Content-Disposition"] = "attachment"
        return this
    }

    public func attachment(filename: String): HttpResponse {
        this.headers["Content-Disposition"] = "attachment; filename=\"${filename}\""
        this.headers["Content-Type"] = mimeFor(filename)
        return this
    }

    // 以「附件下载」的方式发送一个文件(对应 Express 的 res.download)。先写好
    // Content-Disposition(下载文件名默认取路径的 basename,也可显式指定),再交给
    // sendFile 发送文件字节——因此同样具备二进制安全、ETag 与 Range 支持。
    // 注意:Content-Type 以文件实际扩展名为准(sendFile 内设置),下载文件名只影响
    // 保存时的建议名,二者互不冲突。
    public func download(path: String): Unit {
        download(path, basename(path))
    }

    public func download(path: String, filename: String): Unit {
        this.headers["Content-Disposition"] = "attachment; filename=\"${filename}\""
        sendFile(path)
    }

    // 发送一段文本响应体(纯文本或 HTML)并结束响应。
    // 不改动 Content-Type,沿用当前已设置的值(默认是 text/plain);如需指定为
    // HTML 等类型,请在调用前用 contentType/mimeType 设置好。
    public func send(text: String): Unit {
        this.body = text
        this.finished = true
    }

    // 发送一段原始二进制响应体并结束响应。本方法不会自动设置 Content-Type;
    // 如果类型对客户端有意义,请在调用前自行设置(例如 res.contentType("image/png"))。
    public func sendBytes(data: Array<UInt8>): Unit {
        this.bodyBytes = Some(data)
        this.finished = true
    }

    // 以流式方式发送响应:先把状态行和响应头刷出(因此所有头部必须在调用前设好),
    // 随后在回调 `body` 运行期间,通过传入的 StreamWriter 不断推送数据块。
    // 流式响应不带 Content-Length(长度未知);当 `body` 返回时连接随之关闭。
    // 方法内部会把 hijacked 与 finished 都置为 true,以接管连接并跳过服务端的
    // 常规序列化写出流程。需要设置的头(如 Content-Type)请务必在调用前设好。
    public func stream(body: (StreamWriter) -> Unit): Unit {
        this.hijacked = true
        this.finished = true
        let writer = StreamWriter(this)
        writer.begin()
        body(writer)
    }

    // 建立一个 Server-Sent Events(SSE,服务器推送事件)流。先设置好 SSE 所需的
    // 响应头(Content-Type 为 text/event-stream、Cache-Control 为 no-cache、
    // Connection 为 keep-alive),然后基于底层的 stream 机制,把一个 SseWriter
    // 交给回调 `body` 用于逐条推送事件。当 `body` 返回时连接关闭;此时浏览器的
    // EventSource 通常会自动发起重连。
    public func sse(body: (SseWriter) -> Unit): Unit {
        this.headers["Content-Type"] = "text/event-stream; charset=utf-8"
        this.headers["Cache-Control"] = "no-cache"
        this.headers["Connection"] = "keep-alive"
        this.stream({ w: StreamWriter => body(SseWriter(w)) })
    }

    // 发送一个 JSON 响应体(传入的是已经序列化好的 JSON 字符串)并结束响应。
    // 会把 Content-Type 设为 application/json; charset=utf-8。
    public func json(payload: String): Unit {
        this.headers["Content-Type"] = "application/json; charset=utf-8"
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
        this.headers["Location"] = location
        this.body = ""
        this.finished = true
    }

    // 指定状态码的重定向(如 301 永久重定向)。
    public func redirect(status: Int64, location: String): Unit {
        this.status(status)
        this.headers["Location"] = location
        this.body = ""
        this.finished = true
    }

    // 往 Vary 头追加一个字段(已存在则不重复),对应 Express 的 res.vary。
    public func vary(field: String): HttpResponse {
        match (this.headers.get("Vary")) {
            case Some(v) =>
                var present = false
                for (part in v.split(",")) {
                    if (part.trimAscii().toAsciiLower() == field.toAsciiLower()) {
                        present = true
                    }
                }
                if (!present) {
                    this.headers["Vary"] = "${v}, ${field}"
                }
            case None => this.headers["Vary"] = field
        }
        return this
    }

    // 渲染一个视图模板并作为 HTML 响应发送(对应 Express 的 res.render)。视图定位、
    // 引擎选择等逻辑都委托给所属 Application.renderView;这里只负责设好 Content-Type、
    // 写入渲染结果并结束响应。data 为传给模板的数据(用 JsonValue 表示)。
    // 需要经由 app.handle 派发(从而 res 关联到请求与应用);否则抛异常。
    public func render(name: String, data: JsonValue): Unit {
        let app = resolveApp()
        this.headers["Content-Type"] = "text/html; charset=utf-8"
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
        match (this.headers.get("Vary")) {
            case Some(v) => if (!v.contains("Accept")) { this.headers["Vary"] = "${v}, Accept" }
            case None => this.headers["Vary"] = "Accept"
        }
        var chosen: ?String = None
        match (this.req) {
            case Some(r) => chosen = r.accepts(offered.toArray())
            case None => if (offered.size > 0) { chosen = Some(offered[0]) }
        }
        match (chosen) {
            case Some(t) =>
                this.headers["Content-Type"] = contentTypeFor(t)
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
            case Some(r) =>
                match (r.app) {
                    case Some(a) => return a
                    case None => throw Exception("render: 响应未关联 Application")
                }
            case None => throw Exception("render: 响应未关联请求/Application")
        }
    }

    // 取签名 Cookie 用的密钥(app.cookieSecret);未设置则抛异常。
    private func cookieSecretOrThrow(): String {
        let app = resolveApp()
        if (app.cookieSecret.isEmpty()) {
            throw Exception("签名 Cookie 需要先设置 app.cookieSecret")
        }
        return app.cookieSecret
    }
}

// 把内容类型的简写(如 "json"、"html"、"text" 等)展开为完整的 MIME 类型。
// 规则:
//   - 若传入值本身已含 "/"(已是完整 MIME),原样返回,不做转换。
//   - 否则按小写匹配已知简写,返回对应的完整类型(文本类还带 charset=utf-8)。
//   - 无法识别的简写一律回退为 application/octet-stream(通用二进制流)。
// 该函数同时被请求侧(isType/accepts 的类型比较)和响应侧(mimeType 设头)复用。
public func contentTypeFor(value: String): String {
    if (value.contains("/")) {
        return value
    }
    let n = value.toAsciiLower()
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
