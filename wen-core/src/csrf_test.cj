package wen

import std.unittest.*
import std.unittest.testmacro.*

@Test
class CsrfTest {
    // 安全方法(GET)放行,并把 token 暴露到 req.attribute("csrfToken")。
    @TestCase
    func testGetExposesToken(): Unit {
        let app = wen()
        app.cookieSecret = "csrf-secret"
        app.use(csrf())
        app.get("/form", {
            req: HttpRequest, res: HttpResponse => res.send(req.attribute("csrfToken") ?? "none")
        })
        let req = HttpRequest("GET", "/form");
        req.path = "/form"
        let res = HttpResponse();
        app.handle(req, res)
        @Assert(res.statusCode == 200)
        @Expect(!res.body.isEmpty())
        @Assert(res.body != "none")
    }

    // 带正确签名 Cookie + 匹配的 X-CSRF-Token 头的 POST -> 放行。
    @TestCase
    func testValidHeaderTokenPasses(): Unit {
        let secret = "csrf-secret"
        let token = "tok-abcdef123456"
        let app = wen()
        app.cookieSecret = secret
        app.use(csrf())
        app.post("/save", {_: HttpRequest, res: HttpResponse => res.send("saved")})
        let req = HttpRequest("POST", "/save");
        req.path = "/save"
        req.headers["cookie"] = "_csrf=${token}.${hmacSha256Hex(secret, token)}"
        req.headers["x-csrf-token"] = token
        let res = HttpResponse();
        app.handle(req, res)
        @Assert(res.statusCode == 200)
        @Assert(res.body == "saved")
    }

    // 表单字段回传 token 也被接受。
    @TestCase
    func testValidFormFieldTokenPasses(): Unit {
        let secret = "csrf-secret"
        let token = "form-token-123456"
        let app = wen()
        app.cookieSecret = secret
        app.use(csrf())
        app.post("/save", {_: HttpRequest, res: HttpResponse => res.send("saved")})
        let req = HttpRequest("POST", "/save");
        req.path = "/save"
        req.headers["cookie"] = "_csrf=${token}.${hmacSha256Hex(secret, token)}"
        req.headers["content-type"] = "application/x-www-form-urlencoded"
        req.body = "_csrf=${token}&data=1"
        let res = HttpResponse();
        app.handle(req, res)
        @Assert(res.statusCode == 200)
        @Assert(res.body == "saved")
    }

    // 缺失回传 token 的 POST -> 403。
    @TestCase
    func testMissingTokenRejected(): Unit {
        let app = wen()
        app.cookieSecret = "csrf-secret"
        app.use(csrf())
        app.post("/save", {_: HttpRequest, res: HttpResponse => res.send("saved")})
        let req = HttpRequest("POST", "/save");
        req.path = "/save"
        let res = HttpResponse();
        app.handle(req, res)
        @Assert(res.statusCode == 403)
    }

    // Cookie 里的 token 与回传 token 不一致 -> 403。
    @TestCase
    func testMismatchedTokenRejected(): Unit {
        let secret = "csrf-secret"
        let token = "real-token-xyz789"
        let app = wen()
        app.cookieSecret = secret
        app.use(csrf())
        app.post("/save", {_: HttpRequest, res: HttpResponse => res.send("saved")})
        let req = HttpRequest("POST", "/save");
        req.path = "/save"
        req.headers["cookie"] = "_csrf=${token}.${hmacSha256Hex(secret, token)}"
        req.headers["x-csrf-token"] = "wrong-token"
        let res = HttpResponse();
        app.handle(req, res)
        @Assert(res.statusCode == 403)
    }

    // 篡改的签名 Cookie(签名对不上)-> 无有效 token,POST 被拒 403。
    @TestCase
    func testTamperedCookieRejected(): Unit {
        let token = "real-token-abc123"
        let app = wen()
        app.cookieSecret = "csrf-secret"
        app.use(csrf())
        app.post("/save", {_: HttpRequest, res: HttpResponse => res.send("saved")})
        let req = HttpRequest("POST", "/save");
        req.path = "/save"
        // 用错误的签名段:验签失败,signedCookie 返回 None。
        req.headers["cookie"] = "_csrf=${token}.deadbeefbadsig"
        req.headers["x-csrf-token"] = token
        let res = HttpResponse();
        app.handle(req, res)
        @Assert(res.statusCode == 403)
    }
}
