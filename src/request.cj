package wen

import std.collection.*

/*
 * 一个进入服务端的 HTTP 请求对象。
 * 注意:请求头(header)的键统一以小写形式存储,这样按名字查找时就与大小写无关,
 * 符合 HTTP 规范中"字段名大小写不敏感"的要求(例如 "Content-Type" 与
 * "content-type" 视为同一个头)。配套的 header()/get() 方法在查询前也会把传入的
 * 名字转成小写,从而保证写入和读取两端一致。
 */
public class HttpRequest {
    public var method: String
    public var url: String          // 原始请求目标(request target),包含查询串,例如 "/a?x=1"
    public var path: String         // 仅路径部分(已剥离查询串),例如 "/a"
    public var httpVersion: String

    public let headers: HashMap<String, String>
    public let query: HashMap<String, String>
    public var params: HashMap<String, String>
    public var body: String

    // 每个请求独享的、自由形式的"字符串"附属数据存储区,供中间件向下游
    // (后续中间件 / 处理器)传递字符串数据。它对应 Express 中直接往 `req`
    // 对象上挂自定义属性的做法。这里只存字符串;若要传递任意类型的对象,
    // 请改用下面的 locals。
    public let attributes: HashMap<String, String>

    // 每个请求独享的"带类型"对象存储区:中间件可以在这里暂存任意类型的对象
    // (例如解析好的请求体、已认证的用户、数据库连接句柄等),供下游处理器取用。
    // 值类型是 Any,因此读取时需要用 `local(key)` 取出,再用 `as` 向下转型回
    // 具体类型。与 attributes 的区别在于:attributes 只能存字符串,locals 可存
    // 任意对象。
    public let locals: HashMap<String, Any>

    // 解析后的请求 Cookie 键值对。该字段由 cookieParser 中间件负责填充;
    // 如果没有启用 cookieParser,这个表会一直为空。
    public let cookies: HashMap<String, String>

    // 请求体的原始字节。服务端会原样保留这份字节数据,以确保二进制负载
    // (例如文件上传、被代理转发的内容等)不会在编码转换中被破坏。
    // 上面的 `body` 字段则是同一份数据按 UTF-8 解码后的字符串视图,适合处理
    // 文本请求体;需要逐字节处理二进制时应使用 bodyBytes。
    public var bodyBytes: Array<UInt8>

    // 解析后的 JSON 请求体。仅当请求携带格式正确的 application/json 请求体、
    // 且启用了 jsonParser 中间件时,该字段才会被填充;否则保持为 None。
    // 通过 `json()` 方法读取它。
    public var jsonBody: ?JsonValue = None

    // 对端(客户端)的远程地址,由服务端在收到连接时填入。
    // 当请求不是经由真实网络连接、而是直接通过 app.handle 派发时(例如在单元
    // 测试中手工构造请求),没有底层连接可取地址,此字段会是空字符串。
    public var ip: String = ""

    // 拥有(派发)该请求的应用实例。在请求被派发处理时由框架设置,使得中间件
    // 能在请求处理期间访问到应用级别的配置项。它对应 Express 中的 `req.app`。
    // 直接构造请求(未经应用派发)时为 None,此时 setting() 会返回 None。
    public var app: ?Application = None

    public init(method: String, url: String) {
        this.method = method
        this.url = url
        this.path = url
        this.httpVersion = "HTTP/1.1"
        this.headers = HashMap<String, String>()
        this.query = HashMap<String, String>()
        this.params = HashMap<String, String>()
        this.body = ""
        this.attributes = HashMap<String, String>()
        this.locals = HashMap<String, Any>()
        this.cookies = HashMap<String, String>()
        this.bodyBytes = Array<UInt8>()
    }

    // 按名字查找请求头,大小写不敏感。
    // 实现上先把传入名字转为小写,再到以小写键存储的 headers 中查找,从而与
    // HTTP 规范"字段名大小写无关"一致。未命中时返回 None。
    public func header(name: String): ?String {
        return this.headers.get(name.toAsciiLower())
    }

    // `header` 的别名,沿用 Express 中 `req.get(name)` 的命名习惯,行为完全相同。
    public func get(name: String): ?String {
        return header(name)
    }

    // 取一个被路由捕获的路径参数。例如路由模式 `/users/:id` 匹配后,
    // 用 param("id") 即可取到 URL 中对应位置的值。不存在该参数时返回 None。
    public func param(name: String): ?String {
        return this.params.get(name)
    }

    // 取一个查询串(query string)参数的值。例如 URL 带 `?page=2` 时,
    // queryParam("page") 返回 "2"。不存在该参数时返回 None。
    public func queryParam(name: String): ?String {
        return this.query.get(name)
    }

