package wen

import std.collection.*
import std.fs.*
import std.unittest.*
import std.unittest.testmacro.*

// 一个示例对象：模拟中间件可能挂到请求上的数据（例如已认证用户），
// 用来在测试中验证 req.locals（请求级局部存储）能存取自定义类型的对象。
class StashedUser {
    let name: String
    init(name: String) {
        this.name = name
    }
}

@Test
class AppTest {
    // 验证最基础的路由：为 GET "/" 注册一个返回 "hi" 的处理器，
    // 请求根路径后，响应状态码应为 200，响应体应为 "hi"。
    @TestCase
    func testBasicGet(): Unit {
        let app = wen()
        app.get("/", {
            req: HttpRequest, res: HttpResponse => res.send("hi")
        })
        let req = HttpRequest("GET", "/")
        req.path = "/"
        let res = HttpResponse()
        app.handle(req, res)
        @Assert(res.statusCode == 200)
        @Assert(res.body, "hi")
    }

    // 验证带命名参数 :id 的路由：访问 /users/42 时应捕获到 id="42"，
    // 处理器把它拼进 JSON 并原样回显。最终状态码 200，响应体里应含有捕获到的 "42"。
    @TestCase
    func testParamRoute(): Unit {
        let app = wen()
        app.get(
            "/users/:id",
            {
                req: HttpRequest, res: HttpResponse =>
                    // req.param 返回 ?String（Option），这里用 match 显式解包，
                    // 而不依赖在 Option 上使用 ?? 运算符。
                    var id = "?"
                    match (req.param("id")) {
                        case Some(v) => id = v
                        case None => ()
                    }
                    res.json("{\"id\":\"${id}\"}")
            }
        )
        let req = HttpRequest("GET", "/users/42")
        req.path = "/users/42"
        let res = HttpResponse()
        app.handle(req, res)
        @Assert(res.statusCode == 200)
        // 响应体中应包含被捕获的 id 值 "42"。
        @Expect(res.body.contains("42"))
    }

    // 验证未匹配到任何路由时返回 404：只注册了 GET "/"，
    // 却请求 /nope，没有对应路由，状态码应为 404。
    @TestCase
    func testUnmatchedRouteIs404(): Unit {
        let app = wen()
        app.get("/", {
            req: HttpRequest, res: HttpResponse => res.send("hi")
        })
        let req = HttpRequest("GET", "/nope")
        req.path = "/nope"
        let res = HttpResponse()
        app.handle(req, res)
        @Assert(res.statusCode == 404)
    }

    // 验证 parseInt 的容错解析：遇到第一个非数字字符就停止，忽略后面的多余字符。
    // 因此 "123abc" 应被解析为整数 123。
    @TestCase
    func testParseInt(): Unit {
        @Assert(parseInt("123abc") == 123)
    }

    // 验证 urlDecode 能正确处理 URL 编码：把百分号编码 %20 还原为空格，
    // 并把 '+' 也解码为空格。因此 "a%20b+c" 应解码为 "a b c"。
    @TestCase
    func testUrlDecode(): Unit {
        @Assert(urlDecode("a%20b+c"), "a b c")
    }

    // 验证 urlDecode 会把多个百分号字节先收集再按 UTF-8 整体重组，
    // 而不是逐字节单独解码（“中”在 UTF-8 下是三字节 %E4%B8%AD）。
    // 因此 %E4%B8%AD 应还原为“中”，混在普通字符间（a...b）也应正确，
    // 连续两个汉字 %E4%BD%A0%E5%A5%BD 应还原为“你好”。
    @TestCase
    func testUrlDecodeUtf8(): Unit {
        @Assert(urlDecode("%E4%B8%AD"), "中")
        @Assert(urlDecode("a%E4%B8%ADb"), "a中b")
        @Assert(urlDecode("%E4%BD%A0%E5%A5%BD"), "你好")
    }

    // 验证 UTF-8 路径参数在“捕获 + 解码”的完整链路上不丢失：
    // 请求 /u/%E4%B8%AD，参数 name 被捕获并解码后，处理器原样发回，响应体应为“中”。
    @TestCase
    func testParamUrlDecodedUtf8(): Unit {
        let app = wen()
        app.get(
            "/u/:name",
            {
                req: HttpRequest, res: HttpResponse =>
                    let n = match (req.param("name")) {
                        case Some(v) => v;
                        case None => "?"
                    }
                    res.send(n)
            }
        )
        let req = HttpRequest("GET", "/u/%E4%B8%AD");
        req.path = "/u/%E4%B8%AD"
        let res = HttpResponse();
        app.handle(req, res)
        @Assert(res.body, "中")
    }

    // 验证 splitOnce 只在分隔符第一次出现处切分一次：
    // 用 ":" 切分 "k:v"，应得到键 "k" 和值 "v" 两部分。
    @TestCase
    func testSplitOnce(): Unit {
        let (a, b) = splitOnce("k:v", ":")
        @Assert(a, "k")
        @Assert(b, "v")
    }

