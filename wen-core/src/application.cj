package wen

import std.collection.*
import std.sync.*

// 检查 cookieSecret 强度,长度 < 32 字节(256 位)时在 stderr 打一行警告。该长度阈值
// 对应「在线暴力破解 HMAC-SHA256 实际不可行」的常用底线。空串不警告(配套异常已说明)。
// 不强制抛错(避免阻断已有应用启动),只引起开发者关注。
//
// 警告闸门由 Application 实例字段 warnedWeakCookieSecret 承担(从前的包级
// AtomicBool 会让同进程内多个 Application 共享标志位,跨实例的弱密钥警告漏报)。
func warnIfWeakCookieSecret(app: ?Application, secret: String): Unit {
    if (secret.isEmpty() || secret.size >= 32) {
        return
    }
    match (app) {
        case Some(a) =>
            if (!a.warnedWeakCookieSecret.compareAndSwap(false, true)) {
                return
            }
        case None => ()
    }
    eprintln("[wen] 警告: cookieSecret 长度 ${secret.size} 不足 32 字节(256 位),易被暴力破解;生产环境请使用至少 32 字节的强随机密钥")
}

// 应用启动后再修改配置(setLocal / engine / bodyParser / set / enable / disable / mime)
// 会抛此异常。多线程并发请求阶段对共享 HashMap 的写入会引发数据竞争,所以"配置阶段
// 写入、运行阶段只读"被设为强约束。
public class IllegalStateException <: Exception {
    public init(msg: String) {
        super(msg)
    }
}

/*
 * 应用对象——相当于 Express 里的 `const app = express()`。
 *
 * 它是整个框架对外的主入口，聚合了路由表、设置项和应用级共享数据，并提供注册
 * 路由 / 中间件以及启动服务器的全部方法。
 *
 * 两个一贯的设计约定：
 * 1. 链式调用：所有注册类方法都返回 `this`（Application 自身），因此可以
 *    app.use(...).get(...).post(...) 这样连写。
 * 2. 处理器双形式：每个动词方法既接受完整的 `Middleware`（(req, res, next)），
 *    也接受终结的 `Handler`（(req, res)，不带 next）。后者由框架自动用一个
 *    包装器补上被忽略的 next，从而统一成 Middleware 纳入调度——调用方无需关心
 *    这层转换。
 */
public class Application {
    let router: Router = Router()
    let settings: HashMap<String, String> = HashMap<String, String>()

    // 实例级的弱密钥告警闸门:同进程内多个 Application 各自独立提醒一次,免刷屏。
    let warnedWeakCookieSecret: AtomicBool = AtomicBool(false)

    // 应用是否已进入「运行阶段」:listen() 一旦启动便置 true,此后再修改路由 / 共享配置
    // (use / get / post / set / engine / bodyParser / setLocal 等)都会抛
    // IllegalStateException — 因为请求处理线程会并发读这些字段(HashMap/ArrayList 非
    // 线程安全),启动后再写就是数据竞争。
    let frozen: AtomicBool = AtomicBool(false)

    // 应用级的共享存储（对应 Express 的 app.locals）：一张键值表，生命周期
    // 与应用相同、被所有请求共享。适合放配置对象、共享的服务实例、全局可复用
    // 的资源等。值类型为 Any，因此可以存放任意类型；取用时需要由调用方自行
    // 断言 / 转换回具体类型。与「按请求」隔离的数据不同，这里写入的内容对后续
    // 所有请求都可见。
    public let locals: HashMap<String, Any> = HashMap<String, Any>()

    // 是否信任反向代理设置的 X-Forwarded-* 头(对应 Express 的 'trust proxy')。
    // 置为 true 后,req.protocol/secure/hostname/ips/clientIp 会采信
    // X-Forwarded-Proto / X-Forwarded-Host / X-Forwarded-For;否则一律视为直连。
    // 仅当应用确实部署在可信代理(如 Nginx)之后才开启,否则客户端可伪造这些头。
    public var trustProxy: Bool = false

    // 签名 Cookie / session 所用的 HMAC 主密钥。设为非空后,res.cookie(..., signed: true)
    // 会对值签名、req.signedCookie 会验签;session() 中间件也依赖它来保护 sid。
    // 生产环境请设为足够随机的长字符串,且妥善保管、不要硬编码进版本库。
    //
    // **新签发**始终用本主密钥;**验签**先用主密钥,失败再依次尝试 legacyCookieSecrets。
    public var cookieSecret: String = ""

