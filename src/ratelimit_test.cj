package wen

import std.unittest.*
import std.unittest.testmacro.*

@Test
class RateLimitTest {
    // 限额内放行,超出回 429,并带 Retry-After 与 X-RateLimit-* 头。
    @TestCase
    func testLimitAndBlock(): Unit {
        let app = wen()
        app.use(rateLimit(max: 2, windowSeconds: 60))
        app.get("/", { _: HttpRequest, res: HttpResponse => res.send("ok") })

        func hit(): HttpResponse {
            let req = HttpRequest("GET", "/"); req.path = "/"
            let res = HttpResponse(); app.handle(req, res)
            return res
        }

        // 同一 key(测试里 clientIp 为空串,大家共用一个桶)。
        let s1 = hit()
        @Assert(s1.statusCode == 200)
        let rem1 = match (s1.get("X-RateLimit-Remaining")) { case Some(v) => v; case None => "" }
        @Assert(rem1 == "1")

        let s2 = hit()
        @Assert(s2.statusCode == 200)
        @Assert((match (s2.get("X-RateLimit-Remaining")) { case Some(v) => v; case None => "" }) == "0")

        // 第三次超额 -> 429。
        let s3 = hit()
        @Assert(s3.statusCode == 429)
        @Assert(s3.body == "Too Many Requests")
        @Expect(!(match (s3.get("Retry-After")) { case Some(v) => v; case None => "" }).isEmpty())
        let limit = match (s3.get("X-RateLimit-Limit")) { case Some(v) => v; case None => "" }
        @Assert(limit == "2")
    }

    // 序列化时会补上 Date 响应头(RFC 1123 HTTP 日期,带 GMT)。
    @TestCase
    func testDateHeader(): Unit {
        let server = HttpServer(wen())
        let res = HttpResponse()
        res.send("hi")
        let text = String.fromUtf8(server.serializeResponse(res))
        @Expect(text.contains("Date: "))
        @Expect(text.contains("GMT"))
    }

    // 若处理器已自行设置 Date,则不覆盖。
    @TestCase
    func testDateNotOverwritten(): Unit {
        let server = HttpServer(wen())
        let res = HttpResponse()
        res.set("Date", "Mon, 01 Jan 1990 00:00:00 GMT")
        res.send("hi")
        let text = String.fromUtf8(server.serializeResponse(res))
        @Expect(text.contains("Mon, 01 Jan 1990 00:00:00 GMT"))
    }
}