    // 验证挂载在某前缀下的中间件看到的是“去掉挂载前缀后”的路径：
    // 在 /static 上挂载中间件，处理器回显 req.path。
    @TestCase
    func testMountStripsPrefix(): Unit {
        let app = wen()
        app.use("/static", {
            req: HttpRequest, res: HttpResponse, _: Next => res.send(req.path)
        })
        let req = HttpRequest("GET", "/static/css/app.css")
        req.path = "/static/css/app.css"
        let res = HttpResponse()
        app.handle(req, res)
        // 请求 /static/css/app.css 时，前缀 "/static" 被剥离，中间件只看到剩余的 "/css/app.css"。
        @Assert(res.body, "/css/app.css")
    }

    // 验证 app.route(path) 的链式绑定：在同一路径上为多个 HTTP 动词分别绑定处理器，
    // 每个动词都应被正确分发——GET 返回 "list"，POST 返回 "create"，状态码均为 200。
    @TestCase
    func testRouteChaining(): Unit {
        let app = wen()
        app
            .route("/book")
            .get({req: HttpRequest, res: HttpResponse => res.send("list")})
            .post({req: HttpRequest, res: HttpResponse => res.send("create")})

        let getReq = HttpRequest("GET", "/book")
        getReq.path = "/book"
        let getRes = HttpResponse()
        app.handle(getReq, getRes)
        @Assert(getRes.statusCode == 200)
        @Assert(getRes.body, "list")

        let postReq = HttpRequest("POST", "/book")
        postReq.path = "/book"
        let postRes = HttpResponse()
        app.handle(postReq, postRes)
        @Assert(postRes.statusCode == 200)
        @Assert(postRes.body, "create")
    }

    // 验证中间件可以把一个带类型的对象暂存到 req.locals 上，
    // 下游处理器能再取回并向下转型（downcast）回原类型读取其字段：
    // 中间件用 setLocal("user", StashedUser("alice")) 存入，
    // 处理器用 local("user") 取出、再用 as StashedUser 转型，读出 name 并发回，应为 "alice"。
    @TestCase
    func testReqLocalsTyped(): Unit {
        let app = wen()
        app.use(
            {
                req: HttpRequest, _: HttpResponse, next: Next =>
                    req.setLocal("user", StashedUser("alice"))
                    next()
            }
        )
        app.get(
            "/",
            {
                req: HttpRequest, res: HttpResponse =>
                    var name = "?"
                    match (req.local("user")) {
                        case Some(v) => match (v as StashedUser) {
                            case Some(u) => name = u.name
                            case None => ()
                        }
                        case None => ()
                    }
                    res.send(name)
            }
        )
        let req = HttpRequest("GET", "/");
        req.path = "/"
        let res = HttpResponse();
        app.handle(req, res)
        @Assert(res.body, "alice")
    }

    // 验证 res.sendBytes 会设置一段原始二进制响应体，序列化时按字节原样使用：
    // 设置内容类型为 application/octet-stream 并发送 3 个字节后，响应应标记为已完成，
    // 且 bodyBytes 中应存在一个长度为 3 的字节数组。
    @TestCase
    func testResSendBytes(): Unit {
        let res = HttpResponse()
        res.contentType("application/octet-stream").sendBytes([UInt8(1), UInt8(2), UInt8(3)])
        @Assert(res.finished)
        match (res.bodyBytes) {
            case Some(b) => @Assert(b.size == 3)
            case None => @Assert(false)
        }
    }

    // 验证直接构造 HttpRequest 时，bodyBytes 默认为空：
    // 新建一个请求后，其 bodyBytes 的长度应为 0。
    @TestCase
    func testReqBodyBytesDefault(): Unit {
        let req = HttpRequest("GET", "/")
        @Assert(req.bodyBytes.size == 0)
    }

    // 验证带约束的参数 :id(\d+) 只匹配纯数字段：
    // 数字路径 /users/42 应匹配成功（状态码 200，捕获到 "42"）；
    @TestCase
    func testParamConstraintMatches(): Unit {
        let app = wen()
        app.get(
            "/users/:id(\\d+)",
            {
                req: HttpRequest, res: HttpResponse =>
                    let id = match (req.param("id")) {
                        case Some(v) => v;
                        case None => "?"
                    }
                    res.send(id)
            }
        )
        let ok = HttpRequest("GET", "/users/42");
        ok.path = "/users/42"
        let okRes = HttpResponse();
        app.handle(ok, okRes)
        @Assert(okRes.statusCode == 200)
        @Assert(okRes.body, "42")

        // 非数字的 id 不满足约束，无法匹配该受约束路由，因此返回 404。
        let bad = HttpRequest("GET", "/users/abc");
        bad.path = "/users/abc"
        let badRes = HttpResponse();
        app.handle(bad, badRes)
        @Assert(badRes.statusCode == 404)
    }

