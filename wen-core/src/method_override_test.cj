package wen

import std.unittest.*
import std.unittest.testmacro.*

@Test
class MethodOverrideTest {
    // 头部重写:POST + X-HTTP-Method-Override: DELETE -> 命中 DELETE 路由,原方法记入 originalMethod。
    @TestCase
    func testHeaderOverride(): Unit {
        let app = wen()
        app.use(methodOverride())
        app.delete("/items/:id", {
            req: HttpRequest, res: HttpResponse =>
                let om = req.attribute("originalMethod") ?? "?"
                res.send("deleted ${req.param("id") ?? "?"} (was ${om})")
        })
        let req = HttpRequest("POST", "/items/7");
        req.path = "/items/7"
        req.headers["x-http-method-override"] = "DELETE"
        let res = HttpResponse();
        app.handle(req, res)
        @Assert(res.statusCode == 200)
        @Assert(res.body == "deleted 7 (was POST)")
    }

    // 头值含多个时取第一个;小写也能归一。
    @TestCase
    func testHeaderFirstTokenAndCase(): Unit {
        let app = wen()
        app.use(methodOverride())
        app.put("/p", {_: HttpRequest, res: HttpResponse => res.send("put-ok")})
        let req = HttpRequest("POST", "/p");
        req.path = "/p"
        req.headers["x-http-method-override"] = "put, get"
        let res = HttpResponse();
        app.handle(req, res)
        @Assert(res.body == "put-ok")
    }

    // 表单字段重写:POST + body _method=put -> 命中 PUT 路由。
    @TestCase
    func testFieldOverride(): Unit {
        let app = wen()
        app.use(methodOverrideField())
        app.put("/p", {_: HttpRequest, res: HttpResponse => res.send("put-ok")})
        let req = HttpRequest("POST", "/p");
        req.path = "/p"
        req.headers["content-type"] = "application/x-www-form-urlencoded"
        req.body = "_method=put&x=1"
        let res = HttpResponse();
        app.handle(req, res)
        @Assert(res.body == "put-ok")
    }

    // 查询串重写:POST + ?_method=PATCH -> 命中 PATCH 路由。
    // 直接构造 HttpRequest 不会自动解析 URL 上的 query(那由 server 完成),
    // 这里按测试惯例(参见 url_headers_test.cj)显式塞入 query 字典。
    @TestCase
    func testQueryOverride(): Unit {
        let app = wen()
        app.use(methodOverrideField())
        app.patch("/q", {_: HttpRequest, res: HttpResponse => res.send("patched")})
        let req = HttpRequest("POST", "/q?_method=PATCH");
        req.path = "/q"
        req.query["_method"] = "PATCH"
        let res = HttpResponse();
        app.handle(req, res)
        @Assert(res.body == "patched")
    }

    // 非 POST 不被重写:GET + 头 -> 仍命中 GET(重写仅对 POST 生效)。
    @TestCase
    func testOnlyPostOverridden(): Unit {
        let app = wen()
        app.use(methodOverride())
        app.get("/g", {_: HttpRequest, res: HttpResponse => res.send("got")})
        app.delete("/g", {_: HttpRequest, res: HttpResponse => res.send("deleted")})
        let req = HttpRequest("GET", "/g");
        req.path = "/g"
        req.headers["x-http-method-override"] = "DELETE"
        let res = HttpResponse();
        app.handle(req, res)
        @Assert(res.body == "got")
    }

    // 未知方法被忽略:POST + 头=BOGUS -> 不改写,仍按 POST 处理。
    @TestCase
    func testUnknownMethodIgnored(): Unit {
        let app = wen()
        app.use(methodOverride())
        app.post("/x", {_: HttpRequest, res: HttpResponse => res.send("posted")})
        let req = HttpRequest("POST", "/x");
        req.path = "/x"
        req.headers["x-http-method-override"] = "BOGUS"
        let res = HttpResponse();
        app.handle(req, res)
        @Assert(res.body == "posted")
    }
}
