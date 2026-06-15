package wen

import std.collection.*
import std.unittest.*
import std.unittest.testmacro.*

@Test
class HelmetTest {
    func hv(res: HttpResponse, name: String): String {
        match (res.get(name)) { case Some(v) => return v; case None => return "" }
    }

    // 运行一次带 helmet 的请求,返回响应供断言。
    func run(mw: Middleware): HttpResponse {
        let app = wen()
        app.use(mw)
        app.get("/", { _: HttpRequest, res: HttpResponse => res.send("ok") })
        let req = HttpRequest("GET", "/"); req.path = "/"
        let res = HttpResponse(); app.handle(req, res)
        return res
    }

    // 默认配置下应下发预期的安全头。
    @TestCase
    func testDefaults(): Unit {
        let res = run(helmet())
        @Assert(res.body == "ok")
        @Assert(hv(res, "X-Content-Type-Options") == "nosniff")
        @Assert(hv(res, "X-Frame-Options") == "SAMEORIGIN")
        @Assert(hv(res, "Referrer-Policy") == "no-referrer")
        @Expect(hv(res, "Content-Security-Policy").contains("default-src 'self'"))
        @Expect(hv(res, "Strict-Transport-Security").contains("max-age="))
        @Assert(hv(res, "Cross-Origin-Opener-Policy") == "same-origin")
        @Assert(hv(res, "Cross-Origin-Resource-Policy") == "same-origin")
    }

    // hsts: false 时不下发 HSTS 头。
    @TestCase
    func testDisableHsts(): Unit {
        let res = run(helmet(hsts: false))
        @Assert(hv(res, "Strict-Transport-Security") == "")
        // 其它头仍在。
        @Assert(hv(res, "X-Content-Type-Options") == "nosniff")
    }

    // csp 为空串时不下发 CSP 头。
    @TestCase
    func testDisableCsp(): Unit {
        let res = run(helmet(csp: ""))
        @Assert(hv(res, "Content-Security-Policy") == "")
    }

    // 可自定义 X-Frame-Options 与 Referrer-Policy。
    @TestCase
    func testCustomValues(): Unit {
        let res = run(helmet(frameOptions: "DENY", referrerPolicy: "strict-origin"))
        @Assert(hv(res, "X-Frame-Options") == "DENY")
        @Assert(hv(res, "Referrer-Policy") == "strict-origin")
    }

    // noSniff: false 时不下发 X-Content-Type-Options;frameOptions 空串时不下发该头。
    @TestCase
    func testToggleOff(): Unit {
        let res = run(helmet(frameOptions: "", noSniff: false))
        @Assert(hv(res, "X-Content-Type-Options") == "")
        @Assert(hv(res, "X-Frame-Options") == "")
    }
}