    // 验证受约束路由与不受约束的兜底路由可以共存，并按优先级正确分发：
    // /p/:n(\d+) 只接数字，/p/:n 接任意值。
    // 请求 /p/7（数字）应命中数字路由返回 "num"；
    // 请求 /p/hello（非数字）不满足数字约束，落到兜底路由返回 "any"。
    @TestCase
    func testParamConstraintFallthrough(): Unit {
        let app = wen()
        app.get("/p/:n(\\d+)", {_: HttpRequest, res: HttpResponse => res.send("num")})
        app.get("/p/:n", {_: HttpRequest, res: HttpResponse => res.send("any")})

        let r1 = HttpRequest("GET", "/p/7");
        r1.path = "/p/7"
        let s1 = HttpResponse();
        app.handle(r1, s1)
        @Assert(s1.body, "num")

        let r2 = HttpRequest("GET", "/p/hello");
        r2.path = "/p/hello"
        let s2 = HttpResponse();
        app.handle(r2, s2)
        @Assert(s2.body, "any")
    }

    // 验证 res.set 接受一个映射，一次性批量设置多个响应头：
    // 传入含 X-A=1、X-B=2 的 HashMap 后，从响应头中分别读回这两个头，值应为 "1" 和 "2"。
    @TestCase
    func testResSetBatch(): Unit {
        let res = HttpResponse()
        let h = HashMap<String, String>()
        h["X-A"] = "1"
        h["X-B"] = "2"
        res.set(h)
        let a = match (res.headers.get("X-A")) {
            case Some(v) => v;
            case None => ""
        }
        let b = match (res.headers.get("X-B")) {
            case Some(v) => v;
            case None => ""
        }
        @Assert(a, "1")
        @Assert(b, "2")
    }

    // 验证“路径存在但方法不被允许”时返回 405，并带上 Allow 头列出支持的方法：
    // /x 上注册了 GET 和 POST，却用 PUT 访问，状态码应为 405，
    // 且 Allow 头中应同时包含 GET 与 POST。
    @TestCase
    func testMethodNotAllowed(): Unit {
        let app = wen()
        app.get("/x", {_: HttpRequest, res: HttpResponse => res.send("ok")})
        app.post("/x", {_: HttpRequest, res: HttpResponse => res.send("made")})
        let req = HttpRequest("PUT", "/x");
        req.path = "/x"
        let res = HttpResponse();
        app.handle(req, res)
        @Assert(res.statusCode == 405)
        let allow = match (res.get("Allow")) {
            case Some(v) => v;
            case None => ""
        }
        @Expect(allow.contains("GET"))
        @Expect(allow.contains("POST"))
    }

    // 验证对已知路径的 OPTIONS 请求会被框架自动应答为 204，并附带 Allow 头：
    // /x 上只注册了 GET，但 OPTIONS 请求应自动返回 204，
    // 且 Allow 头中应包含 GET、OPTIONS、HEAD（HEAD/OPTIONS 由框架自动补全）。
    @TestCase
    func testAutoOptions(): Unit {
        let app = wen()
        app.get("/x", {_: HttpRequest, res: HttpResponse => res.send("ok")})
        let req = HttpRequest("OPTIONS", "/x");
        req.path = "/x"
        let res = HttpResponse();
        app.handle(req, res)
        @Assert(res.statusCode == 204)
        let allow = match (res.get("Allow")) {
            case Some(v) => v;
            case None => ""
        }
        @Expect(allow.contains("GET"))
        @Expect(allow.contains("OPTIONS"))
        @Expect(allow.contains("HEAD"))
    }

    // 验证在未单独注册 HEAD 路由时，HEAD 请求会自动回退到 GET 处理器，但只返回头、不返回体：
    // /x 的 GET 返回 "hello"，对其发 HEAD 请求时状态码应为 200，
    // 响应体应为空字符串，而 Content-Length 头仍应反映原 GET 内容的字节数 "5"。
    @TestCase
    func testAutoHead(): Unit {
        let app = wen()
        app.get("/x", {_: HttpRequest, res: HttpResponse => res.send("hello")})
        let req = HttpRequest("HEAD", "/x");
        req.path = "/x"
        let res = HttpResponse();
        app.handle(req, res)
        @Assert(res.statusCode == 200)
        @Assert(res.body, "")
        let len = match (res.get("Content-Length")) {
            case Some(v) => v;
            case None => ""
        }
        @Assert(len, "5")
    }

    // 验证 204 响应在序列化时既无响应体、也不带 Content-Length 头（符合 HTTP 规范）：
    // 构造状态 204 的响应并序列化为文本，文本中应含 "204 No Content"、不含 "Content-Length"，
    @TestCase
    func test204NoContentLength(): Unit {
        let server = HttpServer(wen())
        let res = HttpResponse()
        res.status(204).end()
        let text = String.fromUtf8(server.serializeResponse(res))
        @Expect(text.contains("204 No Content"))
        @Expect(!text.contains("Content-Length"))
        // 头部区段必须以空行（\r\n\r\n）结束，且其后不携带任何响应体。
        @Expect(text.endsWith("\r\n\r\n"))
    }

