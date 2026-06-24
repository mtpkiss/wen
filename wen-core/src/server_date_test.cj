package wen

import std.time.*
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

    // formatHttpDate 输出的 HTTP 日期串必须用固定的 ASCII 三字母月份/星期缩写
    // ("Jan"、"Mon"),不依赖 std 的本地化字符串。否则切到非英语 locale 后,
    // If-Modified-Since 等条件请求会因为日期字符串不对齐而全部 cache miss,缓存
    // 校验彻底失效。这里用一个已知日期(2026-01-01)断言输出含 "Jan" 且以 "GMT"
    // 结尾。
    @TestCase
    func testFormatHttpDateAsciiAbbrev(): Unit {
        let t = DateTime.of(year: 2026, month: Month.January, dayOfMonth: 1, hour: 0, minute: 0, second: 0)
        let s = formatHttpDate(t)
        @Assert(s.contains("Jan"))
        @Assert(s.contains("2026"))
        @Assert(s.endsWith("GMT"))
    }
}
