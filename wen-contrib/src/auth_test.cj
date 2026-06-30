package wen_contrib

import wen.*
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

    // 严格 base64 解码:合法标准 base64(含 "=" 填充 / 无填充)正常解码;掺入非法字符、
    // 填充错位或长度非法的畸形输入一律判废返回空数组 —— 杜绝旧的"忽略垃圾字符仍解出
    // 看似有效 user:pass"的宽容行为(防 Basic 凭据被构造歧义解析)。
    @TestCase
    func testBase64DecodeRejectsMalformed(): Unit {
        // 合法:带填充与不带填充都应正确解码。
        @Assert(String.fromUtf8(base64Decode("YWRtaW4=")) == "admin")
        @Assert(String.fromUtf8(base64Decode("YWRtaW46c2VjcmV0")) == "admin:secret")
        // 含非法字符(空格 / '@' / 全非字母表)→ 判废返回空。
        @Assert(base64Decode("YWRt aW4=").size == 0)
        @Assert(base64Decode("YW@taW4=").size == 0)
        @Assert(base64Decode("****").size == 0)
        // "=" 出现在非尾部、或填充多于 2 个 → 判废。
        @Assert(base64Decode("YW=taW4").size == 0)
        @Assert(base64Decode("YQ===").size == 0)
        // 有效字符数 mod 4 == 1(不足以构成一个字节)→ 判废。
        @Assert(base64Decode("YWRtY").size == 0)
    }

    // Basic 认证:正确凭据放行并设 authUser;错误/缺失回 401 + WWW-Authenticate。
    @TestCase
    func testBasicAuth(): Unit {
        let app = wen()
        app.get(
            "/secret",
            [
                basicAuth({u: String, p: String => u == "admin" && p == "secret"}),
                {
                    req: HttpRequest, res: HttpResponse, _: Next =>
                        let who = match (req.attribute("authUser")) {
                            case Some(v) => v;
                            case None => "?"
                        }
                        res.send("hi ${who}")
                }
            ]
        )

        // 缺凭据 -> 401。
        let r0 = HttpRequest("GET", "/secret");
        r0.path = "/secret"
        let s0 = HttpResponse();
        app.handle(r0, s0)
        @Assert(s0.statusCode == 401)
        @Expect((match (s0.get("WWW-Authenticate")) { case Some(v) => v; case None => "" }).contains("Basic"))

        // 正确凭据 -> 200。
        let r1 = HttpRequest("GET", "/secret");
        r1.path = "/secret"
        r1.headers["authorization"] = "Basic " + base64Encode("admin:secret".toArray())
        let s1 = HttpResponse();
        app.handle(r1, s1)
        @Assert(s1.statusCode == 200)
        @Assert(s1.body == "hi admin")

        // 错误密码 -> 401。
        let r2 = HttpRequest("GET", "/secret");
        r2.path = "/secret"
        r2.headers["authorization"] = "Basic " + base64Encode("admin:wrong".toArray())
        let s2 = HttpResponse();
        app.handle(r2, s2)
        @Assert(s2.statusCode == 401)
    }

    // Bearer 认证:有效 token 放行;无效/缺失回 401。
    @TestCase
    func testBearerAuth(): Unit {
        let app = wen()
        app.get(
            "/api",
            [
                bearerAuth({t: String => t == "good-token"}),
                {_: HttpRequest, res: HttpResponse, _: Next => res.send("ok")}
            ]
        )

        let r1 = HttpRequest("GET", "/api");
        r1.path = "/api"
        r1.headers["authorization"] = "Bearer good-token"
        let s1 = HttpResponse();
        app.handle(r1, s1)
        @Assert(s1.statusCode == 200)

        let r2 = HttpRequest("GET", "/api");
        r2.path = "/api"
        r2.headers["authorization"] = "Bearer bad"
        let s2 = HttpResponse();
        app.handle(r2, s2)
        @Assert(s2.statusCode == 401)

        let r3 = HttpRequest("GET", "/api");
        r3.path = "/api"
        let s3 = HttpResponse();
        app.handle(r3, s3)
        @Assert(s3.statusCode == 401)
    }

    // requestId:无头则生成并写回响应头;有头则沿用。
    @TestCase
    func testRequestId(): Unit {
        let app = wen()
        app.use(requestId())
        app.get(
            "/",
            {
                req: HttpRequest, res: HttpResponse =>
                    let id = match (req.requestId()) {
                        case Some(v) => v;
                        case None => ""
                    }
                    res.send(id)
            }
        )

        // 无头:生成一个非空 ID,并写回 X-Request-Id。
        let r1 = HttpRequest("GET", "/");
        r1.path = "/"
        let s1 = HttpResponse();
        app.handle(r1, s1)
        @Expect(!s1.body.isEmpty())
        let hid = match (s1.get("X-Request-Id")) {
            case Some(v) => v;
            case None => ""
        }
        @Assert(hid == s1.body)

        // 有头:沿用上游传入的 ID。
        let r2 = HttpRequest("GET", "/");
        r2.path = "/"
        r2.headers["x-request-id"] = "trace-123"
        let s2 = HttpResponse();
        app.handle(r2, s2)
        @Assert(s2.body == "trace-123")
        @Assert((match (s2.get("X-Request-Id")) { case Some(v) => v; case None => "" }) == "trace-123")
    }

    // basicAuth 的 realm 来自配置 / i18n / 业务字符串拼接,可能不慎带入 CR / LF /
    // NUL(i18n 字符串末尾误带换行是常见情况)。若不转义直接写进 WWW-Authenticate
    // 头,会触发 header 安全校验抛异常 → 401 路径反而变 500,认证 UX 完全断掉。
    // 这里把 realm 设成 "evil\r\nrealm",断言响应仍是 401 且 WWW-Authenticate 头
    // 里没有原始 CR/LF 残留(实现用 "_" 替换)。
    @TestCase
    func testAuthRealmWithCrLfReplaced(): Unit {
        let app = wen()
        app.use(basicAuth({_: String, _: String => false}, realm: "evil\r\nrealm"))
        app.get("/", {_: HttpRequest, res: HttpResponse => res.send("hi")})
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
