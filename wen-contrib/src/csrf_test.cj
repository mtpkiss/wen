package wen_contrib

import wen.*
import std.time.*
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

    // rotateAfterSeconds 默认 -1(关闭),csrf token 整个会话期复用 — 即使客户端
    // cookie 是裸 token 也照常验证 + 复用,与旧行为完全一致。这条断言锁住"默认关
    // 闭旋转"语义,免得 opt-in 选项的引入误改默认行为。
    @TestCase
    func testCsrfRotateDisabledByDefaultReusesToken(): Unit {
        let secret = "csrf-secret"
        let token = "tok-stable-aabbcc1122"
        let app = wen()
        app.cookieSecret = secret
        app.use(csrf())
        app.get("/form", {
            req: HttpRequest, res: HttpResponse => res.send(req.attribute("csrfToken") ?? "none")
        })
        let req = HttpRequest("GET", "/form")
        req.path = "/form"
        req.headers["cookie"] = "_csrf=${token}.${hmacSha256Hex(secret, token)}"
        let res = HttpResponse()
        app.handle(req, res)
        @Assert(res.statusCode == 200)
        @Assert(res.body == token) // 复用原 token,不重生
        @Assert(res.setCookies.size == 0) // 不重发 cookie
    }

    // rotateAfterSeconds > 0 时,过期 cookie(iat=0,即 1970-01-01)必触发新 token
    // 生成 + 重发 cookie。iat 嵌在 cookie value 中(格式 "${token}@${iat}"),签名整
    // 体仍走 HMAC,防止客户端篡改 iat。模拟"客户端持有的旧 csrf cookie 已远超
    // rotate 窗口"的场景,期望 wen 自动续期。
    @TestCase
    func testCsrfRotatesExpiredToken(): Unit {
        let secret = "csrf-secret"
        let oldToken = "old-token-deadbeef00"
        let app = wen()
        app.cookieSecret = secret
        app.use(csrf(rotateAfterSeconds: 60))
        app.get("/form", {
            req: HttpRequest, res: HttpResponse => res.send(req.attribute("csrfToken") ?? "none")
        })
        // iat=0(1970-01-01)远早于现在 - 60 秒,必触发 rotate。
        let value = "${oldToken}@0"
        let signed = "${value}.${hmacSha256Hex(secret, value)}"
        let req = HttpRequest("GET", "/form")
        req.path = "/form"
        req.headers["cookie"] = "_csrf=${signed}"
        let res = HttpResponse()
        app.handle(req, res)
        @Assert(res.statusCode == 200)
        @Assert(res.body != oldToken) // 已重生
        @Assert(res.setCookies.size > 0) // 重发 cookie
    }

    // rotateAfterSeconds > 0 + cookie 未过期(iat 取当前时间)→ 复用同 token,不重
    // 发 cookie。这条断言确认 rotate 不是"每次请求重发",只在真正过期时触发。
    @TestCase
    func testCsrfDoesNotRotateUnexpiredToken(): Unit {
        let secret = "csrf-secret"
        let token = "tok-fresh-1234567890"
        let app = wen()
        app.cookieSecret = secret
        app.use(csrf(rotateAfterSeconds: 3600))
        app.get("/form", {
            req: HttpRequest, res: HttpResponse => res.send(req.attribute("csrfToken") ?? "none")
        })
        // 当前时间作 iat,远在 1 小时窗口内。
        let nowSec = DateTime.now().toUnixTimeStamp().toSeconds()
        let value = "${token}@${nowSec}"
        let signed = "${value}.${hmacSha256Hex(secret, value)}"
        let req = HttpRequest("GET", "/form")
        req.path = "/form"
        req.headers["cookie"] = "_csrf=${signed}"
        let res = HttpResponse()
        app.handle(req, res)
        @Assert(res.statusCode == 200)
        @Assert(res.body == token) // 复用
        @Assert(res.setCookies.size == 0) // 不重发
    }

    // csrf 中间件在未通过校验时必须立刻 403,不能先去把请求体当 multipart 解析。
    // 如果 csrf 校验依赖 req.attribute(formField) 之类会触发 body 解析的访问器,
    // 攻击者就能用 1 MiB 垃圾 multipart body POST 到任意被 csrf 守的端点,即便最
    // 终 403,框架也已经把整段 multipart 解析掉,白白消耗 CPU 与内存配额。断言
    // 响应是 403 且 req.files 仍为空,确认 csrf 校验阶段没触发 multipart 解析。
    @TestCase
    func testCsrfRejectsBeforeMultipartParse(): Unit {
        let app = wen()
        app.cookieSecret = "the-secret"
        app.use(csrf())
        let body = "--BOUNDARY\r\n" + "Content-Disposition: form-data; name=\"f\"; filename=\"x.bin\"\r\n" +
            "Content-Type: application/octet-stream\r\n\r\n" + "junk\r\n" + "--BOUNDARY--\r\n"
        let req = HttpRequest("POST", "/")
        req.path = "/"
        req.headers["content-type"] = "multipart/form-data; boundary=BOUNDARY"
        req.bodyBytes = body.toArray()
        let res = HttpResponse()
        app.handle(req, res)
        @Assert(res.statusCode == 403)
        @Assert(req.files.size == 0) // multipart 解析未触发
    }
}