    // 密钥轮换期间的"旧密钥列表"。验签时,主 cookieSecret 失败后会依次尝试这里的每个
    // 密钥;一旦匹配即视为有效。新签发(res.cookie / sid 续期)始终用主密钥,确保下次
    // 请求即被切换到新密钥。典型流程:
    //   1. 现有部署:cookieSecret = "old"
    //   2. 升级:cookieSecret = "new",legacyCookieSecrets = ["old"]
    //   3. 等所有持有旧 cookie 的客户端在过期 / 续期后被切换到 new
    //   4. 清空 legacyCookieSecrets,完成轮换
    // 对应 Express cookie-parser(['new', 'old']) 的语义,但分离主签发与 fallback。
    public var legacyCookieSecrets: Array<String> = Array<String>()

    // 已注册的视图引擎表:键为扩展名(不含点,如 "html"),值为对应的渲染引擎。
    // 经 app.engine(ext, fn) 注册;res.render 时按模板扩展名在此查找,未注册即抛异常。
    let engines: HashMap<String, ViewEngine> = HashMap<String, ViewEngine>()

    // 已注册的请求体解析器表:键为规范化的主 Content-Type(如 "application/xml"),值为
    // 对应解析器。经 app.bodyParser(contentType, fn) 注册;ensureBody 懒解析时优先查它,
    // 未命中再回落内置(json/urlencoded/multipart)。
    let bodyParsers: HashMap<String, BodyParser> = HashMap<String, BodyParser>()

    public init() {}

    // 把应用切到「运行阶段」:由 listen 在启动前调用。一旦冻结,后续配置类写操作
    // (路由注册、setLocal、engine、bodyParser、set/enable/disable、mime 等)都会
    // 抛 IllegalStateException,避免请求处理线程与运行时写入并发访问 HashMap。
    // 同时联动冻结底层 router,使所有路由注册入口也拒绝写入。
    func markFrozen(): Unit {
        // 在冻结之前把两项路由 settings 同步到 router,使后续 handle 路径无需再写
        // router 字段 — 多线程并发请求时即便都写同值也是数据竞争,索性一次写完锁定。
        router.caseSensitive = enabled("case sensitive routing")
        router.strict = enabled("strict routing")
        frozen.store(true)
        router.freeze()
    }

    // 配置类方法入口检查:仅允许在 listen 之前修改应用配置。
    func ensureNotFrozen(): Unit {
        if (frozen.load()) {
            throw IllegalStateException("wen: 应用已 listen,不能再修改配置/路由/共享状态;请在 listen() 之前完成注册")
        }
    }

    public func setLocal(key: String, value: Any): Unit {
        ensureNotFrozen()
        locals[key] = value
    }

    public func local(key: String): ?Any {
        return locals.get(key)
    }

    // ---- 中间件 -------------------------------------------------------

    public func use(handler: Middleware): Application {
        router.use(handler)
        return this
    }

    public func use(path: String, handler: Middleware): Application {
        router.use(path, handler)
        return this
    }

    // 把一个子路由（Router）作为「迷你应用」挂载到 `path` 前缀下，对应 Express
    // 的 `app.use('/birds', router)`。挂载后，落在该前缀下的请求会交给子路由处理：
    // 子路由会先剥掉 `path` 前缀，再用剩余路径去匹配它自己的中间件和路由。
    //
    // 关于路径参数的边界行为：如果挂载前缀本身带有参数（例如 /birds/:type），
    // 这些被捕获的参数会保留在「共享的请求对象」上，因此子路由内部的处理函数
    // 仍能读取到它们——效果等同于 Express 的 mergeParams: true（父级参数对子路由
    // 可见，不会因为进入子路由就丢失）。实现上是把子路由包装成一个普通中间件，
    // 在其中调用 sub.handleAsMiddleware 来驱动子路由的匹配与执行。
    public func use(path: String, sub: Router): Application {
        sub.mountpath = path
        router.use(path, {
            req: HttpRequest, res: HttpResponse, next: Next => sub.handleAsMiddleware(req, res, next)
        })
        return this
    }

    // 注册一个错误处理中间件，形如 (err, req, res, next)。注意注册顺序很关键：
    // 它只能捕获「在它之前注册」的那些路由 / 中间件抛出的异常，因此应当把它放在
    // 那些需要被它兜底的路由之后注册——这一顺序语义与 Express 一致。
    public func use(handler: ErrorHandler): Application {
        router.useError(handler)
        return this
    }

    // 为某个模板扩展名注册视图引擎,对应 Express 的 app.engine(ext, fn)。扩展名可带
    // 或不带前导点("html" 与 ".html" 等价)。注册后,渲染该扩展名的模板时即用此引擎。
    public func engine(ext: String, fn: ViewEngine): Application {
        ensureNotFrozen()
        engines[normalizeExt(ext)] = fn
        return this
    }