    // 验证 304 响应同样省略 Content-Length 头：
    // 构造状态 304 的响应并序列化，文本中应含 "304 Not Modified"、不含 "Content-Length"。
    @TestCase
    func test304NoContentLength(): Unit {
        let server = HttpServer(wen())
        let res = HttpResponse()
        res.status(304).end()
        let text = String.fromUtf8(server.serializeResponse(res))
        @Expect(text.contains("304 Not Modified"))
        @Expect(!text.contains("Content-Length"))
    }

    // 验证 headerHasContentLength 能不区分大小写地检测 Content-Length 头是否存在：
    // 含小写 "content-length" 的报文头应判定为真；只含 Host 而无该头的报文头应判定为假。
    @TestCase
    func testHeaderHasContentLength(): Unit {
        @Assert(headerHasContentLength("POST / HTTP/1.1\r\ncontent-length: 5"))
        @Assert(!headerHasContentLength("GET / HTTP/1.1\r\nHost: x"))
    }

    // 验证完全未知的路径仍然返回 404：只注册了 /x，请求 /nope 时应得到 404。
    @TestCase
    func testUnknownPathStill404(): Unit {
        let app = wen()
        app.get("/x", {_: HttpRequest, res: HttpResponse => res.send("ok")})
        let req = HttpRequest("GET", "/nope");
        req.path = "/nope"
        let res = HttpResponse();
        app.handle(req, res)
        @Assert(res.statusCode == 404)
    }

    // 验证路径参数在被捕获时会自动进行 URL 解码：
    // 请求 /u/john%20doe，参数 name 捕获后 %20 应被解码为空格，处理器发回 "john doe"。
    @TestCase
    func testParamUrlDecoded(): Unit {
        let app = wen()
        app.get(
            "/u/:name",
            {
                req: HttpRequest, res: HttpResponse =>
                    let n = match (req.param("name")) {
                        case Some(v) => v;
                        case None => "?"
                    }
                    res.send(n)
            }
        )
        let req = HttpRequest("GET", "/u/john%20doe");
        req.path = "/u/john%20doe"
        let res = HttpResponse();
        app.handle(req, res)
        @Assert(res.body, "john doe")
    }

    // 验证分发请求时 req.app 已被设置，从而处理器/中间件能读取应用级配置：
    // 用 app.set("title", "wen") 设置配置后，处理器通过 req.setting("title") 读出并发回，应为 "wen"。
    @TestCase
    func testReqApp(): Unit {
        let app = wen()
        app.set("title", "wen")
        app.get(
            "/",
            {
                req: HttpRequest, res: HttpResponse =>
                    let t = match (req.setting("title")) {
                        case Some(v) => v;
                        case None => "?"
                    }
                    res.send(t)
            }
        )
        let req = HttpRequest("GET", "/");
        req.path = "/"
        let res = HttpResponse();
        app.handle(req, res)
        @Assert(res.body, "wen")
    }

    // 验证 res.get 能读回此前通过 res.set 设置的响应头：
    // 设置 X-Trace=abc 后用 res.get("X-Trace") 取回，值应为 "abc"。
    @TestCase
    func testResGet(): Unit {
        let res = HttpResponse()
        res.set("X-Trace", "abc")
        let v = match (res.get("X-Trace")) {
            case Some(x) => x;
            case None => ""
        }
        @Assert(v, "abc")
    }

    // 验证 res.locals 与 app.locals 都能存放带类型的值：
    // 用 app.setLocal 在应用级存入 StashedUser("service")，在响应级 res.locals 存入一项。
    // 从 app.local("svc") 取出并向下转型读出 name，应为 "service"；
    // 同时 res.locals 的大小应为 1（恰好存了一项）。
    @TestCase
    func testLocalsStores(): Unit {
        let app = wen()
        app.setLocal("svc", StashedUser("service"))
        let res = HttpResponse()
        res.locals["k"] = StashedUser("scoped")
        var a = "?"
        match (app.local("svc")) {
            case Some(v) => match (v as StashedUser) {
                case Some(u) => a = u.name
                case None => ()
            }
            case None => ()
        }
        @Assert(a, "service")
        @Assert(res.locals.size == 1)
    }

    // 验证 res.stream 的测试态回退行为：调用 stream 会把响应标记为已被接管（hijacked），
    // 而在没有真实 socket 的测试环境下，写入的各个分块会被累积进 res.body，便于断言。
    // 处理器依次写入 "a"、"b"，最终响应应满足：hijacked 为真、finished 为真、body 为 "ab"。
    @TestCase
    func testStreamFallback(): Unit {
        let app = wen()
        app.get("/s", {
            _: HttpRequest, res: HttpResponse => res.stream(
                {
                    w: StreamWriter =>
                        w.write("a")
                        w.write("b")
                }
            )
        })
        let req = HttpRequest("GET", "/s");
        req.path = "/s"
        let res = HttpResponse();
        app.handle(req, res)
        @Assert(res.hijacked)
        @Assert(res.finished)
        @Assert(res.body, "ab")
    }