    public func setAttribute(key: String, value: String): Unit {
        this.attributes[key] = value
    }

    public func attribute(key: String): ?String {
        return this.attributes.get(key)
    }

    // 向 locals 存储区暂存一个任意类型的值,供下游处理器取用。
    // 与 setAttribute 不同,这里接受任意类型(Any),而非仅限字符串。
    public func setLocal(key: String, value: Any): Unit {
        this.locals[key] = value
    }

    // 取回上游中间件暂存在 locals 中的带类型值。返回类型是 ?Any,因此通常需要
    // 用 `as` 向下转型回具体类型,例如 `(req.local("user") ?? ...) as User`。
    // 键不存在时返回 None。
    public func local(key: String): ?Any {
        return this.locals.get(key)
    }

    // 取一个已解析的 Cookie 值。该功能依赖 cookieParser 中间件先行解析;
    // 若未启用该中间件,或不存在同名 Cookie,则返回 None。
    public func cookie(name: String): ?String {
        return this.cookies.get(name)
    }

    // 返回已解析的 JSON 请求体。仅当 jsonParser 中间件已运行、且请求体是格式
    // 正确的 application/json 时才有值,否则为 None。拿到 JsonValue 后,可用
    // get/at/asString/asInt 等方法在其中逐层导航取值。
    public func json(): ?JsonValue {
        return this.jsonBody
    }

    // 在请求处理期间读取一项应用级配置。前提是该请求已知其所属应用(app 不为
    // None);若 app 为 None(例如未经应用派发的请求),直接返回 None。
    public func setting(key: String): ?String {
        match (this.app) {
            case Some(a) => return a.setting(key)
            case None => return None
        }
    }

    // 从 Host 请求头中提取主机名,并去掉其中可能附带的端口号,对应 Express 的
    // req.hostname。特别处理了用方括号包裹的 IPv6 字面量(例如 "[::1]:8080"):
    // 此时主机名是方括号连同其中的地址(即 "[::1]"),不能简单地按第一个冒号
    // 切分,否则会把 IPv6 地址截断。没有 Host 头、或切分后主机名为空时返回 None。
    public func hostname(): ?String {
        // 信任代理时优先采用 X-Forwarded-Host(取逗号分隔的第一个值,即最初客户端
        // 请求的主机名),否则使用 Host 头。
        let raw = if (trustProxy()) {
            match (this.header("x-forwarded-host")) {
                case Some(v) =>
                    let (first, _) = splitOnce(v, ",")
                    Some(first.trimAscii())
                case None => this.header("host")
            }
        } else {
            this.header("host")
        }
        match (raw) {
            case Some(h) =>
                if (h.startsWith("[")) {
                    match (h.indexOf("]")) {
                        case Some(i) => return Some(h[0..(i + 1)])
                        case None => return Some(h)
                    }
                }
                let (host, _) = splitOnce(h, ":")
                if (host.isEmpty()) {
                    return None
                }
                return Some(host)
            case None => return None
        }
    }

    // 判断本次请求体的 Content-Type 是否与 `t` 匹配。`t` 既可以是简写
    // (例如 "json"),也可以是完整的 MIME 类型。比较时会先用 contentTypeFor 把
    // 简写展开成完整类型,再剥掉其中的参数部分(分号后的内容,如 charset),
    // 然后做大小写无关的子串包含判断。请求没有 Content-Type 头时返回 false。
    // (之所以叫 isType 而不是 is,是因为 `is` 是仓颉的关键字;Express 中对应
    // 的方法名为 `req.is`。)
    public func isType(t: String): Bool {
        let ct = match (this.header("content-type")) {
            case Some(v) => v.toAsciiLower()
            case None => return false
        }
        let (wantMain, _) = splitOnce(contentTypeFor(t).toAsciiLower(), ";")
        return ct.contains(wantMain.trimAscii())
    }

    // 判断客户端的 Accept 请求头是否接受类型 `t`(`t` 可为简写或完整 MIME 类型)。
    // 与 Express 一致:当 Accept 头缺失、为空、或包含通配 `*/*` 时,视为接受任何
    // 类型,直接返回 true。否则把 `t` 展开成完整 MIME、剥掉参数部分,再在 Accept
    // 头中做大小写无关的子串包含判断。
    public func accepts(t: String): Bool {
        let accept = match (this.header("accept")) {
            case Some(v) => v.toAsciiLower()
            case None => return true
        }
        if (accept.isEmpty() || accept.contains("*/*")) {
            return true
        }
        let (wantMain, _) = splitOnce(contentTypeFor(t).toAsciiLower(), ";")
        return accept.contains(wantMain.trimAscii())
    }

