package wen

import std.unittest.*
import std.unittest.testmacro.*

@Test
class AuthTest {
    // base64 编解码往返。
    @TestCase
    func testBase64RoundTrip(): Unit {
        @Assert(base64Encode("admin:secret".toArray()) == "YWRtaW46c2VjcmV0")
        @Assert(String.fromUtf8(base64Decode("YWRtaW46c2VjcmV0")) == "admin:secret")
        @Assert(String.fromUtf8(base64Decode(base64Encode("你好 hi".toArray()))) == "你好 hi")
    }

    // Basic 认证:正确凭据放行并设 authUser;错误/缺失回 401 + WWW-Authenticate。
    @TestCase
    func testBasicAuth(): Unit {
        let app = wen()
        app.get("/secret", [
            basicAuth({ u: String, p: String => u == "admin" && p == "secret" }),
            { req: HttpRequest, res: HttpResponse, _: Next =>
                let who = match (req.attribute("authUser")) { case Some(v) => v; case None => "?" }
                res.send("hi ${who}")
            }
        ])

        // 缺凭据 -> 401。
        let r0 = HttpRequest("GET", "/secret"); r0.path = "/secret"
        let s0 = HttpResponse(); app.handle(r0, s0)
        @Assert(s0.statusCode == 401)
        @Expect((match (s0.get("WWW-Authenticate")) { case Some(v) => v; case None => "" }).contains("Basic"))

        // 正确凭据 -> 200。
        let r1 = HttpRequest("GET", "/secret"); r1.path = "/secret"
        r1.headers["authorization"] = "Basic " + base64Encode("admin:secret".toArray())
        let s1 = HttpResponse(); app.handle(r1, s1)
        @Assert(s1.statusCode == 200)
        @Assert(s1.body == "hi admin")

        // 错误密码 -> 401。
        let r2 = HttpRequest("GET", "/secret"); r2.path = "/secret"
        r2.headers["authorization"] = "Basic " + base64Encode("admin:wrong".toArray())
        let s2 = HttpResponse(); app.handle(r2, s2)
        @Assert(s2.statusCode == 401)
    }

    // Bearer 认证:有效 token 放行;无效/缺失回 401。
    @TestCase
    func testBearerAuth(): Unit {
        let app = wen()
        app.get("/api", [
            bearerAuth({ t: String => t == "good-token" }),
            { _: HttpRequest, res: HttpResponse, _: Next => res.send("ok") }
        ])

        let r1 = HttpRequest("GET", "/api"); r1.path = "/api"
        r1.headers["authorization"] = "Bearer good-token"
        let s1 = HttpResponse(); app.handle(r1, s1)
        @Assert(s1.statusCode == 200)

        let r2 = HttpRequest("GET", "/api"); r2.path = "/api"
        r2.headers["authorization"] = "Bearer bad"
        let s2 = HttpResponse(); app.handle(r2, s2)
        @Assert(s2.statusCode == 401)

        let r3 = HttpRequest("GET", "/api"); r3.path = "/api"
        let s3 = HttpResponse(); app.handle(r3, s3)
        @Assert(s3.statusCode == 401)
    }

    // requestId:无头则生成并写回响应头;有头则沿用。
    @TestCase
    func testRequestId(): Unit {
        let app = wen()
        app.use(requestId())
        app.get("/", { req: HttpRequest, res: HttpResponse =>
            let id = match (req.requestId()) { case Some(v) => v; case None => "" }
            res.send(id)
        })

        // 无头:生成一个非空 ID,并写回 X-Request-Id。
        let r1 = HttpRequest("GET", "/"); r1.path = "/"
        let s1 = HttpResponse(); app.handle(r1, s1)
        @Expect(!s1.body.isEmpty())
        let hid = match (s1.get("X-Request-Id")) { case Some(v) => v; case None => "" }
        @Assert(hid == s1.body)

        // 有头:沿用上游传入的 ID。
        let r2 = HttpRequest("GET", "/"); r2.path = "/"
        r2.headers["x-request-id"] = "trace-123"
        let s2 = HttpResponse(); app.handle(r2, s2)
        @Assert(s2.body == "trace-123")
        @Assert((match (s2.get("X-Request-Id")) { case Some(v) => v; case None => "" }) == "trace-123")
    }
}