    // 验证 res.sse 会按 Server-Sent Events 规范格式化数据帧；测试态的写入器会把这些帧捕获到 res.body：
    // 处理器先 send("hello") 再 event("tick", "1")。响应应被标记为 hijacked，
    // Content-Type 应包含 text/event-stream。
    @TestCase
    func testSseFrames(): Unit {
        let app = wen()
        app.get("/events", {
            _: HttpRequest, res: HttpResponse => res.sse(
                {
                    s: SseWriter =>
                        s.send("hello")
                        s.event("tick", "1")
                }
            )
        })
        let req = HttpRequest("GET", "/events");
        req.path = "/events"
        let res = HttpResponse();
        app.handle(req, res)
        @Assert(res.hijacked)
        let ct = match (res.headers.get("Content-Type")) {
            case Some(v) => v;
            case None => ""
        }
        @Expect(ct.contains("text/event-stream"))
        // 默认事件帧形如 "data: hello\n\n"；命名事件帧形如 "event: tick\n" 紧接 "data: 1\n\n"。
        @Expect(res.body.contains("data: hello\n\n"))
        @Expect(res.body.contains("event: tick\n"))
        @Expect(res.body.contains("data: 1\n\n"))
    }

    // 验证 req.hostname 从 Host 头中读取主机名并剥除端口部分：
    // Host 为 "example.com:8080" 时，hostname() 应返回去掉端口后的 "example.com"。
    @TestCase
    func testHostname(): Unit {
        let req = HttpRequest("GET", "/")
        req.headers["host"] = "example.com:8080"
        let h = match (req.hostname()) {
            case Some(v) => v;
            case None => "?"
        }
        @Assert(h, "example.com")
    }

    // 验证在没有真实 socket 的情况下处理请求时（例如直接走 app.handle），req.ip 默认为空：
    // 新建请求后其 ip 应为空字符串。
    @TestCase
    func testReqIpDefault(): Unit {
        let req = HttpRequest("GET", "/")
        @Assert(req.ip, "")
    }

    // 验证 cookieParser 中间件会从 Cookie 头解析出各个键值对并填充到 req.cookies：
    // Cookie 头为 "sid=abc123; theme=dark" 时，处理器用 req.cookie("sid") 应能取到 "abc123"。
    @TestCase
    func testCookieParser(): Unit {
        let app = wen()
        app.use(cookieParser())
        app.get(
            "/",
            {
                req: HttpRequest, res: HttpResponse =>
                    let sid = match (req.cookie("sid")) {
                        case Some(v) => v;
                        case None => "?"
                    }
                    res.send(sid)
            }
        )
        let req = HttpRequest("GET", "/");
        req.path = "/"
        req.headers["cookie"] = "sid=abc123; theme=dark"
        let res = HttpResponse();
        app.handle(req, res)
        @Assert(res.body, "abc123")
    }

    // 验证 res.cookie 会按所选属性排入一条 Set-Cookie 记录：
    // 调用 res.cookie("sid", "xyz", httpOnly: true, maxAge: 3600) 后，setCookies 应有 1 条记录，
    // 且该记录中应包含键值对 "sid=xyz"、HttpOnly 标志、以及 "Max-Age=3600"。
    @TestCase
    func testResCookie(): Unit {
        let res = HttpResponse()
        res.cookie("sid", "xyz", httpOnly: true, maxAge: 3600)
        @Assert(res.setCookies.size == 1)
        @Expect(res.setCookies[0].contains("sid=xyz"))
        @Expect(res.setCookies[0].contains("HttpOnly"))
        @Expect(res.setCookies[0].contains("Max-Age=3600"))
    }

    // SameSite=None 必须配 Secure(Chrome 80+ 强制),即使调用方没显式传 secure,
    // 框架也自动补上 Secure 以防呆。
    @TestCase
    func testSameSiteNoneAutoSecure(): Unit {
        let res = HttpResponse()
        res.cookie("sid", "abc", sameSite: "None") // 注意:没传 secure
        @Assert(res.setCookies.size == 1)
        @Expect(res.setCookies[0].contains("SameSite=None"))
        @Expect(res.setCookies[0].contains("Secure"))
    }

    // 大小写不敏感:sameSite="none" 同样触发自动 Secure。
    @TestCase
    func testSameSiteNoneAutoSecureCaseInsensitive(): Unit {
        let res = HttpResponse()
        res.cookie("sid", "abc", sameSite: "none")
        @Expect(res.setCookies[0].contains("Secure"))
    }

    // SameSite=Lax / Strict 不会被强制加 Secure(向后兼容旧行为)。
    @TestCase
    func testSameSiteLaxDoesNotForceSecure(): Unit {
        let res = HttpResponse()
        res.cookie("sid", "abc", sameSite: "Lax")
        @Assert(!res.setCookies[0].contains("Secure"))
    }

