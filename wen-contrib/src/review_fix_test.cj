package wen_contrib

import wen.*
import std.unittest.*
import std.unittest.testmacro.*

/*
 * wen_contrib 一侧的评审修复回归测试。配套 wen-core/src/review_fix_test.cj。
 */
@Test
class ReviewFixContribTest {
    // ============================================================
    // P1-9 CSRF 校验路径不应触发 multipart 解析 — 浪费 CPU/内存,即使最终 403。
    //      验证方式:POST multipart 请求不带 token,断言 csrf 拒后 req.files 为空
    //      (即 multipart 解析未发生)。
    // ============================================================
    @TestCase
    func testP1_9_CsrfRejectsBeforeMultipartParse(): Unit {
        let app = wen()
        app.cookieSecret = "the-secret"
        app.use(csrf())
        let body = "--BOUNDARY\r\n" +
            "Content-Disposition: form-data; name=\"f\"; filename=\"x.bin\"\r\n" +
            "Content-Type: application/octet-stream\r\n\r\n" +
            "junk\r\n" +
            "--BOUNDARY--\r\n"
        let req = HttpRequest("POST", "/")
        req.path = "/"
        req.headers["content-type"] = "multipart/form-data; boundary=BOUNDARY"
        req.bodyBytes = body.toArray()
        let res = HttpResponse()
        app.handle(req, res)
        @Assert(res.statusCode == 403)
        @Assert(req.files.size == 0) // multipart 解析未触发
    }

    // ============================================================
    // P1-10 CORS 选项 reflectRequestHeaders=true 时,把预检的
    //       Access-Control-Request-Headers 原样反射到 Allow-Headers。
    // ============================================================
    @TestCase
    func testP1_10_CorsReflectsAccessControlRequestHeaders(): Unit {
        let app = wen()
        app.use(cors("*", reflectRequestHeaders: true))
        let req = HttpRequest("OPTIONS", "/x")
        req.path = "/x"
        req.headers["origin"] = "https://example.com"
        req.headers["access-control-request-headers"] = "X-Custom-Foo, X-Another"
        let res = HttpResponse()
        app.handle(req, res)
        match (res.get("Access-Control-Allow-Headers")) {
            case Some(v) => @Assert(v.contains("X-Custom-Foo"))
            case None => @Assert(false)
        }
    }

    // ============================================================
    // P2-L 含 CR/LF 的 realm 不应让 401 路径炸成 500。CR/LF/NUL 被替换为 "_"。
    // ============================================================
    @TestCase
    func testP2_L_AuthRealmWithCrLfReplaced(): Unit {
        let app = wen()
        app.use(basicAuth({ _: String, _: String => false }, realm: "evil\r\nrealm"))
        app.get("/", { _: HttpRequest, res: HttpResponse => res.send("hi") })
        let req = HttpRequest("GET", "/")
        req.path = "/"
        let res = HttpResponse()
        app.handle(req, res)
        // 期望:401(由 basicAuth 拒);WWW-Authenticate 头存在且不含 CR/LF。
        @Assert(res.statusCode == 401)
        match (res.get("WWW-Authenticate")) {
            case Some(v) =>
                @Assert(!v.contains("\r"))
                @Assert(!v.contains("\n"))
            case None => @Assert(false)
        }
    }
}
