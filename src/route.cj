package wen

/*
 * A single route bound to one path, mirroring Express's `app.route(path)`.
 *
 * Lets you register several HTTP verbs against the same path without repeating
 * it, e.g.
 *
 *     app.route("/book")
 *        .get({ req, res => res.send("list") })
 *        .post({ req, res => res.send("create") })
 *
 * Every verb method returns `this`, so calls chain. Each verb has both a full
 * `Middleware` overload and a terminal `Handler` overload, matching Application.
 */
public class Route {
    let path: String
    let router: Router

    init(path: String, router: Router) {
        this.path = path
        this.router = router
    }

    // ---- Middleware form -----------------------------------------------------

    public func get(handler: Middleware): Route { router.get(path, handler); return this }
    public func post(handler: Middleware): Route { router.post(path, handler); return this }
    public func put(handler: Middleware): Route { router.put(path, handler); return this }
    public func delete(handler: Middleware): Route { router.delete(path, handler); return this }
    public func patch(handler: Middleware): Route { router.patch(path, handler); return this }
    public func head(handler: Middleware): Route { router.head(path, handler); return this }
    public func options(handler: Middleware): Route { router.options(path, handler); return this }
    public func all(handler: Middleware): Route { router.all(path, handler); return this }

    // ---- terminal Handler form (no `next`) ----------------------------------

    public func get(handler: Handler): Route { router.get(path, wrap(handler)); return this }
    public func post(handler: Handler): Route { router.post(path, wrap(handler)); return this }
    public func put(handler: Handler): Route { router.put(path, wrap(handler)); return this }
    public func delete(handler: Handler): Route { router.delete(path, wrap(handler)); return this }
    public func patch(handler: Handler): Route { router.patch(path, wrap(handler)); return this }
    public func head(handler: Handler): Route { router.head(path, wrap(handler)); return this }
    public func options(handler: Handler): Route { router.options(path, wrap(handler)); return this }
    public func all(handler: Handler): Route { router.all(path, wrap(handler)); return this }

    private func wrap(handler: Handler): Middleware {
        return { req: HttpRequest, res: HttpResponse, _: Next => handler(req, res) }
    }
}