    // 显式 secure: true 与 sameSite: "None" 共存时只输出一次 Secure。
    @TestCase
    func testSameSiteNoneWithExplicitSecureNoDuplicate(): Unit {
        let res = HttpResponse()
        res.cookie("sid", "abc", secure: true, sameSite: "None")
        var count = 0
        let s = res.setCookies[0]
        var i = 0
        while (true) {
            match (s.indexOf("Secure", i)) {
                case Some(k) => count += 1; i = k + 6
                case None => break
            }
        }
        @Assert(count == 1)
    }

    // 验证 clearCookie 通过设置 Max-Age=0 来让 cookie 立即过期（即删除）：
    // 调用 res.clearCookie("sid") 后，setCookies 应有 1 条记录，且其中应包含 "Max-Age=0"。
    @TestCase
    func testClearCookie(): Unit {
        let res = HttpResponse()
        res.clearCookie("sid")
        @Assert(res.setCookies.size == 1)
        @Expect(res.setCookies[0].contains("Max-Age=0"))
    }

    // 验证 req.isType 用简写形式匹配请求体的 Content-Type：
    // Content-Type 为 "application/json; charset=utf-8" 时，isType("json") 应为真、isType("html") 应为假。
    @TestCase
    func testReqIsType(): Unit {
        let req = HttpRequest("POST", "/")
        req.headers["content-type"] = "application/json; charset=utf-8"
        @Assert(req.isType("json"))
        @Assert(!req.isType("html"))
    }

    // 验证 req.accepts 依据 Accept 头判断客户端可接受的类型（并支持通配）：
    // Accept 为 "text/html,application/json" 时，accepts("json")、accepts("html") 应为真，
    // 而未列出的 accepts("css") 应为假。
    @TestCase
    func testReqAccepts(): Unit {
        let req = HttpRequest("GET", "/")
        req.headers["accept"] = "text/html,application/json"
        @Assert(req.accepts("json"))
        @Assert(req.accepts("html"))
        @Assert(!req.accepts("css"))
    }

    // 验证 res.mimeType 把简写展开为完整的 Content-Type：
    // 调用 res.mimeType("json") 后，Content-Type 头中应包含 "application/json"。
    @TestCase
    func testResMimeType(): Unit {
        let res = HttpResponse()
        res.mimeType("json")
        let ct = match (res.headers.get("Content-Type")) {
            case Some(v) => v;
            case None => ""
        }
        @Expect(ct.contains("application/json"))
    }

    // 验证 res.append 用于构建多值响应头（多次追加会以逗号拼接）：
    // 先后向 Vary 头追加 "Accept" 和 "Origin"，最终 Vary 头的值应为 "Accept, Origin"。
    @TestCase
    func testResAppend(): Unit {
        let res = HttpResponse()
        res.append("Vary", "Accept")
        res.append("Vary", "Origin")
        let v = match (res.headers.get("Vary")) {
            case Some(x) => x;
            case None => ""
        }
        @Assert(v, "Accept, Origin")
    }

    // 验证 res.sendFile 能发送一个已存在的文件，并根据扩展名推断 Content-Type：
    // 测试自行创建一个临时 .html 文件（从而不依赖运行时的工作目录），调用 sendFile 后
    // 响应应被标记为已完成，Content-Type 应包含 text/html；用完后删除该临时文件。
    @TestCase
    func testSendFile(): Unit {
        let path = "._cjx_sendfile_test.html"
        File.writeTo(path, "<h1>hi</h1>".toArray())
        let res = HttpResponse()
        res.sendFile(path)
        @Assert(res.finished)
        let ct = match (res.headers.get("Content-Type")) {
            case Some(v) => v;
            case None => ""
        }
        @Expect(ct.contains("text/html"))
        remove(path)
    }

    // 验证 res.sendFile 对二进制内容做逐字节传输（不经过 UTF-8 编解码往返而损坏数据）：
    // 写入一段包含 PNG 文件头、且故意含有非法 UTF-8 字节的数据，sendFile 后逐字节比对
    // bodyBytes 与原始数据应完全一致，且 Content-Type 应被推断为 image/png；最后删除临时文件。
    @TestCase
    func testSendFileBinary(): Unit {
        let path = "._cjx_sendfile_bin_test.png"
        // PNG 文件签名后接若干并非合法 UTF-8 的字节；这些字节必须原样保留不被破坏。
        let data: Array<UInt8> = [UInt8(137), UInt8(80), UInt8(78), UInt8(71), UInt8(13), UInt8(10), UInt8(26),
            UInt8(10), UInt8(255), UInt8(200)]
        File.writeTo(path, data)
        let res = HttpResponse()
        res.sendFile(path)
        @Assert(res.finished)
        match (res.bodyBytes) {
            case Some(b) =>
                @Assert(b.size == data.size)
                var same = true
                var i = 0
                while (i < b.size) {
                    if (b[i] != data[i]) {
                        same = false
                    }
                    i += 1
                }
                @Assert(same)
            case None => @Assert(false)
        }
        let ct = match (res.headers.get("Content-Type")) {
            case Some(v) => v;
            case None => ""
        }
        @Expect(ct.contains("image/png"))
        remove(path)
    }

