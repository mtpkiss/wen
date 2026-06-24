package wen

import std.unittest.*
import std.unittest.testmacro.*

@Test
class ExtrasTest {
    func hv(res: HttpResponse, name: String): String {
        match (res.get(name)) {
            case Some(v) => return v;
            case None => return ""
        }
    }

    // res.vary 追加且去重。
    @TestCase
    func testVary(): Unit {
        let res = HttpResponse()
        res.vary("Accept")
        res.vary("Accept-Encoding")
        res.vary("accept") // 大小写不敏感,不重复
        @Assert(hv(res, "Vary") == "Accept, Accept-Encoding")
    }

    // redirect 带状态码。
    @TestCase
    func testRedirectStatus(): Unit {
        let res = HttpResponse()
        res.redirect(301, "/new")
        @Assert(res.statusCode == 301)
        @Assert(hv(res, "Location") == "/new")
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

    // res.send 已结束响应(finished=true)后,业务代码若仍调 res.status(500) 改状
    // 态码,这种"状态码与正文不匹配"的写错通常说明上游中间件链有 bug。框架在
    // finished 后默默吞掉 status / cookie / redirect / send / sendBytes 这类
    // 改语义的接口,且发 stderr 警告 — 既不破坏已发出的响应,也让 bug 浮现。
    // 断言状态码不被覆盖。
    @TestCase
    func testStatusAfterFinishedIsNoop(): Unit {
        let res = HttpResponse()
        res.send("ok") // finished=true
        let savedStatus = res.statusCode
        res.status(500)
        @Assert(res.statusCode == savedStatus)
    }

    // 与 status 不同,res.set 在 finished 之后必须仍然生效:server 序列化阶段需要
    // 在 finished=true 之后写入 Date、自动 Content-Length、charset 这类系统级头。
    // 如果 set 也在 finished 后被屏蔽,这些自动头就再也写不进去了。这条断言锁住
    // "改语义的接口屏蔽、改头的接口放行"这条边界:finished 后调 set 仍能成功
    // 写头。
    @TestCase
    func testSetAfterFinishedAllowed(): Unit {
        let res = HttpResponse()
        res.send("ok")
        res.set("X-Late", "v")
        match (res.get("X-Late")) {
            case Some(v) => @Assert(v == "v")
            case None => @Assert(false)
        }
    }

    // res.cookie 的 value 若含 cookie-octet 范围外的字符(分号、空格、逗号、双引号、
    // 反斜杠、控制字符),会让攻击者注入 cookie attribute:用户代码
    // `res.cookie("u", req.queryParam("name") ?? "")` 若把外部输入直接当 value,
    // 攻击者把 name 设成 "xxx; Domain=evil.com",生成的 Set-Cookie 就变成
    // `u=xxx; Domain=evil.com; Path=/`,浏览器接受 Domain 后把该 cookie 跨域投递。
    // RFC 6265 §4.1.1 cookie-octet 范围:0x21、0x23–0x2B、0x2D–0x3A、0x3C–0x5B、
    // 0x5D–0x7E(明确排除 SP、DQUOTE、","、";"、"\")。校验应该在 res.cookie 入口
    // 直接拒(抛异常),由调用方显式处理。
    @TestCase
    func testCookieValueRejectsAttributeInjection(): Unit {
        let res = HttpResponse()
        var caught = false
        try {
            res.cookie("u", "xxx; Domain=evil.com")
        } catch (_: Exception) {
            caught = true
        }
        @Assert(caught)
        // 即便没抛异常,也应该不允许把恶意 Domain 拼进 Set-Cookie 头。
        if (!caught && res.setCookies.size > 0) {
            @Assert(!res.setCookies[0].contains("Domain=evil.com"))
        }
    }

    // 同上,空格也属 cookie-octet 范围外字符 — 一旦放行,攻击者就能用空格分隔
    // 自己拼出来的额外属性。校验应当一并拒。
    @TestCase
    func testCookieValueRejectsSpace(): Unit {
        let res = HttpResponse()
        var caught = false
        try {
            res.cookie("u", "abc def")
        } catch (_: Exception) {
            caught = true
        }
        @Assert(caught)
    }
}
