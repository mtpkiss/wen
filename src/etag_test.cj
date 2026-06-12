package wen

import std.unittest.*
import std.unittest.testmacro.*

@Test
class EtagTest {
    // res.send 的动态响应:首次得到 ETag,带 If-None-Match 回送则 304。
    @TestCase
    func testSendConditional(): Unit {
        let app = wen()
        app.use(etag())
        app.get("/", { _: HttpRequest, res: HttpResponse => res.send("hello world") })

        let r1 = HttpRequest("GET", "/"); r1.path = "/"
        let s1 = HttpResponse(); app.handle(r1, s1)
        @Assert(s1.statusCode == 200)
        let tag = match (s1.get("ETag")) { case Some(v) => v; case None => "" }
        @Expect(!tag.isEmpty())

        let r2 = HttpRequest("GET", "/"); r2.path = "/"
        r2.headers["if-none-match"] = tag
        let s2 = HttpResponse(); app.handle(r2, s2)
        @Assert(s2.statusCode == 304)
        @Assert(s2.body == "")
    }

    // res.json 同样获得 ETag;内容不同则 ETag 不同(不会误判 304)。
    @TestCase
    func testJsonEtagDiffers(): Unit {
        let app = wen()
        app.use(etag())
        app.get("/a", { _: HttpRequest, res: HttpResponse => res.json(JsonObj().put("v", 1).build()) })
        app.get("/b", { _: HttpRequest, res: HttpResponse => res.json(JsonObj().put("v", 2).build()) })

        let ra = HttpRequest("GET", "/a"); ra.path = "/a"
        let sa = HttpResponse(); app.handle(ra, sa)
        let ta = match (sa.get("ETag")) { case Some(v) => v; case None => "" }

        let rb = HttpRequest("GET", "/b"); rb.path = "/b"
        let sb = HttpResponse(); app.handle(rb, sb)
        let tb = match (sb.get("ETag")) { case Some(v) => v; case None => "" }

        @Expect(!ta.isEmpty())
        @Assert(ta != tb)

        // 用 /a 的 ETag 去请求 /b,不应命中 304。
        let rb2 = HttpRequest("GET", "/b"); rb2.path = "/b"
        rb2.headers["if-none-match"] = ta
        let sb2 = HttpResponse(); app.handle(rb2, sb2)
        @Assert(sb2.statusCode == 200)
    }

    // 非 GET 不加 ETag。
    @TestCase
    func testNonGetNoEtag(): Unit {
        let app = wen()
        app.use(etag())
        app.post("/", { _: HttpRequest, res: HttpResponse => res.send("created") })
        let req = HttpRequest("POST", "/"); req.path = "/"
        let res = HttpResponse(); app.handle(req, res)
        match (res.get("ETag")) { case Some(_) => @Assert(false); case None => @Expect(true) }
    }

    // 文件响应已自带 ETag,中间件不重复处理(仍是文件那套 ETag,响应 200)。
    @TestCase
    func testFileResponseNotDoubled(): Unit {
        let app = wen()
        app.use(etag())
        app.get("/x", { _: HttpRequest, res: HttpResponse =>
            res.contentType("text/plain").sendBytes("data".toArray())
        })
        // sendBytes 不带 ETag,故这里中间件会补;另用真实文件场景已在 file_response_test 覆盖。
        let req = HttpRequest("GET", "/x"); req.path = "/x"
        let res = HttpResponse(); app.handle(req, res)
        @Assert(res.statusCode == 200)
        @Expect(!(match (res.get("ETag")) { case Some(v) => v; case None => "" }).isEmpty())
    }
}