    // 验证 staticFiles 静态文件中间件同样对二进制文件做逐字节传输（不经 UTF-8 往返而损坏）：
    // 在当前目录写入一个含非法 UTF-8 字节的 .png 文件，用 staticFiles(".") 中间件按 /文件名 请求，
    // 响应应标记为已完成，且 bodyBytes 与原始数据应逐字节相等；最后删除临时文件。
    @TestCase
    func testStaticFilesBinary(): Unit {
        let name = "._cjx_static_bin_test.png"
        let data: Array<UInt8> = [UInt8(137), UInt8(80), UInt8(78), UInt8(71), UInt8(0), UInt8(255), UInt8(200)]
        File.writeTo(name, data)
        // 临时文件名以 "." 开头(便于 gitignore),故显式允许 dotfiles 以验证二进制传输。
        let mw = staticFiles(".", dotfiles: "allow")
        let req = HttpRequest("GET", "/${name}");
        req.path = "/${name}"
        let res = HttpResponse()
        mw(req, res, {=> ()})
        @Assert(res.finished)
        match (res.bodyBytes) {
            case Some(b) =>
                @Assert(b.size == data.size)
                var same = true
                var i = 0
                while (i < b.size) {
                    if (b[i] != data[i]) {
                        same = false
                    }
                    i += 1
                }
                @Assert(same)
            case None => @Assert(false)
        }
        remove(name)
    }

    // 验证对不存在的文件调用 res.sendFile 会抛异常，并由此进入错误处理管线：
    // 处理器对 public/nope.xyz 调用 sendFile 触发异常，被注册的错误处理中间件捕获后
    // 返回 404 + "no file"。最终响应状态码应为 404，响应体应为 "no file"。
    @TestCase
    func testSendFileMissingThrows(): Unit {
        let app = wen()
        app.get("/f", {_: HttpRequest, res: HttpResponse => res.sendFile("public/nope.xyz")})
        app.use({
            _: Exception, _: HttpRequest, res: HttpResponse, _: Next => res.status(404).send("no file")
        })
        let req = HttpRequest("GET", "/f");
        req.path = "/f"
        let res = HttpResponse();
        app.handle(req, res)
        @Assert(res.statusCode == 404)
        @Assert(res.body, "no file")
    }

    // 验证处理器中抛出的异常会被路由到已注册的错误处理中间件，由其渲染错误信息：
    // /boom 的处理器抛出 Exception("kaboom")，错误中间件捕获后返回 500 + 含错误消息的 JSON。
    // 最终状态码应为 500，响应体中应包含 "kaboom"。
    @TestCase
    func testErrorHandlerCatches(): Unit {
        let app = wen()
        app.get("/boom", {
            _: HttpRequest, _: HttpResponse => throw Exception("kaboom")
        })
        app.use({
            e: Exception, _: HttpRequest, res: HttpResponse, _: Next => res
                .status(500)
                .json("{\"error\":\"${e.message}\"}")
        })
        let req = HttpRequest("GET", "/boom");
        req.path = "/boom"
        let res = HttpResponse();
        app.handle(req, res)
        @Assert(res.statusCode == 500)
        @Expect(res.body.contains("kaboom"))
    }

    // 验证在没有注册任何错误处理中间件时，抛出的异常会落到框架默认处理，产生 500：
    // /boom 处理器抛出异常，由于无自定义错误处理器，最终状态码应为默认的 500。
    @TestCase
    func testErrorDefault500(): Unit {
        let app = wen()
        app.get("/boom", {
            _: HttpRequest, _: HttpResponse => throw Exception("kaboom")
        })
        let req = HttpRequest("GET", "/boom");
        req.path = "/boom"
        let res = HttpResponse();
        app.handle(req, res)
        @Assert(res.statusCode == 500)
    }

    // 验证对正常成功的请求，错误处理中间件会被跳过、不会被执行：
    // /ok 正常返回 "fine"，即使注册了会返回 "should-not-run" 的错误中间件，它也不应触发。
    // 最终状态码应为 200，响应体应为 "fine"（而非错误中间件的内容）。
    @TestCase
    func testErrorHandlerSkippedOnSuccess(): Unit {
        let app = wen()
        app.get("/ok", {_: HttpRequest, res: HttpResponse => res.send("fine")})
        app.use({
            _: Exception, _: HttpRequest, res: HttpResponse, _: Next => res.status(500).send("should-not-run")
        })
        let req = HttpRequest("GET", "/ok");
        req.path = "/ok"
        let res = HttpResponse();
        app.handle(req, res)
        @Assert(res.statusCode == 200)
        @Assert(res.body, "fine")
    }

