package wen

import std.collection.*

/*
 * 应用对象——相当于 Express 里的 `const app = express()`。
 *
 * 它是整个框架对外的主入口，聚合了路由表、设置项和应用级共享数据，并提供注册
 * 路由 / 中间件 / 插件以及启动服务器的全部方法。
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

    // 签名 Cookie / session 所用的 HMAC 密钥。设为非空后,res.cookie(..., signed: true)
    // 会对值签名、req.signedCookie 会验签;session() 中间件也依赖它来保护 sid。
    // 生产环境请设为足够随机的长字符串,且妥善保管、不要硬编码进版本库。
    public var cookieSecret: String = ""

    // 已注册的视图引擎表:键为扩展名(不含点,如 "html"),值为对应的渲染引擎。
    // 经 app.engine(ext, fn) 注册;res.render 时按模板扩展名在此查找,未注册即抛异常。
    let engines: HashMap<String, ViewEngine> = HashMap<String, ViewEngine>()

    public init() {}

    public func setLocal(key: String, value: Any): Unit {
        locals[key] = value
    }

    public func local(key: String): ?Any {
        return locals.get(key)
    }

    // ---- 中间件 / 插件 -------------------------------------------------------

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
        router.use(path, { req: HttpRequest, res: HttpResponse, next: Next =>
            sub.handleAsMiddleware(req, res, next)
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

    // 注册一个实现了 Plugin 接口的插件。内部直接回调插件的 install 方法，并把
    // 当前 Application 交给它，让插件在安装阶段完成自己的扩展（加路由、加中间件、
    // 改设置等）。返回 this 以便继续链式调用。
    public func register(plugin: Plugin): Application {
        plugin.install(this)
        return this
    }

    // 为某个模板扩展名注册视图引擎,对应 Express 的 app.engine(ext, fn)。扩展名可带
    // 或不带前导点("html" 与 ".html" 等价)。注册后,渲染该扩展名的模板时即用此引擎。
    public func engine(ext: String, fn: ViewEngine): Application {
        engines[normalizeExt(ext)] = fn
        return this
    }

    // 渲染一个视图并返回结果字符串(供 res.render 调用)。流程:
    //   1. 用 "views" 设置(默认 "views")作为视图根目录;
    //   2. 若 name 自带扩展名就用它,否则取 "view engine" 设置作为默认扩展名并补全文件名;
    //   3. 按扩展名查 app.engine(ext, fn) 注册的引擎;没有则抛异常;
    //   4. 交给引擎读取模板文件并渲染。
    func renderView(name: String, data: JsonValue): String {
        let viewsDir = match (this.setting("views")) {
            case Some(v) => v
            case None => "views"
        }
        var fileName = name
        let ext = match (fileExt(name)) {
            case Some(e) => e
            case None =>
                match (this.setting("view engine")) {
                    case Some(e) =>
                        fileName = name + "." + e
                        e
                    case None =>
                        throw Exception("render: 未设置 view engine,且视图名 '${name}' 不含扩展名")
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

    public func get(path: String, handler: Middleware): Application { router.get(path, handler); return this }
    public func post(path: String, handler: Middleware): Application { router.post(path, handler); return this }
    public func put(path: String, handler: Middleware): Application { router.put(path, handler); return this }
    public func delete(path: String, handler: Middleware): Application { router.delete(path, handler); return this }
    public func patch(path: String, handler: Middleware): Application { router.patch(path, handler); return this }
    public func head(path: String, handler: Middleware): Application { router.head(path, handler); return this }
    public func options(path: String, handler: Middleware): Application { router.options(path, handler); return this }
    public func all(path: String, handler: Middleware): Application { router.all(path, handler); return this }

    // ---- 路由注册（终结 Handler 形式：处理器不带 next）-----------------------

    public func get(path: String, handler: Handler): Application { router.get(path, wrap(handler)); return this }
    public func post(path: String, handler: Handler): Application { router.post(path, wrap(handler)); return this }
    public func put(path: String, handler: Handler): Application { router.put(path, wrap(handler)); return this }
    public func delete(path: String, handler: Handler): Application { router.delete(path, wrap(handler)); return this }
    public func patch(path: String, handler: Handler): Application { router.patch(path, wrap(handler)); return this }
    public func head(path: String, handler: Handler): Application { router.head(path, wrap(handler)); return this }
    public func options(path: String, handler: Handler): Application { router.options(path, wrap(handler)); return this }
    public func all(path: String, handler: Handler): Application { router.all(path, wrap(handler)); return this }

    // ---- 路由注册（多处理器形式：同一路径挂多个中间件，按数组顺序执行）-------

    public func get(path: String, handlers: Array<Middleware>): Application { router.get(path, handlers); return this }
    public func post(path: String, handlers: Array<Middleware>): Application { router.post(path, handlers); return this }
    public func put(path: String, handlers: Array<Middleware>): Application { router.put(path, handlers); return this }
    public func delete(path: String, handlers: Array<Middleware>): Application { router.delete(path, handlers); return this }
    public func patch(path: String, handlers: Array<Middleware>): Application { router.patch(path, handlers); return this }
    public func head(path: String, handlers: Array<Middleware>): Application { router.head(path, handlers); return this }
    public func options(path: String, handlers: Array<Middleware>): Application { router.options(path, handlers); return this }
    public func all(path: String, handlers: Array<Middleware>): Application { router.all(path, handlers); return this }

    // 一次挂载多个全局 / 前缀中间件。
    public func use(handlers: Array<Middleware>): Application { router.use(handlers); return this }
    public func use(path: String, handlers: Array<Middleware>): Application { router.use(path, handlers); return this }

    // 注册参数预处理回调，对应 Express 的 app.param(name, fn)。
    public func param(name: String, handler: ParamHandler): Application { router.param(name, handler); return this }

    private func wrap(handler: Handler): Middleware {
        return { req: HttpRequest, res: HttpResponse, _: Next => handler(req, res) }
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
        settings[key] = value
        return this
    }

    public func setting(key: String): ?String {
        return settings.get(key)
    }

    // 布尔设置的语法糖(对应 Express 的 app.enable/disable/enabled/disabled):
    // enable/disable 把设置置为 "true"/"false";enabled/disabled 判断其布尔值
    // (未设置视为 false / 未启用)。
    public func enable(key: String): Application { settings[key] = "true"; return this }
    public func disable(key: String): Application { settings[key] = "false"; return this }
    public func enabled(key: String): Bool {
        match (settings.get(key)) {
            case Some(v) => return v == "true"
            case None => return false
        }
    }
    public func disabled(key: String): Bool { return !enabled(key) }

    // ---- 请求分发 / 启动服务 ------------------------------------------------

    // 对给定的请求 / 响应跑完整条中间件链。这是真正的请求处理入口：它先把当前
    // Application 关联到请求对象（req.app）上，再交给 router 去匹配并依次执行
    // 中间件与路由。之所以把它设为 public，是为了能在「不真正开启网络套接字」的
    // 情况下直接构造 req/res 来测试整条处理链。
    public func handle(req: HttpRequest, res: HttpResponse): Unit {
        req.app = Some(this)
        // 让请求与响应互相持有对方的引用（对应 Express 的 res.req / req.res）：
        // sendFile 这类方法据此读取条件请求（If-None-Match）与 Range 头；
        // req.fresh()/req.range() 也据此读取响应上的 ETag / Last-Modified。
        res.req = Some(req)
        req.res = Some(res)
        // 把 Express 风格的两项路由设置投递到 router(只对顶级 router 生效;嵌套的
        // 子 Router 可独立设置 caseSensitive / strict)。
        router.caseSensitive = enabled("case sensitive routing")
        router.strict = enabled("strict routing")
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

    public func listen(port: Int64): Unit {
        buildServer().listen(port)
    }

    public func listen(port: Int64, onReady: () -> Unit): Unit {
        let server = buildServer()
        onReady()
        server.listen(port)
    }

    private func buildServer(): HttpServer {
        let server = HttpServer(this)
        server.maxBodySize = this.maxBodySize
        server.readTimeoutMs = this.readTimeoutMs
        server.maxConnections = this.maxConnections
        return server
    }
}

// 应用工厂函数，对应 Express 的 `express()`。仅仅是 Application() 的简写，
// 让使用方可以写 `let app = wen()` 这样贴近 Express 习惯的代码来获取应用实例。
public func wen(): Application {
    return Application()
}
