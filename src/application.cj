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

    // ---- 请求分发 / 启动服务 ------------------------------------------------

    // 对给定的请求 / 响应跑完整条中间件链。这是真正的请求处理入口：它先把当前
    // Application 关联到请求对象（req.app）上，再交给 router 去匹配并依次执行
    // 中间件与路由。之所以把它设为 public，是为了能在「不真正开启网络套接字」的
    // 情况下直接构造 req/res 来测试整条处理链。
    public func handle(req: HttpRequest, res: HttpResponse): Unit {
        req.app = Some(this)
        // 让响应持有对本次请求的引用（对应 Express 的 res.req），这样像
        // sendFile 这类方法才能读取条件请求（If-None-Match）与 Range 等请求头。
        res.req = Some(req)
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
