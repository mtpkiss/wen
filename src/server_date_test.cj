package wen

import std.unittest.*
import std.unittest.testmacro.*

// 服务器序列化阶段的 Date 响应头行为。
@Test
class ServerDateTest {
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
