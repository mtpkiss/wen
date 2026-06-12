package wen

/*
 * 绑定到「单一路径」的路由对象，对应 Express 的 `app.route(path)`。
 *
 * 它的价值在于：当同一个路径需要响应多个 HTTP 方法时，不必把路径字符串反复
 * 重写一遍，而是先用 app.route(path) 取得一个绑定了该路径的 Route，再在其上
 * 链式注册各个方法。例如：
 *
 *     app.route("/book")
 *        .get({ req, res => res.send("list") })
 *        .post({ req, res => res.send("create") })
 *
 * 设计要点：每个动词方法（get/post/...）注册完后都返回 `this`（同一个 Route），
 * 因此调用可以连续链式书写。每个动词都提供两个重载——完整的 `Middleware` 形式
 * （带 next）和终结的 `Handler` 形式（不带 next），与 Application 上的同名方法
 * 保持一致，使用习惯完全统一。Route 本身不保存路由表，只是把调用转发给内部的
 * router，真正的注册仍由 Router 完成。
 */
public class Route {
    let path: String
    let router: Router

    init(path: String, router: Router) {
        this.path = path
        this.router = router
    }

    // ---- Middleware 形式（处理器带 next，可决定是否继续向后传递）-------------

    public func get(handler: Middleware): Route { router.get(path, handler); return this }
    public func post(handler: Middleware): Route { router.post(path, handler); return this }
    public func put(handler: Middleware): Route { router.put(path, handler); return this }
    public func delete(handler: Middleware): Route { router.delete(path, handler); return this }
    public func patch(handler: Middleware): Route { router.patch(path, handler); return this }
    public func head(handler: Middleware): Route { router.head(path, handler); return this }
    public func options(handler: Middleware): Route { router.options(path, handler); return this }
    public func all(handler: Middleware): Route { router.all(path, handler); return this }

    // ---- 终结 Handler 形式（不带 next，处理器只负责产出响应）-----------------

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
