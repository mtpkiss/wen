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

    // 默认配置:只发「部署无关、不会误伤」的头;策略类头(CSP / COOP / CORP)默认不发。
    @TestCase
    func testDefaults(): Unit {
        let res = run(helmet())
        @Assert(res.body == "ok")
        // 默认开。
        @Assert(hv(res, "X-Content-Type-Options") == "nosniff")
        @Assert(hv(res, "X-Frame-Options") == "SAMEORIGIN")
        @Assert(hv(res, "Referrer-Policy") == "no-referrer")
        @Expect(hv(res, "Strict-Transport-Security").contains("max-age="))
        // 默认关(易误伤,需显式传值)。
        @Assert(hv(res, "Content-Security-Policy") == "")
        @Assert(hv(res, "Cross-Origin-Opener-Policy") == "")
        @Assert(hv(res, "Cross-Origin-Resource-Policy") == "")
    }

    // 策略类头需显式开启:传入即下发对应值。
    @TestCase
    func testOptInPolicies(): Unit {
        let res = run(helmet(csp: "default-src 'self'", coop: "same-origin", corp: "same-origin"))
        @Assert(hv(res, "Content-Security-Policy") == "default-src 'self'")
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