    // 当前请求所属应用是否开启了「信任代理」。它决定下面这些方法是否采信
    // X-Forwarded-* 头。未关联应用(app 为 None)时一律返回 false。
    func trustProxy(): Bool {
        match (this.app) {
            case Some(a) => return a.trustProxy
            case None => return false
        }
    }

    // 请求所用的协议:"http" 或 "https"。Wen 自身直连无 TLS,默认返回 "http";
    // 当信任代理时,改用 X-Forwarded-Proto 头的第一个值(反向代理在终结 HTTPS 后
    // 转发明文请求时,会用该头告知原始协议)。对应 Express 的 req.protocol。
    public func protocol(): String {
        if (trustProxy()) {
            match (this.header("x-forwarded-proto")) {
                case Some(v) =>
                    let (first, _) = splitOnce(v, ",")
                    let p = first.trimAscii().toAsciiLower()
                    if (!p.isEmpty()) {
                        return p
                    }
                case None => ()
            }
        }
        return "http"
    }

    // 请求是否经由 HTTPS,等价于 protocol() == "https"。对应 Express 的 req.secure。
    public func secure(): Bool {
        return protocol() == "https"
    }

    // X-Forwarded-For 链(对应 Express 的 req.ips)。仅在信任代理时有意义:把该头
    // 按逗号拆分、去空白,顺序为「最靠近客户端 → 最靠近服务器」。不信任代理或无此头
    // 时返回空列表。
    public func ips(): ArrayList<String> {
        let out = ArrayList<String>()
        if (trustProxy()) {
            match (this.header("x-forwarded-for")) {
                case Some(v) =>
                    for (part in v.split(",")) {
                        let p = part.trimAscii()
                        if (!p.isEmpty()) {
                            out.add(p)
                        }
                    }
                case None => ()
            }
        }
        return out
    }

    // 客户端真实 IP:信任代理时取 X-Forwarded-For 链中的第一个(最初的客户端),
    // 否则回退到直连对端地址 ip。之所以单列一个方法而非改写 ip 字段,是为了保持
    // ip 始终表示「直接对端」的语义不变(ip 由服务端在建立连接时填入)。
    public func clientIp(): String {
        if (trustProxy()) {
            let chain = ips()
            if (!chain.isEmpty()) {
                return chain[0]
            }
        }
        return this.ip
    }

    // 子域名列表(对应 Express 的 req.subdomains)。在 hostname 的基础上,去掉末尾
    // 「主域名 + 顶级域」若干段(段数由应用设置 "subdomain offset" 决定,默认 2),
    // 其余段按从右到左(由近及远)的顺序返回。
    // 例如 hostname 为 "tobi.ferrets.example.com"、offset=2 时返回 ["ferrets", "tobi"]。
    // 当主机名是 IP 字面量、或段数不足以扣除 offset 时,返回空列表。
    public func subdomains(): ArrayList<String> {
        let out = ArrayList<String>()
        let host = match (hostname()) {
            case Some(h) => h
            case None => return out
        }
        // IP 地址(IPv4 或方括号 IPv6 字面量)不拆子域名。
        if (host.startsWith("[") || isIpv4Like(host)) {
            return out
        }
        let parts = host.split(".")
        let offset = subdomainOffset()
        // 丢弃末尾 offset 段,把剩下的从右往左收集。
        var i = parts.size - offset - 1
        while (i >= 0) {
            out.add(parts[i])
            i -= 1
        }
        return out
    }

    // 读取应用设置 "subdomain offset"(默认 2);非正数或缺失时回退为 2。
    func subdomainOffset(): Int64 {
        match (this.setting("subdomain offset")) {
            case Some(v) =>
                let n = parseInt(v)
                if (n > 0) {
                    return n
                }
                return 2
            case None => return 2
        }
    }

    // 是否为 AJAX 请求:X-Requested-With 头等于 "XMLHttpRequest"(大小写无关)。
    // 许多前端库(如 jQuery)会自动带上该头。对应 Express 的 req.xhr。
    public func xhr(): Bool {
        match (this.header("x-requested-with")) {
            case Some(v) => return v.toAsciiLower() == "xmlhttprequest"
            case None => return false
        }
    }
}

// 判断字符串是否形如 IPv4 地址(只由数字与 "." 组成)。用于在 subdomains 中避免把
// 形如 "127.0.0.1" 的 IP 误当作带子域名的主机名来拆分。
func isIpv4Like(s: String): Bool {
    if (s.isEmpty()) {
        return false
    }
    for (b in s.toArray()) {
        if (!((b >= UInt8(48) && b <= UInt8(57)) || b == UInt8(46))) {
            return false
        }
    }
    return true
}
