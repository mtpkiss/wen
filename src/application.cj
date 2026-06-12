package wen

import std.collection.*

/*
 * The application object — the analogue of `const app = express()`.
 *
 * Route/middleware registration is chainable. Handlers may be supplied either
 * as a full `Middleware` ((req, res, next)) or as a terminal `Handler`
 * ((req, res)); the terminal form is wrapped automatically.
 */
public class Application {
    let router: Router = Router()
    let settings: HashMap<String, String> = HashMap<String, String>()

    // App-scoped typed store, shared across all requests (Express's app.locals):
    // a place for config objects, shared services, etc.
    public let locals: HashMap<String, Any> = HashMap<String, Any>()

    public init() {}

    public func setLocal(key: String, value: Any): Unit {
        locals[key] = value
    }

    public func local(key: String): ?Any {
        return locals.get(key)
    }

    // ---- middleware / plugins ------------------------------------------------

    public func use(handler: Middleware): Application {
        router.use(handler)
        return this
    }

    public func use(path: String, handler: Middleware): Application {
        router.use(path, handler)
        return this
    }

    // Mount a sub-router as a "mini-app" under `path`, mirroring Express's
    // `app.use('/birds', router)`. The sub-router runs its own middleware and
    // routes against the request path with `path` stripped; any params the
    // mount path captures (e.g. /birds/:type) stay on the shared request, so
    // sub-routes can read them (effectively mergeParams: true).
    public func use(path: String, sub: Router): Application {
        router.use(path, { req: HttpRequest, res: HttpResponse, next: Next =>
            sub.handleAsMiddleware(req, res, next)
        })
        return this
    }

    // Register an error-handling middleware (err, req, res, next). Register it
    // after the routes whose errors it should catch, mirroring Express.
    public func use(handler: ErrorHandler): Application {
        router.useError(handler)
        return this
    }

    // Register a Plugin implementation.
    public func register(plugin: Plugin): Application {
        plugin.install(this)
        return this
    }

    // ---- routes (Middleware form) -------------------------------------------

    public func get(path: String, handler: Middleware): Application { router.get(path, handler); return this }
    public func post(path: String, handler: Middleware): Application { router.post(path, handler); return this }
    public func put(path: String, handler: Middleware): Application { router.put(path, handler); return this }
    public func delete(path: String, handler: Middleware): Application { router.delete(path, handler); return this }
    public func patch(path: String, handler: Middleware): Application { router.patch(path, handler); return this }
    public func head(path: String, handler: Middleware): Application { router.head(path, handler); return this }
    public func options(path: String, handler: Middleware): Application { router.options(path, handler); return this }
    public func all(path: String, handler: Middleware): Application { router.all(path, handler); return this }

    // ---- routes (terminal Handler form, no `next`) --------------------------

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

    // ---- route grouping -----------------------------------------------------

    // Express-style `app.route(path)`: bind several verbs to one path via a
    // chainable Route, e.g. app.route("/book").get(...).post(...).
    public func route(path: String): Route {
        return Route(path, router)
    }

    // ---- mounting sub-routers -----------------------------------------------

    // Kept for convenience; equivalent to `use(prefix, sub)`.
    public func route(prefix: String, sub: Router): Application {
        return use(prefix, sub)
    }

    // ---- settings -----------------------------------------------------------

    public func set(key: String, value: String): Application {
        settings[key] = value
        return this
    }

    public func setting(key: String): ?String {
        return settings.get(key)
    }

    // ---- dispatch / serving -------------------------------------------------

    // Run the full middleware chain. Exposed for testing without a socket.
    public func handle(req: HttpRequest, res: HttpResponse): Unit {
        req.app = Some(this)
        router.handle(req, res)
    }

    // Server tunables applied when listen() builds the HttpServer.
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

// Application factory, the analogue of Express's `express()`.
public func wen(): Application {
    return Application()
}
