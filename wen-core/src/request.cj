package wen

import std.collection.*

/**
 * 一个进入服务端的 HTTP 请求对象。
 *
 * 注意:请求头(header)的键统一以小写形式存储,这样按名字查找时就与大小写无关,
 * 符合 HTTP 规范中"字段名大小写不敏感"的要求(例如 "Content-Type" 与
 * "content-type" 视为同一个头)。配套的 `header()` / `get()` 方法在查询前也会把
 * 传入的名字转成小写,从而保证写入和读取两端一致。
 */
public class HttpRequest {
    public var method: String
    public var url: String // 原始请求目标(request target),包含查询串,例如 "/a?x=1"
    public var path: String // 仅路径部分(已剥离查询串),例如 "/a"
    public var httpVersion: String

    // 始终保留客户端发来的原始请求 URL(含查询串),不随中间件对 url/path 的修改而改变。
    // 对应 Express 的 req.originalUrl。在 app.use(path, router) 子挂载场景下,
    // 访问 /api/users 时 url 可能被改写为 /users,但 originalUrl 始终是 /api/users。
    public var originalUrl: String = ""

    // 当前路由器实例被挂载的路径前缀。例如把子路由挂载到 "/api" 时,进入该子路由的
    // 请求其 baseUrl 为 "/api"。顶级路由的 baseUrl 为 ""。对应 Express 的 req.baseUrl。
    public var baseUrl: String = ""

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

    // 解析后的请求 Cookie 键值对。首次通过 cookie()/signedCookie() 等访问器读取时,
    // 会从 Cookie 头按需解析填充(也可由可选的 cookieParser 中间件提前触发)。
    public let cookies: HashMap<String, String>

    // 请求体的原始字节。服务端会原样保留这份字节数据,以确保二进制负载
    // (例如文件上传、被代理转发的内容等)不会在编码转换中被破坏。
    // 上面的 `body` 字段则是同一份数据按 UTF-8 解码后的字符串视图,适合处理
    // 文本请求体;需要逐字节处理二进制时应使用 bodyBytes。
    public var bodyBytes: Array<UInt8>

    // 解析后的 JSON 请求体。首次调用 json() 时,会按需解析 application/json 请求体
    // 填充(也可由可选的 jsonParser 中间件提前触发);为空 / 非法 JSON 时保持 None。
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

    // 指向本次请求对应的响应对象,对应 Express 的 req.res,由 app.handle 设置;
    // 直接构造请求(未经应用派发)时为 None。fresh()/stale() 依赖它读取响应上的
    // ETag / Last-Modified 头。
    public var res: ?HttpResponse = None

    // multipart/form-data 上传的文件列表。首次通过 file(name)/files 访问时,会按需解析
    // multipart 请求体填充(也可由可选的 multipart 中间件提前触发)。用 file(name) 取单个文件。
    public let files: ArrayList<UploadedFile> = ArrayList<UploadedFile>()

    // 当前请求的会话对象,由 session() 中间件设置;未启用时为 None。
    public var session: ?Session = None

    // multipart 解析的配额与过滤选项。由 multipart(maxFileSize!, ...) 中间件在执行
    // 时塞入,供 ensureBody 触发的 parseMultipart 读取;为 None 时不施加任何配额。
    // 必须在任何会触发请求体解析的代码(如 req.attribute / req.file / 其它解析中间件)
    // 之前注册中间件,否则配额来不及生效。
    public var multipartOptions: ?MultipartOptions = None

