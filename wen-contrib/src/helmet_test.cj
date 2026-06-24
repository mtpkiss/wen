package wen_contrib

import wen.*
import std.collection.*
import std.unittest.*
import std.unittest.testmacro.*

@Test
class HelmetTest {
    func hv(res: HttpResponse, name: String): String {
        match (res.get(name)) {
            case Some(v) => return v;
            case None => return ""
        }
    }

    // 运行一次带 helmet 的请求,返回响应供断言。
    func run(mw: Middleware): HttpResponse {
        let app = wen()
        app.use(mw)
        app.get("/", {_: HttpRequest, res: HttpResponse => res.send("ok")})
        let req = HttpRequest("GET", "/");
        req.path = "/"
        let res = HttpResponse();
        app.handle(req, res)
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

    // 默认 HSTS 串与历史一致:180 天 + includeSubDomains、不带 preload。
    @TestCase
    func testHstsDefaultBackwardsCompatible(): Unit {
        let res = run(helmet())
        @Assert(hv(res, "Strict-Transport-Security") == "max-age=15552000; includeSubDomains")
    }

    // 自定义 max-age 生效;includeSubDomains 默认仍带。
    @TestCase
    func testHstsCustomMaxAge(): Unit {
        let res = run(helmet(hstsMaxAge: 31536000))
        @Assert(hv(res, "Strict-Transport-Security") == "max-age=31536000; includeSubDomains")
    }

    // 生产 preload 标配:1 年 max-age + includeSubDomains + preload。
    @TestCase
    func testHstsPreloadEnabled(): Unit {
        let res = run(helmet(hstsMaxAge: 31536000, hstsPreload: true))
        @Assert(hv(res, "Strict-Transport-Security") == "max-age=31536000; includeSubDomains; preload")
    }

    // includeSubDomains 关闭时该指令不出现;preload 仍可独立控制。
    @TestCase
    func testHstsWithoutIncludeSubDomains(): Unit {
        let res = run(helmet(hstsIncludeSubDomains: false))
        @Assert(hv(res, "Strict-Transport-Security") == "max-age=15552000")
    }

    // 默认应发 `X-XSS-Protection: 0` 关闭浏览器内置的 XSS auditor。Chrome 78 之前
    // 与 Safari 当前仍内置该机制,而该 auditor 本身可作为跨源信息泄露的利用面
    // (Masato Kinugawa 2018 等多次研究证实),helmet.js v3 起默认就是显式发 0。
    // wen 不发的话,等同对站点保留一条遗留漏洞利用面 — 没有理由比同配的 Express
    // 应用更不安全。
    @TestCase
    func testXssProtectionDefaultZero(): Unit {
        let res = run(helmet())
        @Assert(hv(res, "X-XSS-Protection") == "0")
    }

    // 同其他头,xssProtection: false 时不下发该头(给到需要保留旧行为或自己用其
    // 它中间件控制该头的场景一个逃生口)。
    @TestCase
    func testXssProtectionCanBeDisabled(): Unit {
        let res = run(helmet(xssProtection: false))
        @Assert(hv(res, "X-XSS-Protection") == "")
    }
}