    // 注册(或覆盖)一个扩展名到 MIME 类型的映射:此后 sendFile / download / 静态文件
    // 中间件按该扩展名发文件时,以及 res.type(ext)/res.mimeType(ext) 取该扩展名时,都会
    // 返回此 Content-Type。ext 可带或不带前导点、大小写不敏感(".WEBP" 与 "webp" 等价)。
    // 用于补齐内置表未覆盖的类型(.webp/.wasm/.avif 等)或覆盖内置默认。约定在 listen()
    // 之前调用。它是包级 registerMimeType 的链式语法糖,二者写入同一张进程级全局表。
    public func mime(ext: String, mimeType: String): Application {
        ensureNotFrozen()
        registerMimeType(ext, mimeType)
        return this
    }

    // 注册一个请求体解析器:当请求的主 Content-Type 等于 contentType(剥掉 charset 等
    // 参数后比较、大小写无关)时,首次经 req.json()/req.attribute()/req.local() 等访问器
    // 懒解析请求体会调用 parser(req),由它读取 req.body/req.bodyBytes 并把结果写回 req
    // (常见做法:req.setLocal(key, 对象) 供下游取用)。可支持内置三类(json/urlencoded/
    // multipart)之外的类型(如 application/xml、application/protobuf),也可覆盖内置默认。
    // 约定在 listen() 之前注册;解析器内抛出的异常会照常传播到错误处理流水线(框架不吞)。
    public func bodyParser(contentType: String, parser: BodyParser): Application {
        ensureNotFrozen()
        bodyParsers[primaryContentType(contentType)] = parser
        return this
    }

    // 内部:取匹配某主 Content-Type 的已注册解析器(供 HttpRequest.ensureBody 调用)。
    func bodyParserFor(mainType: String): ?BodyParser {
        return bodyParsers.get(mainType)
    }

    // 渲染一个视图并返回结果字符串(供 res.render 调用)。流程:
    //   1. 用 "views" 设置(默认 "views")作为视图根目录;
    //   2. 若 name 自带扩展名就用它,否则取 "view engine" 设置作为默认扩展名并补全文件名;
    //   3. 按扩展名查 app.engine(ext, fn) 注册的引擎;没有则抛异常;
    //   4. 交给引擎读取模板文件并渲染。
    //
    // 安全:视图名经 normalizeRelPath 规范化,若试图跳出 views 目录(如含 "../")抛异常,
    // 防止模板路径穿越。
    func renderView(name: String, data: JsonValue): String {
        let viewsDir = match (this.setting("views")) {
            case Some(v) => v
            case None => "views"
        }
        // 沙箱:确保 name 不会跳出 viewsDir。不在乎规范化结果(后续仍走 joinViewPath
        // 保留原拼接行为),只借此触发越界异常。
        normalizeRelPath(name)
        var fileName = name
        let ext = match (fileExt(name)) {
            case Some(e) => e
            case None => match (this.setting("view engine")) {
                case Some(e) =>
                    fileName = name + "." + e
                    e
                case None => throw Exception("render: 未设置 view engine,且视图名 '${name}' 不含扩展名")
            }
        }
        let path = joinViewPath(viewsDir, fileName)
        let eng = match (engines.get(normalizeExt(ext))) {
            case Some(en) => en
            case None => throw Exception("render: 未为扩展名 '${ext}' 注册视图引擎,请用 app.engine(...) 注册")
        }
        return eng(path, data)
    }

    // ---- 路由注册（Middleware 形式：处理器带 next）---------------------------

    public func get(path: String, handler: Middleware): Application {
        router.get(path, handler);
        return this
    }
    public func post(path: String, handler: Middleware): Application {
        router.post(path, handler);
        return this
    }
    public func put(path: String, handler: Middleware): Application {
        router.put(path, handler);
        return this
    }
    public func delete(path: String, handler: Middleware): Application {
        router.delete(path, handler);
        return this
    }
    public func patch(path: String, handler: Middleware): Application {
        router.patch(path, handler);
        return this
    }
    public func head(path: String, handler: Middleware): Application {
        router.head(path, handler);
        return this
    }
    public func options(path: String, handler: Middleware): Application {
        router.options(path, handler);
        return this
    }
    public func all(path: String, handler: Middleware): Application {
        router.all(path, handler);
        return this
    }

    // ---- 路由注册（终结 Handler 形式：处理器不带 next）-----------------------