    // 内部状态:next("route") 信号。处理器调用 nextRoute() 置位后,调度器会跳过
    // 当前路由的剩余处理器。
    var skipRouteFlag: Bool = false
    // 内部状态:本请求已触发过 param 预处理回调的参数名,确保每个参数名只触发一次。
    let processedParamNames: ArrayList<String> = ArrayList<String>()
    // 内部状态:请求体 / Cookie 是否已解析(懒解析的一次性闸门,见 ensureBody / ensureCookies)。
    var bodyParsed: Bool = false
    var cookiesParsed: Bool = false

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
        ensureBody()
        return this.attributes.get(key)
    }

    // 本请求的关联 ID(由 requestId() 中间件设置;未启用时为 None)。
    public func requestId(): ?String {
        return this.attributes.get("requestId")
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

    // 取一个 Cookie 值。首次访问时自动解析 Cookie 头(无需任何中间件);
    // 不存在同名 Cookie 时返回 None。
    public func cookie(name: String): ?String {
        ensureCookies()
        return this.cookies.get(name)
    }

    // 返回解析后的 JSON 请求体。首次调用时自动解析 application/json 请求体(无需任何
    // 中间件);请求体为空或非法 JSON 时返回 None。拿到 JsonValue 后,可用
    // get/at/asString/asInt 等方法在其中逐层导航取值。
    public func json(): ?JsonValue {
        ensureBody()
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
    // (例如 "json"),也可以是完整的 MIME 类型。请求没有 Content-Type 头时返回 false。
    // (之所以叫 isType 而不是 is,是因为 `is` 是仓颉的关键字;Express 中对应
    // 的方法名为 `req.is`。)
    //
    // 匹配规则(对齐 Express / RFC 6838 §4.2.8 结构化语法后缀):
    //   1. 精确匹配:`isType("json")` 命中 `application/json`。
    //   2. 结构化后缀:`isType("json")` 也命中 `application/ld+json`、`application/vnd.api+json`。
    // 早先实现用 contains 做子串包含,会把 `application/xmlrpc` 当成 xml(误判),
    // 也会把 `application/json-patch+json` 当成 json(碰巧对,但理由不对);现在改成
    // 严格 token 比对,只走精确名 + 后缀两条路径。
    public func isType(t: String): Bool {
        let ct = match (this.header("content-type")) {
            case Some(v) => v.toAsciiLower()
            case None => return false
        }
        let actualMain = primaryContentType(ct)
        let (wantRaw, _) = splitOnce(contentTypeFor(t).toAsciiLower(), ";")
        let wantMain = wantRaw.trimAscii()
        if (actualMain == wantMain) {
            return true
        }
        // 结构化后缀语法:wantMain = "application/json",actualMain = "application/ld+json"
        // 当 want 的 subtype 是简单 token(不含 "+")时,匹配以 "+<subtype>" 结尾的 actual。
        let (wantType, wantSub) = splitOnce(wantMain, "/")
        let (actualType, actualSub) = splitOnce(actualMain, "/")
        if (wantType.isEmpty() || wantSub.isEmpty() || actualType.isEmpty() || actualSub.isEmpty()) {
            return false
        }
        if (wantType != actualType) {
            return false
        }
        if (wantSub.contains("+")) {
            return false
        }
        return actualSub.endsWith("+${wantSub}")
    }

    // 判断客户端的 Accept 请求头是否接受类型 `t`(`t` 可为简写或完整 MIME 类型)。
    // 缺少 Accept 头时视为接受任何类型(返回 true)。否则按内容协商规则判断:把 `t`
    // 展开成完整 MIME、剥掉参数部分,在 Accept 条目中查找匹配并要求其质量值 q > 0
    // (即某项写成 "application/json;q=0" 时,该类型被明确拒绝,返回 false)。
    public func accepts(t: String): Bool {
        match (this.header("accept")) {
            case None => return true
            case Some(v) =>
                let items = parseAcceptHeader(v)
                if (items.isEmpty()) {
                    return true
                }
                let (full, _) = splitOnce(contentTypeFor(t).toAsciiLower(), ";")
                let (q, rank, _) = acceptMatch(full.trimAscii(), items)
                return rank >= 0 && q > 0.0
        }
    }

    // 在一组候选类型里,按客户端 Accept 头选出「最佳」的那个并返回(对应 Express 的
    // req.accepts([...]))。挑选优先级:质量值 q 越大越好;q 相同则匹配越具体越好;
    // 再相同则在 Accept 头中越靠前越好;仍相同则按候选数组给出的先后。都不被接受
    // (或都 q=0)时返回 None。缺少 Accept 头时返回候选中的第一个。
    public func accepts(types: Array<String>): ?String {
        let header = match (this.header("accept")) {
            case Some(v) => v
            case None =>
                if (types.size > 0) {
                    return Some(types[0])
                }
                return None
        }
        let items = parseAcceptHeader(header)
        if (items.isEmpty()) {
            if (types.size > 0) {
                return Some(types[0])
            }
            return None
        }
        var best: ?String = None
        var bestQ = -1.0
        var bestRank = -2
        var bestIdx = 0
        for (cand in types) {
            let (full, _) = splitOnce(contentTypeFor(cand).toAsciiLower(), ";")
            let (q, rank, idx) = acceptMatch(full.trimAscii(), items)
            if (rank < 0 || q <= 0.0) {
                continue
            }
            var better = false
            if (q > bestQ) {
                better = true
            } else if (q == bestQ) {
                if (rank > bestRank) {
                    better = true
                } else if (rank == bestRank && idx < bestIdx) {
                    better = true
                }
            }
            if (better) {
                bestQ = q
                bestRank = rank
                bestIdx = idx
                best = Some(cand)
            }
        }
        return best
    }

    // 内容协商:从候选 charset 列表里挑出客户端 Accept-Charset 最偏好的一个,对应
    // Express 的 req.acceptsCharsets([...])。缺少该头时返回首个候选;都不可接受时返回 None。
    public func acceptsCharsets(charsets: Array<String>): ?String {
        return negotiateAccept(this.header("accept-charset"), charsets, false, false)
    }

    // 单个 charset 是否可被接受(acceptsCharsets 的布尔便捷形式)。
    public func acceptsCharsets(charset: String): Bool {
        match (acceptsCharsets([charset])) {
            case Some(_) => return true
            case None => return false
        }
    }

    // 从候选编码列表里挑出客户端 Accept-Encoding 最偏好的一个,对应 req.acceptsEncodings。
    // 特例:"identity"(不压缩)默认可接受,除非被 "identity;q=0" 或 "*;q=0" 显式排除。
    public func acceptsEncodings(encodings: Array<String>): ?String {
        return negotiateAccept(this.header("accept-encoding"), encodings, false, true)
    }

    // 单个编码是否可被接受(acceptsEncodings 的布尔便捷形式)。
    public func acceptsEncodings(encoding: String): Bool {
        match (acceptsEncodings([encoding])) {
            case Some(_) => return true
            case None => return false
        }
    }

    // 从候选语言列表里挑出客户端 Accept-Language 最偏好的一个,对应 req.acceptsLanguages。
    // 支持语言前缀匹配:头里的 "en" 可匹配候选 "en-US"。
    public func acceptsLanguages(languages: Array<String>): ?String {
        return negotiateAccept(this.header("accept-language"), languages, true, false)
    }

    // 单个语言是否可被接受(acceptsLanguages 的布尔便捷形式)。
    public func acceptsLanguages(language: String): Bool {
        match (acceptsLanguages([language])) {
            case Some(_) => return true
            case None => return false
        }
    }

    // 解析 Range 请求头,对应 Express 的 req.range(size)。size 为内容总字节数。返回:
    //   NoRange         —— 请求未带 Range 头;
    //   Malformed       —— 语法非法(无 "bytes=" 单位或为空,对应 Express 的 -2);
    //   Unsatisfiable   —— 语法合法但区间全部越界(对应 Express 的 -1,调用方应回 416);
    //   Satisfiable(rs) —— 一个或多个可满足的字节区间(闭区间含两端,已按 size 归一化)。
    // 支持多区间(逗号分隔)及 "start-end" / "start-" / "-suffix" 三种写法;末尾后缀
    // 超过 size 时起点夹到 0(与文件服务的 Range 行为一致)。单个非法/越界子区间会被跳过。
    public func range(size: Int64): RangeRequest {
        let raw = match (this.header("range")) {
            case Some(v) => v.trimAscii()
            case None => return NoRange
        }
        if (!raw.toAsciiLower().startsWith("bytes=")) {
            return Malformed
        }
        let spec = raw[6..raw.size].trimAscii()
        if (spec.isEmpty()) {
            return Malformed
        }
        if (size <= 0) {
            return Unsatisfiable
        }
        let ranges = ArrayList<ByteRange>()
        // 防御:Range 多区间放大攻击。客户端 "bytes=0-0,0-1,..." 几千段可让响应放大成
        // multipart,消耗带宽与 CPU。nginx / Apache 默认上限在十位数,这里取 16。
        let maxRanges = 16
        for (part in spec.split(",")) {
            if (ranges.size >= maxRanges) {
                return Malformed
            }
            let p = part.trimAscii()
            if (p.isEmpty()) {
                continue
            }
            let (aRaw, bRaw) = splitOnce(p, "-")
            let aStr = aRaw.trimAscii()
            let bStr = bRaw.trimAscii()
            var start = 0
            var end = 0
            if (aStr.isEmpty()) {
                // "-N":请求末尾 N 个字节。
                if (!allDigits(bStr)) {
                    continue
                }
                let n = parseInt(bStr)
                if (n <= 0) {
                    continue
                }
                start = size - n
                if (start < 0) {
                    start = 0
                }
                end = size - 1
            } else {
                if (!allDigits(aStr)) {
                    continue
                }
                start = parseInt(aStr)
                if (bStr.isEmpty()) {
                    end = size - 1
                } else if (allDigits(bStr)) {
                    end = parseInt(bStr)
                } else {
                    continue
                }
            }
            if (end > size - 1) {
                end = size - 1
            }
            if (start < 0 || start > end) {
                continue
            }
            ranges.add(ByteRange(start, end))
        }
        if (ranges.isEmpty()) {
            return Unsatisfiable
        }
        return Satisfiable(ranges.toArray())
    }

    // 对应 Express 的 req.fresh:依据条件请求头判断「客户端缓存是否仍然新鲜」(可回 304)。
    // 为 true 需同时满足:
    //   1. 方法为 GET 或 HEAD;
    //   2. 已绑定响应(经 app.handle 派发)且其状态码为 2xx 或 304;
    //   3. 请求带 If-None-Match 或 If-Modified-Since(都没有则无从判断,返回 false);
    //   4. 请求未声明 Cache-Control: no-cache;
    //   5. 与响应的 ETag / Last-Modified 比对全部通过。
    // ETag 比对复用 etagMatches(支持 "*"、逗号分隔、弱校验前缀);Last-Modified 采用与
    // 文件响应一致的保守判断(取值完全相等才算未变),绝不误判为「未修改」。
    public func fresh(): Bool {
        if (this.method != "GET" && this.method != "HEAD") {
            return false
        }
        let res = match (this.res) {
            case Some(r) => r
            case None => return false
        }
        let status = res.statusCode
        if (!((status >= 200 && status < 300) || status == 304)) {
            return false
        }

        let inm = this.header("if-none-match")
        let ims = this.header("if-modified-since")
        let hasInm = match (inm) {
            case Some(_) => true;
            case None => false
        }
        let hasIms = match (ims) {
            case Some(_) => true;
            case None => false
        }
        if (!hasInm && !hasIms) {
            return false
        }
        match (this.header("cache-control")) {
            case Some(cc) =>
                if (cc.toAsciiLower().contains("no-cache")) {
                    return false
                }
            case None => ()
        }
        // If-None-Match:"*" 视为命中;否则需与响应 ETag 匹配(无 ETag 则判为不新鲜)。
        match (inm) {
            case Some(v) =>
                if (v.trimAscii() != "*") {
                    match (responseHeaderCI(res, "etag")) {
                        case Some(etag) =>
                            if (!etagMatches(v, etag)) {
                                return false
                            }
                        case None => return false
                    }
                }
            case None => ()
        }
        // If-Modified-Since:保守地只在与响应 Last-Modified 完全相等时才算未变。
        match (ims) {
            case Some(v) => match (responseHeaderCI(res, "last-modified")) {
                case Some(lm) =>
                    if (v.trimAscii() != lm.trimAscii()) {
                        return false
                    }
                case None => return false
            }
            case None => ()
        }
        return true
    }

    // 对应 Express 的 req.stale:与 fresh() 相反,表示客户端缓存已过期、需重新发送内容。
    public func stale(): Bool {
        return !fresh()
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
                case Some(v) => for (part in v.split(",")) {
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

    // 跳过当前路由的剩余处理器,直接进入下一条匹配的路由(对应 Express 的
    // next("route"))。仅在「一条路由挂多个处理器」时有意义:某个处理器据此放弃
    // 本路由、把机会让给后面的路由。调用后应立即 return,不要再调用 next。
    public func nextRoute(): Unit {
        this.skipRouteFlag = true
    }

    // 内部:读取并清除 next("route") 信号,返回它本次是否被置位。
    func consumeSkipRoute(): Bool {
        if (this.skipRouteFlag) {
            this.skipRouteFlag = false
            return true
        }
        return false
    }

    // 读取并验签一个签名 Cookie(对应 res.cookie(..., signed: true) 写入的值)。
    // 流程:从 cookies 取原始值(形如 "<value>.<sig>"),用 app.cookieSecret 重新计算
    // HMAC 并定长时间比对;一致才返回原值,否则(无该 Cookie / 无密钥 / 验签失败)
    // 返回 None。Cookie 头在首次访问时自动解析,无需任何中间件。
    public func signedCookie(name: String): ?String {
        ensureCookies()
        let raw = match (this.cookies.get(name)) {
            case Some(v) => v
            case None => return None
        }
        return verifySignedCookie(raw)
    }

    // 把所有验签通过的 Cookie 收集成一张 name -> 已验签值 的映射,对应 Express 的
    // req.signedCookies。每次调用都会重新计算(因此可在中间件链中任何时刻读到最新结果);
    // 验签失败或非签名形态的 Cookie 不会进入结果。无密钥 / 无 cookies 时返回空表。
    public func signedCookies(): HashMap<String, String> {
        ensureCookies()
        let out = HashMap<String, String>()
        for ((name, raw) in this.cookies) {
            match (verifySignedCookie(raw)) {
                case Some(v) => out[name] = v
                case None => ()
            }
        }
        return out
    }

    // 验签单个 Cookie 原始值:无密钥 / 形态不对 / HMAC 不一致都返回 None。
    // 主密钥失败后会依次尝试 app.legacyCookieSecrets(密钥轮换期重叠认证)。
    private func verifySignedCookie(raw: String): ?String {
        let app = match (this.app) {
            case Some(a) => a
            case None => return None
        }
        warnIfWeakCookieSecret(this.app, app.cookieSecret)
        if (app.cookieSecret.isEmpty()) {
            return None
        }
        // 以最后一个 "." 分隔出 value 与签名(value 自身可包含 ".")。
        let idx = lastIndexOfDot(raw)
        if (idx < 0) {
            return None
        }
        let value = raw[0..idx]
        let sig = raw[(idx + 1)..raw.size]
        // P1-8:始终遍历完所有候选(累积 OR),不早返 — 早先实现"主密钥命中立刻 return"
        // 与"legacy 命中需先 hmac N 次 legacy"之间存在可观测时序差,攻击者反复请求即可
        // 推断"自己 cookie 用的是主密钥还是 legacy",泄露轮换进度。把所有 HMAC 都算完
        // 后再判定,密钥轮换状态对外不可观察。
        var matched = constantTimeEquals(sig, hmacSha256Hex(app.cookieSecret, value))
        for (legacy in app.legacyCookieSecrets) {
            if (legacy.isEmpty()) {
                continue
            }
            // 关键:**先** 计算 HMAC 与比较结果再 OR 回去 — 不能直接写
            // `matched = matched || constantTimeEquals(...)`,因为 `||` 短路会跳过已
            // matched 后的 HMAC 计算,重新引入时序差。
            let thisOne = constantTimeEquals(sig, hmacSha256Hex(legacy, value))
            matched = matched || thisOne
        }
        if (matched) {
            return Some(value)
        }
        return None
    }

    // 取某个字段名的上传文件(同名多文件时返回第一个);不存在则返回 None。
    // 首次访问时自动解析 multipart 请求体,无需任何中间件。
    public func file(name: String): ?UploadedFile {
        ensureBody()
        for (f in this.files) {
            if (f.fieldName == name) {
                return Some(f)
            }
        }
        return None
    }

    // 懒解析请求体:按 Content-Type 解析一次。application/json -> jsonBody;
    // x-www-form-urlencoded -> attributes;multipart/form-data -> files(文本字段进 attributes)。
    // 由 json()/attribute()/file() 等访问器按需触发;jsonParser/urlencodedParser/multipart
    // 等中间件也只是提前调用它。无 Content-Type 或类型不匹配时什么都不做。
    func ensureBody(): Unit {
        if (bodyParsed) {
            return
        }
        bodyParsed = true
        let ctRaw = match (header("content-type")) {
            case Some(v) => v
            case None => return
        }
        let mainType = primaryContentType(ctRaw)
        // app 级注册的自定义解析器优先(请求已关联 app 且注册了匹配该主类型的解析器时):
        // 它既能支持内置三类之外的类型(如 application/xml),也能覆盖内置默认。
        match (this.app) {
            case Some(a) => match (a.bodyParserFor(mainType)) {
                case Some(parser) =>
                    parser(this)
                    return
                case None => ()
            }
            case None => ()
        }
        // 回落内置解析器(始终可用,不依赖 app):测试中直接构造、未经 app 派发的请求,
        // 以及 app 未注册对应解析器的常规情况,都据此正常解析。
        runBuiltinBodyParser(mainType, ctRaw)
    }

    // 内置请求体解析:按主 Content-Type 分派到 json / urlencoded / multipart;均为
    // 「尽力解析、失败不报错」(非法 JSON 时 jsonBody 保持 None)。其它类型不处理。
    func runBuiltinBodyParser(mainType: String, ctRaw: String): Unit {
        if (mainType == "application/json") {
            if (!this.body.isEmpty()) {
                try {
                    this.jsonBody = Some(parseJson(this.body))
                } catch (_: JsonException) {
                    ()
                }
            }
        } else if (mainType == "application/x-www-form-urlencoded") {
            // form 字段不允许污染 framework-reserved 命名空间。早先直接 parseQuery 进
            // attributes,攻击者 POST `authUser=admin&csrfToken=...` 即可覆盖框架内部
            // 状态。round3 P1-10 / P1-B。
            parseFormBodyIntoAttributes(this.body, this.attributes)
        } else if (mainType == "multipart/form-data") {
            match (extractBoundary(ctRaw)) {
                case Some(b) => parseMultipart(this, b)
                case None => ()
            }
        }
    }

    // 懒解析 Cookie 头一次,填充 cookies。由 cookie()/signedCookie() 等访问器按需触发;
    // cookieParser 中间件也只是提前调用它。无 Cookie 头时什么都不做。
    func ensureCookies(): Unit {
        if (cookiesParsed) {
            return
        }
        cookiesParsed = true
        match (header("cookie")) {
            case Some(raw) => for (pair in raw.split(";")) {
                let p = pair.trimAscii()
                if (p.isEmpty()) {
                    continue
                }
                let (k, vRaw) = splitOnce(p, "=")
                let name = k.trimAscii()
                if (name.isEmpty()) {
                    continue
                }
                // 按 RFC 6265:cookie 值可被双引号包裹(被某些客户端使用),需要剥掉。
                // **不**做隐式 urlDecode:RFC 6265 cookie-value 不要求 percent-encoding,
                // res.cookie 写端从不编码,读端做 decode 是不对称的"防御"。这一不对称
                // 会让 signed cookie 含 + / %XX 时 ensureCookies 把 "+" 解为空格 → 重算
                // HMAC 与签名段不符 → signedCookie 永远返回 None,静默丢会话(P0-1)。
                var v = vRaw.trimAscii()
                if (v.size >= 2 && v.startsWith("\"") && v.endsWith("\"")) {
                    v = v[1..(v.size - 1)]
                }
                this.cookies[name] = v
            }
            case None => ()
        }
    }

    // 内部:某参数名的预处理回调本请求是否已触发过。
    func paramProcessed(name: String): Bool {
        return listContains(this.processedParamNames, name)
    }

    // 内部:标记某参数名的预处理回调本请求已触发。
    func markParamProcessed(name: String): Unit {
        this.processedParamNames.add(name)
    }
}

// 取 Content-Type 的主类型:剥掉分号后的参数(charset/boundary 等)、去空白、小写。
// 例如 "application/json; charset=utf-8" -> "application/json"。app.bodyParser 注册与
// ensureBody 查询两端共用,以保证注册 "application/xml" 能匹配请求头 "application/xml; ..."。
func primaryContentType(ct: String): String {
    let (head, _) = splitOnce(ct, ";")
    return head.trimAscii().toAsciiLower()
}

// 判断一个键名是否属于框架保留的 attribute 命名空间。这些名字被框架内置中间件
// 用作内部状态字段(身份 / CSRF token / 原始方法 / 请求 ID / 文本 body 视图)。
// 自动解析路径(urlencoded form / multipart 文本字段)不能写入这些键,否则攻击者
// 经表单字段即可覆盖框架内部状态(round3 P1-10 / P1-B)。
//
// 注意:本拦截仅作用于"自动解析路径",不作用于用户显式调用 setAttribute(key, val)
// — 后者是 API 使用者主动选择的信任边界。
func isFrameworkReservedAttribute(key: String): Bool {
    return key == "authUser" || key == "csrfToken" || key == "originalMethod"
        || key == "requestId" || key == "text"
}

// 把 form 请求体解析进 attributes,但跳过 framework-reserved 键。等价于 parseQuery
// 加保留键过滤。攻击者 POST `authUser=admin&csrfToken=...` 仍能在 form 里出现,但
// 这些字段不会进入 attributes,因此 framework 内部状态不被污染。
func parseFormBodyIntoAttributes(body: String, into: HashMap<String, String>): Unit {
    if (body.isEmpty()) {
        return
    }
    for (pair in body.split("&")) {
        if (pair.isEmpty()) {
            continue
        }
        let (k, v) = splitOnce(pair, "=")
        let key = urlDecode(k)
        if (isFrameworkReservedAttribute(key)) {
            continue
        }
        into[key] = urlDecode(v)
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

/**
 * 一个字节区间 `[start, end]`(闭区间,含两端)。
 *
 * `req.range(size)` 解析出的每个可满足区间都用它表示。参见 [[HttpRequest]].range。
 */
public struct ByteRange {
    public let start: Int64
    public let end: Int64
    public init(start: Int64, end: Int64) {
        this.start = start
        this.end = end
    }
}

/**
 * `req.range(size)` 的解析结果,详见 [[HttpRequest]].range 的文档说明。
 *
 * - `Satisfiable`:语法合法且至少一个区间可满足,携带去重 / 合并后的所有 [[ByteRange]]
 * - `Unsatisfiable`:语法合法但全部区间越界(对应 416 状态码)
 * - `Malformed`:Range 头存在但语法无效
 * - `NoRange`:请求未携带 Range 头
 */
public enum RangeRequest {
    | Satisfiable(Array<ByteRange>)
    | Unsatisfiable
    | Malformed
    | NoRange
}

// 字符串是否非空且全部由 ASCII 数字组成。用于 Range 解析时区分「缺省/非数字」
// 与合法数字(parseInt 对空串/非数字一律返回 0,无法单独区分,故先用本函数判定)。
func allDigits(s: String): Bool {
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

// 大小写无关地读取一个响应头(res.get 按原样键查找,这里兜底处理大小写差异),
// 供 fresh() 读取响应的 ETag / Last-Modified。
func responseHeaderCI(res: HttpResponse, name: String): ?String {
    let want = name.toAsciiLower()
    for ((k, v) in res.headers) {
        if (k.toAsciiLower() == want) {
            return v
        }
    }
    return None
}
