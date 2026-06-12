package wen

import std.collection.*
import std.unittest.*
import std.unittest.testmacro.*

@Test
class ExtrasTest {
    func hv(res: HttpResponse, name: String): String {
        match (res.get(name)) { case Some(v) => return v; case None => return "" }
    }

    // res.vary 追加且去重。
    @TestCase
    func testVary(): Unit {
        let res = HttpResponse()
        res.vary("Accept")
        res.vary("Accept-Encoding")
        res.vary("accept")                 // 大小写不敏感,不重复
        @Assert(hv(res, "Vary") == "Accept, Accept-Encoding")
    }

    // res.links 生成 Link 头。
    @TestCase
    func testLinks(): Unit {
        let res = HttpResponse()
        res.links([("next", "/p/2"), ("last", "/p/9")])
        @Assert(hv(res, "Link") == "</p/2>; rel=\"next\", </p/9>; rel=\"last\"")
    }

    // redirect 带状态码。
    @TestCase
    func testRedirectStatus(): Unit {
        let res = HttpResponse()
        res.redirect(301, "/new")
        @Assert(res.statusCode == 301)
        @Assert(hv(res, "Location") == "/new")
    }

    // jsonp:带合法 callback -> application/javascript 包裹;非法/缺失 -> 普通 JSON。
    @TestCase
    func testJsonp(): Unit {
        let app = wen()
        app.get("/data", { _: HttpRequest, res: HttpResponse => res.jsonp("{\"v\":1}") })

        // 合法 callback。
        let r1 = HttpRequest("GET", "/data?callback=cb"); r1.path = "/data"
        parseQuery("callback=cb", r1.query)
        let s1 = HttpResponse(); app.handle(r1, s1)
        @Expect(hv(s1, "Content-Type").contains("application/javascript"))
        @Expect(s1.body.contains("cb({\"v\":1})"))

        // 非法 callback -> 退化为 JSON。
        let r2 = HttpRequest("GET", "/data"); r2.path = "/data"
        parseQuery("callback=bad)(", r2.query)
        let s2 = HttpResponse(); app.handle(r2, s2)
        @Expect(hv(s2, "Content-Type").contains("application/json"))
        @Assert(s2.body == "{\"v\":1}")
    }

    // app.enable/disable/enabled/disabled。
    @TestCase
    func testEnableDisable(): Unit {
        let app = wen()
        app.enable("trust proxy")
        @Assert(app.enabled("trust proxy"))
        @Assert(!app.disabled("trust proxy"))
        app.disable("trust proxy")
        @Assert(!app.enabled("trust proxy"))
        @Assert(app.disabled("trust proxy"))
        // 未设置的键视为未启用。
        @Assert(!app.enabled("never set"))
        @Assert(app.disabled("never set"))
    }
}