    public func get(path: String, handler: Handler): Application {
        router.get(path, wrap(handler));
        return this
    }
    public func post(path: String, handler: Handler): Application {
        router.post(path, wrap(handler));
        return this
    }
    public func put(path: String, handler: Handler): Application {
        router.put(path, wrap(handler));
        return this
    }
    public func delete(path: String, handler: Handler): Application {
        router.delete(path, wrap(handler));
        return this
    }
    public func patch(path: String, handler: Handler): Application {
        router.patch(path, wrap(handler));
        return this
    }
    public func head(path: String, handler: Handler): Application {
        router.head(path, wrap(handler));
        return this
    }
    public func options(path: String, handler: Handler): Application {
        router.options(path, wrap(handler));
        return this
    }
    public func all(path: String, handler: Handler): Application {
        router.all(path, wrap(handler));
        return this
    }

    // ---- 路由注册（多处理器形式：同一路径挂多个中间件，按数组顺序执行）-------

    public func get(path: String, handlers: Array<Middleware>): Application {
        router.get(path, handlers);
        return this
    }
    public func post(path: String, handlers: Array<Middleware>): Application {
        router.post(path, handlers);
        return this
    }
    public func put(path: String, handlers: Array<Middleware>): Application {
        router.put(path, handlers);
        return this
    }
    public func delete(path: String, handlers: Array<Middleware>): Application {
        router.delete(path, handlers);
        return this
    }
    public func patch(path: String, handlers: Array<Middleware>): Application {
        router.patch(path, handlers);
        return this
    }
    public func head(path: String, handlers: Array<Middleware>): Application {
        router.head(path, handlers);
        return this
    }
    public func options(path: String, handlers: Array<Middleware>): Application {
        router.options(path, handlers);
        return this
    }
    public func all(path: String, handlers: Array<Middleware>): Application {
        router.all(path, handlers);
        return this
    }

    // 一次挂载多个全局 / 前缀中间件。
    public func use(handlers: Array<Middleware>): Application {
        router.use(handlers);
        return this
    }
    public func use(path: String, handlers: Array<Middleware>): Application {
        router.use(path, handlers);
        return this
    }

    // 注册参数预处理回调，对应 Express 的 app.param(name, fn)。
    public func param(name: String, handler: ParamHandler): Application {
        router.param(name, handler);
        return this
    }

    private func wrap(handler: Handler): Middleware {
        return {req: HttpRequest, res: HttpResponse, _: Next => handler(req, res)}
    }

    // ---- 路由分组 -----------------------------------------------------------

    // Express 风格的 `app.route(path)`：返回一个绑定了该路径的、可链式调用的
    // Route 对象，从而把同一路径上的多个动词集中注册，避免重复书写路径，例如
    // app.route("/book").get(...).post(...)。
    public func route(path: String): Route {
        return Route(path, router)
    }

    // ---- 挂载子路由 ---------------------------------------------------------

    // 为书写方便而保留的别名方法，语义上完全等价于 `use(prefix, sub)`——即把
    // 子路由挂载到指定前缀下。提供这个名字只是为了让「挂载」意图读起来更直观。
    public func route(prefix: String, sub: Router): Application {
        return use(prefix, sub)
    }

    // ---- 应用设置（字符串键值配置）------------------------------------------

    public func set(key: String, value: String): Application {
        ensureNotFrozen()
        settings[key] = value
        return this
    }

    public func setting(key: String): ?String {
        return settings.get(key)
    }

    // 布尔设置的语法糖(对应 Express 的 app.enable/disable/enabled/disabled):
    // enable/disable 把设置置为 "true"/"false";enabled/disabled 判断其布尔值
    // (未设置视为 false / 未启用)。
    public func enable(key: String): Application {
        ensureNotFrozen()
        settings[key] = "true"
        return this
    }
    public func disable(key: String): Application {
        ensureNotFrozen()
        settings[key] = "false"
        return this
    }
    public func enabled(key: String): Bool {
        match (settings.get(key)) {
            case Some(v) => return v == "true"
            case None => return false
        }
    }
    public func disabled(key: String): Bool {
        return !enabled(key)
    }

    // ---- 请求分发 / 启动服务 ------------------------------------------------