    // 验证在被挂载的子路由内部抛出的异常会向上冒泡，传播到父应用的错误处理中间件：
    // 子路由的 /explode 抛出 Exception("sub-fail")，挂载到 /api 下；
    // 父级错误中间件捕获后返回 500 + 异常消息。请求 /api/explode 时状态码应为 500，响应体应为 "sub-fail"。
    @TestCase
    func testErrorFromMountedRouter(): Unit {
        let app = wen()
        let sub = Router()
        sub.get("/explode", {_: HttpRequest, _: HttpResponse => throw Exception("sub-fail")})
        app.use("/api", sub)
        app.use({
            e: Exception, _: HttpRequest, res: HttpResponse, _: Next => res.status(500).send(e.message)
        })
        let req = HttpRequest("GET", "/api/explode");
        req.path = "/api/explode"
        let res = HttpResponse();
        app.handle(req, res)
        @Assert(res.statusCode == 500)
        @Assert(res.body, "sub-fail")
    }

    // 验证被挂载的子路由（相当于一个迷你应用）能处理 /birds 与 /birds/about，
    // 且它自带的路由级中间件对这两条路由都会运行：
    // 子路由的中间件给请求打上属性 hit="1"，根处理器读出该属性并随响应返回。
    // 请求 /birds 应得到 200 + "home:1"（说明中间件确实跑过）；
    // 请求 /birds/about 应得到 200 + "about"。
    @TestCase
    func testMountedRouter(): Unit {
        let app = wen()
        let birds = Router()
        birds.use(
            {
                req: HttpRequest, _: HttpResponse, next: Next =>
                    req.attributes["hit"] = "1"
                    next()
            }
        )
        birds.get(
            "/",
            {
                req: HttpRequest, res: HttpResponse =>
                    let hit = match (req.attribute("hit")) {
                        case Some(v) => v;
                        case None => "0"
                    }
                    res.send("home:${hit}")
            }
        )
        birds.get("/about", {_: HttpRequest, res: HttpResponse => res.send("about")})
        app.use("/birds", birds)

        let r1 = HttpRequest("GET", "/birds");
        r1.path = "/birds"
        let s1 = HttpResponse();
        app.handle(r1, s1)
        @Assert(s1.statusCode == 200)
        @Assert(s1.body, "home:1")

        let r2 = HttpRequest("GET", "/birds/about");
        r2.path = "/birds/about"
        let s2 = HttpResponse();
        app.handle(r2, s2)
        @Assert(s2.statusCode == 200)
        @Assert(s2.body, "about")
    }

    // 验证挂载的子路由内未匹配到的路径会继续向下穿透（fall through）到 404，
    // 而不会被子路由“吞掉”导致无响应：
    // 子路由只注册了 /about，请求 /birds/missing 没有对应路由，最终状态码应为 404。
    @TestCase
    func testMountedRouterFallthrough(): Unit {
        let app = wen()
        let birds = Router()
        birds.get("/about", {_: HttpRequest, res: HttpResponse => res.send("about")})
        app.use("/birds", birds)

        let req = HttpRequest("GET", "/birds/missing");
        req.path = "/birds/missing"
        let res = HttpResponse();
        app.handle(req, res)
        @Assert(res.statusCode == 404)
    }

    // 验证挂载路径中的参数（如 /birds/:type）对子路由可见（即 mergeParams 行为）：
    // 把子路由挂载到 /birds/:type 下，子路由的 /info 通过 req.param("type") 读取父级捕获的参数。
    // 请求 /birds/eagle/info 时，状态码应为 200，响应体应为父级路径段捕获到的 "eagle"。
    @TestCase
    func testMountedRouterMergeParams(): Unit {
        let app = wen()
        let sub = Router()
        sub.get(
            "/info",
            {
                req: HttpRequest, res: HttpResponse =>
                    let t = match (req.param("type")) {
                        case Some(v) => v;
                        case None => "?"
                    }
                    res.send(t)
            }
        )
        app.use("/birds/:type", sub)

        let req = HttpRequest("GET", "/birds/eagle/info");
        req.path = "/birds/eagle/info"
        let res = HttpResponse();
        app.handle(req, res)
        @Assert(res.statusCode == 200)
        @Assert(res.body, "eagle")
    }

    // 验证挂载的中间件调用 next() 之后，被剥离的前缀会被还原，下游路由看到的是完整路径：
    // 在 /api 上挂载一个仅调用 next() 的中间件（它内部看到的是去前缀后的路径），
    // 随后精确注册的 /api/health 处理器回显 req.path。
    @TestCase
    func testMountRestoresPathForDownstream(): Unit {
        let app = wen()
        app.use("/api", {_: HttpRequest, _: HttpResponse, next: Next => next()})
        app.get("/api/health", {
            req: HttpRequest, res: HttpResponse => res.send(req.path)
        })
        let req = HttpRequest("GET", "/api/health")
        req.path = "/api/health"
        let res = HttpResponse()
        app.handle(req, res)
        @Assert(res.statusCode == 200)
        // 精确路由仍然匹配成功，且它看到的是原始的完整路径（前缀已被还原）。
        @Assert(res.body, "/api/health")
    }
}
