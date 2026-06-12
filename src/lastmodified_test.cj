package wen

import std.collection.*
import std.fs.*
import std.unittest.*
import std.unittest.testmacro.*

@Test
class LastModifiedTest {
    // sendFile 会带上 Last-Modified;客户端用 If-Modified-Since 回送同一值再请求
    // 时应得 304。
    @TestCase
    func testIfModifiedSince304(): Unit {
        let path = "._cjx_lm_test.txt"
        File.writeTo(path, "data".toArray())
        let app = wen()
        app.get("/f", { _: HttpRequest, res: HttpResponse => res.sendFile(path) })

        // 首次请求:取回 Last-Modified。
        let r1 = HttpRequest("GET", "/f"); r1.path = "/f"
        let s1 = HttpResponse(); app.handle(r1, s1)
        @Assert(s1.statusCode == 200)
        let lm = match (s1.get("Last-Modified")) { case Some(v) => v; case None => "" }
        @Expect(!lm.isEmpty())
        @Expect(lm.contains("GMT"))

        // 带 If-Modified-Since 再请求:未修改 -> 304。
        let r2 = HttpRequest("GET", "/f"); r2.path = "/f"
        r2.headers["if-modified-since"] = lm
        let s2 = HttpResponse(); app.handle(r2, s2)
        @Assert(s2.statusCode == 304)
        remove(path)
    }

    // HTTP 日期格式形如 "Www, DD Mon YYYY HH:MM:SS GMT"。
    @TestCase
    func testHttpDateShape(): Unit {
        let path = "._cjx_lm_shape.txt"
        File.writeTo(path, "x".toArray())
        match (httpDateForFile(path)) {
            case Some(d) =>
                @Expect(d.endsWith(" GMT"))
                @Expect(d.contains(", "))
                @Expect(d.contains(":"))
            case None => @Assert(false)
        }
        remove(path)
    }
}
