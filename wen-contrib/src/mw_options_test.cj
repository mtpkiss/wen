package wen_contrib

import wen.*
import std.collection.*
import std.unittest.*
import std.unittest.testmacro.*

/*
 * 测试一批中间件新增的可配置项:logger 输出 sink、requestId 生成器、cors 细化策略、
 * session cookie 选项。默认行为不变,这里只验证「可注入 / 可配」这一新增能力。
 */
@Test
class MwOptionsTest {
    // logger:自定义 sink 接管输出,日志行不再只能进 stdout。
    @TestCase
    func testLoggerCustomSink(): Unit {
        let captured = ArrayList<String>()
        let app = wen()
        app.use(logger(sink: {line: String => captured.add(line)}))
        app.get("/x", {_: HttpRequest, res: HttpResponse => res.send("ok")})
        let req = HttpRequest("GET", "/x")
        req.path = "/x"
        app.handle(req, HttpResponse())
        @Assert(captured.size == 1)
        @Assert(captured[0].contains("GET /x 200"))
    }

    // requestId:自定义 generator 决定新 ID 的格式 / 取值。
    @TestCase
    func testRequestIdCustomGenerator(): Unit {
        let app = wen()
        app.use(requestId(generator: {=> "fixed-id-123"}))
        app.get("/x", {req: HttpRequest, res: HttpResponse => res.send(req.requestId() ?? "none")})
        let req = HttpRequest("GET", "/x")
        req.path = "/x"
        let res = HttpResponse()
        app.handle(req, res)
        @Assert(res.body == "fixed-id-123")
        @Assert((res.get("X-Request-Id") ?? "") == "fixed-id-123")
    }

    // requestId:上游已注入该头时沿用,不调用 generator。
    @TestCase
    func testRequestIdHonorsUpstream(): Unit {
        let app = wen()
        app.use(requestId(generator: {=> "should-not-be-used"}))
        app.get("/x", {req: HttpRequest, res: HttpResponse => res.send(req.requestId() ?? "none")})
        let req = HttpRequest("GET", "/x")
        req.path = "/x"
        req.headers["x-request-id"] = "upstream-id"
        let res = HttpResponse()
        app.handle(req, res)
        @Assert(res.body == "upstream-id")
    }

    // cors:细化策略(凭据 / 预检缓存 / 自定义头 / 暴露头)都能配。
    @TestCase
    func testCorsOptions(): Unit {
        let app = wen()
        // 用 localhost 避开 cjlint G.OTH.03 对 https://*.example.com 这类 RFC 2606
        // 文档域名的误报;cors 是把 origin 字符串原样写入响应头,具体值不影响语义。
        app.use(
            cors("http://localhost:3000", credentials: true, maxAge: 600, headers: "Content-Type, X-Request-Id",
                exposeHeaders: "X-Total-Count"))
        app.get("/x", {_: HttpRequest, res: HttpResponse => res.send("ok")})
        let req = HttpRequest("GET", "/x")
        req.path = "/x"
        let res = HttpResponse()
        app.handle(req, res)
        @Assert((res.get("Access-Control-Allow-Origin") ?? "") == "http://localhost:3000")
        @Assert((res.get("Access-Control-Allow-Credentials") ?? "") == "true")
        @Assert((res.get("Access-Control-Max-Age") ?? "") == "600")
        @Assert((res.get("Access-Control-Allow-Headers") ?? "") == "Content-Type, X-Request-Id")
        @Assert((res.get("Access-Control-Expose-Headers") ?? "") == "X-Total-Count")
    }

    // cors:默认(无细化参数)行为不变。
    @TestCase
    func testCorsDefaultsUnchanged(): Unit {
        let app = wen()
        app.use(cors("*"))
        app.get("/x", {_: HttpRequest, res: HttpResponse => res.send("ok")})
        let req = HttpRequest("GET", "/x")
        req.path = "/x"
        let res = HttpResponse()
        app.handle(req, res)
        @Assert((res.get("Access-Control-Allow-Methods") ?? "") == "GET, POST, PUT, DELETE, PATCH, OPTIONS")
        @Assert((res.get("Access-Control-Allow-Headers") ?? "") == "Content-Type, Authorization")
        // 未开启 credentials 时不发该头。
        @Assert((res.get("Access-Control-Allow-Credentials") ?? "ABSENT") == "ABSENT")
    }

    // session:自定义 cookie 名与属性出现在下发的 Set-Cookie 上。
    @TestCase
    func testSessionCookieOptions(): Unit {
        let app = wen()
        app.cookieSecret = "test-secret"
        app.use(session(MemorySessionStore(), cookieName: "myapp.sid", secure: true, sameSite: "Strict", maxAge: 3600))
        app.get(
            "/x",
            {
                req: HttpRequest, res: HttpResponse =>
                    match (req.session) {
                        case Some(s) => s.set("u", "1")
                        case None => ()
                    }
                    res.send("ok")
            }
        )
        let req = HttpRequest("GET", "/x")
        req.path = "/x"
        let res = HttpResponse()
        app.handle(req, res)
        var found = ""
        for (c in res.setCookies) {
            if (c.startsWith("myapp.sid=")) {
                found = c
            }
        }
        @Assert(found.contains("myapp.sid="))
        @Assert(found.contains("Secure"))
        @Assert(found.contains("SameSite=Strict"))
        @Assert(found.contains("Max-Age=3600"))
    }

    // 浏览器预检请求带 `Access-Control-Request-Headers: X-Custom-Foo` 时,默认
    // cors 只回固定 Allow-Headers:"Content-Type, Authorization",浏览器据此判定
    // X-Custom-Foo 不在允许列表,拒绝实际请求。开启 reflectRequestHeaders 后,
    // 中间件把预检里请求的头原样反射回 Allow-Headers,免去逐项配置(代价是
    // "信任浏览器送来的头列表",自助 API 场景适用)。断言反射后 Allow-Headers
    // 含 X-Custom-Foo。
    @TestCase
    func testCorsReflectsAccessControlRequestHeaders(): Unit {
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
}
