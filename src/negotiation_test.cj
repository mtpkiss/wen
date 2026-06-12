package wen

import std.collection.*
import std.unittest.*
import std.unittest.testmacro.*

@Test
class NegotiationTest {
    func mk(accept: String): HttpRequest {
        let req = HttpRequest("GET", "/")
        req.headers["accept"] = accept
        return req
    }

    // 没有 Accept 头时,accepts(t) 接受一切。
    @TestCase
    func testNoAcceptHeader(): Unit {
        let req = HttpRequest("GET", "/")
        @Assert(req.accepts("json"))
        @Assert(req.accepts("html"))
    }

    // q=0 表示明确拒绝该类型。
    @TestCase
    func testQZeroRejects(): Unit {
        let req = mk("application/json;q=0")
        @Assert(!req.accepts("json"))
    }

    // 不在 Accept 列表中的类型不被接受。
    @TestCase
    func testUnlistedRejected(): Unit {
        let req = mk("text/html, application/json")
        @Assert(req.accepts("html"))
        @Assert(req.accepts("json"))
        @Assert(!req.accepts("css"))
    }

    // 通配 */* 接受任何类型。
    @TestCase
    func testWildcardAccepts(): Unit {
        let req = mk("*/*")
        @Assert(req.accepts("css"))
        @Assert(req.accepts("json"))
    }

    // accepts([...]) 按 q 值选最佳:html 的 q 更高则胜出。
    @TestCase
    func testBestByQuality(): Unit {
        let req = mk("text/html;q=0.9, application/json;q=0.8")
        match (req.accepts(["json", "html"])) {
            case Some(t) => @Assert(t == "html")
            case None => @Assert(false)
        }
    }

    // q 相同时,按客户端 Accept 头中的先后(更靠前者更受偏好)。
    @TestCase
    func testTieByClientOrder(): Unit {
        let req = mk("application/json, text/html")
        // 两者 q 都为 1,但 json 在 Accept 中更靠前 -> 选 json,即便候选数组把 html 放前面。
        match (req.accepts(["html", "json"])) {
            case Some(t) => @Assert(t == "json")
            case None => @Assert(false)
        }
    }

    // 没有任何候选被接受时返回 None。
    @TestCase
    func testNoneAcceptable(): Unit {
        let req = mk("text/plain")
        match (req.accepts(["json", "html"])) {
            case Some(_) => @Assert(false)
            case None => @Expect(true)
        }
    }

    // 缺少 Accept 头时,accepts([...]) 返回候选中的第一个。
    @TestCase
    func testNoHeaderReturnsFirst(): Unit {
        let req = HttpRequest("GET", "/")
        match (req.accepts(["json", "html"])) {
            case Some(t) => @Assert(t == "json")
            case None => @Assert(false)
        }
    }

    // res.format 依据 Accept 选用对应回调,并设置 Content-Type 与 Vary。
    @TestCase
    func testResFormatPicksJson(): Unit {
        let app = wen()
        app.get("/data", { _: HttpRequest, res: HttpResponse =>
            res.format([
                ("html", { => res.send("<p>hi</p>") }),
                ("json", { => res.json("{\"hi\":true}") })
            ])
        })
        let req = HttpRequest("GET", "/data"); req.path = "/data"
        req.headers["accept"] = "application/json"
        let res = HttpResponse(); app.handle(req, res)
        @Assert(res.body == "{\"hi\":true}")
        let ct = match (res.headers.get("Content-Type")) { case Some(v) => v; case None => "" }
        @Expect(ct.contains("application/json"))
        let vary = match (res.headers.get("Vary")) { case Some(v) => v; case None => "" }
        @Expect(vary.contains("Accept"))
    }

    // res.format 在无可接受类型且无 default 时回 406。
    @TestCase
    func testResFormat406(): Unit {
        let app = wen()
        app.get("/data", { _: HttpRequest, res: HttpResponse =>
            res.format([
                ("html", { => res.send("<p>hi</p>") }),
                ("json", { => res.json("{}") })
            ])
        })
        let req = HttpRequest("GET", "/data"); req.path = "/data"
        req.headers["accept"] = "text/plain"
        let res = HttpResponse(); app.handle(req, res)
        @Assert(res.statusCode == 406)
    }

    // res.format 的 "default" 条目作为兜底。
    @TestCase
    func testResFormatDefault(): Unit {
        let app = wen()
        app.get("/data", { _: HttpRequest, res: HttpResponse =>
            res.format([
                ("json", { => res.json("{}") }),
                ("default", { => res.send("fallback") })
            ])
        })
        let req = HttpRequest("GET", "/data"); req.path = "/data"
        req.headers["accept"] = "text/plain"
        let res = HttpResponse(); app.handle(req, res)
        @Assert(res.body == "fallback")
    }
}