    // 对给定的请求 / 响应跑完整条中间件链。这是真正的请求处理入口:它先把当前
    // Application 关联到请求对象(req.app)上,再交给 router 去匹配并依次执行
    // 中间件与路由。之所以把它设为 public,是为了能在「不真正开启网络套接字」的
    // 情况下直接构造 req/res 来测试整条处理链。
    //
    // **生命周期契约(P0-D)**:每对 (req, res) 只能被 handle **一次**。原因:
    //   1. `req.bodyParsed` / `req.cookiesParsed` 是一次性闸门 — 第二次调用时
    //      ensureBody / ensureCookies 直接跳过,即便 bodyBytes / headers 被替换;
    //   2. `req.res = res` 互相引用 — 第二次 handle 用不同的 res 时,前一次 dispatch
    //      链上未结束的回调读到的 req.res 已被篡改;
    //   3. `res.finished` / `res.headersSent` / `res.hijacked` 是单调标志位,二次
    //      运行不会复位 — 会让响应输出陷入混乱状态。
    //
    // 测试场景里**每条用例都要 new 一对** HttpRequest / HttpResponse,不要复用。
    // 同一个 req 用于"嵌套子派发"(如错误处理 / 视图渲染)由框架内部协调,用户调用
    // app.handle 只该出现在最外层一次。round1 #38 / round3 P3-原P1-3。
    public func handle(req: HttpRequest, res: HttpResponse): Unit {
        req.app = Some(this)
        // 让请求与响应互相持有对方的引用(对应 Express 的 res.req / req.res):
        // sendFile 这类方法据此读取条件请求(If-None-Match)与 Range 头;
        // req.fresh()/req.range() 也据此读取响应上的 ETag / Last-Modified。
        res.req = Some(req)
        req.res = Some(res)
        // 路由设置(case sensitive / strict)由 markFrozen() 在 listen 之前一次性写入
        // router,运行期不再修改 — 避免并发请求路径上的字段写竞争。
        // 未走 listen 的直接 handle(测试场景)下,这里兜底同步一次。
        if (!frozen.load()) {
            router.caseSensitive = enabled("case sensitive routing")
            router.strict = enabled("strict routing")
        }
        router.handle(req, res)
    }

    // 服务器可调参数：在 listen() 构建 HttpServer 时被读取并套用到服务器上。
    // 分别为——单次请求体的最大字节数（默认 1 MiB，超出可用于防止过大请求）、
    // 读取请求的超时毫秒数（默认 15 秒）、以及最大并发连接数（默认 1024）。
    // 这些字段为 var，可在调用 listen() 之前按需修改；listen() 之后再改不会
    // 影响已经构建好的服务器。
    public var maxBodySize: Int64 = 1048576
    public var readTimeoutMs: Int64 = 15000
    public var maxConnections: Int64 = 1024
    // 请求头部块(状态行+全部头)字节上限,默认 64 KiB。独立于 maxBodySize,防止
    // 超大 Cookie 等头部把内存撑爆。
    public var maxHeaderBytes: Int64 = 65536

    // 当前进程内最近一次 listen() 所构建并启动的 HttpServer 引用;close() 据此触发
    // 优雅关闭。listen() 之前为 None,此时 close() 是无操作。
    var httpServer: ?HttpServer = None

    public func listen(port: Int64): Unit {
        let server = buildServer()
        this.httpServer = Some(server)
        markFrozen()
        server.listen(port)
    }

    public func listen(port: Int64, onReady: () -> Unit): Unit {
        let server = buildServer()
        this.httpServer = Some(server)
        markFrozen()
        // 把 onReady 透传给 HttpServer.listen,使其在 bind 成功(端口已可被连接)之后
        // 才触发回调,符合 Express 的 listen(port, cb) 语义。
        server.listen(port, onReady: Some(onReady))
    }

    // 优雅关闭:停止接受新连接,等待在途连接结束当前请求(并断开 keep-alive),
    // 至多等 timeoutMs 毫秒。重复调用幂等;listen() 还未启动时是无操作。
    //
    // 典型用法是在另一协程里调用(主线程 listen 阻塞中):
    //   spawn { app.listen(8080) }
    //   // ... 收到 SIGTERM ...
    //   app.close(timeoutMs: 5000)
    public func close(timeoutMs!: Int64 = 5000): Unit {
        match (this.httpServer) {
            case Some(s) => s.shutdown(timeoutMs: timeoutMs)
            case None => ()
        }
    }

    private func buildServer(): HttpServer {
        let server = HttpServer(this)
        server.maxBodySize = this.maxBodySize
        server.readTimeoutMs = this.readTimeoutMs
        server.maxConnections = this.maxConnections
        server.maxHeaderBytes = this.maxHeaderBytes
        return server
    }
}

// 应用工厂函数，对应 Express 的 `express()`。仅仅是 Application() 的简写，
// 让使用方可以写 `let app = wen()` 这样贴近 Express 习惯的代码来获取应用实例。
public func wen(): Application {
    return Application()
}
