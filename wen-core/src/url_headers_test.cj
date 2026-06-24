package wen

import std.collection.*
import std.unittest.*
import std.unittest.testmacro.*

/*
 * 测试 req.originalUrl、req.baseUrl 和 res.headersSent 三个新增功能。
 *
 * 注意：仓颉 lambda 不能捕获外部的 var 变量，因此这里改用
 * req.attributes["key"] 来在处理器与测试代码之间传递值。
 */
@Test
class OriginalUrlTest {
    // 顶层路由中 originalUrl 与 url 保持一致（均为完整请求目标）。
    @TestCase
    func testOriginalUrlTopLevel(): Unit {
        let app = wen()
        app.get(
            "/hello",
            {
                req: HttpRequest, res: HttpResponse =>
                    req.attributes["captured"] = req.originalUrl
                    res.send("ok")
            }
        )
        let req = HttpRequest("GET", "/hello?foo=bar")
        req.path = "/hello"
        req.query["foo"] = "bar"
        // 模拟 server.cj parseRequest 的行为：originalUrl = url
        req.originalUrl = req.url
        let res = HttpResponse()
        app.handle(req, res)
        let got = match (req.attribute("captured")) {
            case Some(v) => v
            case None => ""
        }
        @Assert(got == "/hello?foo=bar")
    }

    // originalUrl 在子路由中依然是完整原始 URL，不随 req.path 的前缀剥离而变化。
    @TestCase
    func testOriginalUrlUnchangedInSubRouter(): Unit {
        let app = wen()

        let sub = Router()
        sub.get(
            "/users",
            {
                req: HttpRequest, res: HttpResponse =>
                    req.attributes["innerOriginal"] = req.originalUrl
                    req.attributes["innerPath"] = req.path
                    req.attributes["innerBaseUrl"] = req.baseUrl
                    res.send("ok")
            }
        )
        app.use(
            {
                req: HttpRequest, _: HttpResponse, next: Next =>
                    req.attributes["outerOriginal"] = req.originalUrl
                    next()
            }
        )
        app.use("/api", sub)

        let req = HttpRequest("GET", "/api/users")
        req.path = "/api/users"
        req.originalUrl = "/api/users" // 模拟 server.cj 行为

        let res = HttpResponse()
        app.handle(req, res)

        let outerOriginal = match (req.attribute("outerOriginal")) {
            case Some(v) => v;
            case None => ""
        }
        let innerOriginal = match (req.attribute("innerOriginal")) {
            case Some(v) => v;
            case None => ""
        }
        let innerPath = match (req.attribute("innerPath")) {
            case Some(v) => v;
            case None => ""
        }
        let innerBaseUrl = match (req.attribute("innerBaseUrl")) {
            case Some(v) => v;
            case None => ""
        }

        // originalUrl 始终是完整路径
        @Assert(outerOriginal == "/api/users")
        @Assert(innerOriginal == "/api/users")
        // 子路由内 path 已剥掉前缀
        @Assert(innerPath == "/users")
        // baseUrl 反映挂载前缀
        @Assert(innerBaseUrl == "/api")
    }

    // 两级嵌套子路由中 baseUrl 正确累积。
    @TestCase
    func testBaseUrlNestedRouters(): Unit {
        let app = wen()

        let inner = Router()
        inner.get(
            "/detail",
            {
                req: HttpRequest, res: HttpResponse =>
                    req.attributes["capturedBaseUrl"] = req.baseUrl
                    req.attributes["capturedPath"] = req.path
                    res.send("ok")
            }
        )

        let outer = Router()
        outer.use("/v1", inner)

        app.use("/api", outer)

        let req = HttpRequest("GET", "/api/v1/detail")
        req.path = "/api/v1/detail"
        req.originalUrl = "/api/v1/detail"
        let res = HttpResponse()
        app.handle(req, res)

        let gotPath = match (req.attribute("capturedPath")) {
            case Some(v) => v;
            case None => ""
        }
        let gotBaseUrl = match (req.attribute("capturedBaseUrl")) {
            case Some(v) => v;
            case None => ""
        }

        @Assert(gotPath    == "/detail")
        @Assert(gotBaseUrl == "/api/v1")
    }

    // 顶级路由中 baseUrl 默认为空字符串。
    @TestCase
    func testBaseUrlEmptyAtTopLevel(): Unit {
        let app = wen()
        app.get(
            "/",
            {
                req: HttpRequest, res: HttpResponse =>
                    req.attributes["capturedBaseUrl"] = req.baseUrl
                    res.send("ok")
            }
        )
        let req = HttpRequest("GET", "/")
        req.path = "/"
        req.originalUrl = "/"
        let res = HttpResponse()
        app.handle(req, res)

        let gotBaseUrl = match (req.attribute("capturedBaseUrl")) {
            case Some(v) => v;
            case None => "NOT_SET"
        }
        @Assert(gotBaseUrl == "")
    }

    // use(path, mw) 挂载的普通中间件也能看到正确的 baseUrl。
    @TestCase
    func testBaseUrlInMountedMiddleware(): Unit {
        let app = wen()
        app.use(
            "/prefix",
            {
                req: HttpRequest, _: HttpResponse, next: Next =>
                    req.attributes["middlewareBaseUrl"] = req.baseUrl
                    req.attributes["middlewarePath"] = req.path
                    next()
            }
        )
        app.get("/prefix/page", {_: HttpRequest, res: HttpResponse => res.send("ok")})

        let req = HttpRequest("GET", "/prefix/page")
        req.path = "/prefix/page"
        req.originalUrl = "/prefix/page"
        let res = HttpResponse()
        app.handle(req, res)

        let gotBaseUrl = match (req.attribute("middlewareBaseUrl")) {
            case Some(v) => v;
            case None => ""
        }
        let gotPath = match (req.attribute("middlewarePath")) {
            case Some(v) => v;
            case None => ""
        }

        @Assert(gotBaseUrl == "/prefix")
        @Assert(gotPath    == "/page")
    }
}

@Test
class HeadersSentTest {
    // 普通响应（非流式）：在 app.handle 返回后 res.headersSent 仍为 false，
    // 因为测试场景下 res.conn 为 None，不会真正写入 socket。
    // headersSent 只有在真实服务器写入 socket 时（server.cj 中）才会被设为 true。
    @TestCase
    func testHeadersSentFalseInTestMode(): Unit {
        let app = wen()
        app.get(
            "/test",
            {
                req: HttpRequest, res: HttpResponse =>
                    // 处理器执行时响应头尚未发送，将其记录到 attributes 中
                    req.attributes["sentDuringHandler"] = if (res.headersSent) {
                        "true"
                    } else {
                        "false"
                    }
                    res.send("ok")
            }
        )
        let req = HttpRequest("GET", "/test")
        req.path = "/test"
        req.originalUrl = "/test"
        let res = HttpResponse()
        app.handle(req, res)

        let sentDuring = match (req.attribute("sentDuringHandler")) {
            case Some(v) => v;
            case None => "none"
        }
        // 在测试场景（无 conn）下，处理器内 headersSent 应为 false
        @Assert(sentDuring == "false")
        // 测试模式不写 socket，所以 app.handle 后 headersSent 仍为 false
        @Assert(!res.headersSent)
    }

    // 流式响应（stream / sse）：StreamWriter.begin() 会设置 headersSent = true。
    // 测试场景下 res.conn 为 None，但 headersSent 仍应在 begin() 时被置位。
    @TestCase
    func testHeadersSentTrueAfterStream(): Unit {
        let app = wen()
        app.get("/stream", {
            _: HttpRequest, res: HttpResponse => res.stream(
                {
                    w: StreamWriter =>
                        w.write("chunk1")
                        w.write("chunk2")
                }
            )
        })
        let req = HttpRequest("GET", "/stream")
        req.path = "/stream"
        req.originalUrl = "/stream"
        let res = HttpResponse()
        app.handle(req, res)

        // stream() 内部调用了 StreamWriter.begin()，即使无真实连接 headersSent 也应为 true
        @Assert(res.headersSent)
    }

    // SSE 响应也应在 begin() 后将 headersSent 置为 true。
    @TestCase
    func testHeadersSentTrueAfterSse(): Unit {
        let app = wen()
        app.get("/sse", {
            _: HttpRequest, res: HttpResponse => res.sse({
                w: SseWriter => w.send("hello")
            })
        })
        let req = HttpRequest("GET", "/sse")
        req.path = "/sse"
        req.originalUrl = "/sse"
        let res = HttpResponse()
        app.handle(req, res)

        @Assert(res.headersSent)
    }

    // 错误处理中间件可依据 headersSent 决定是否尝试写响应。
    @TestCase
    func testHeadersSentInErrorHandler(): Unit {
        let app = wen()

        app.get("/boom", {
            _: HttpRequest, _: HttpResponse, _: Next => throw Exception("intentional error")
        })
        // 使用 app.use(handler: ErrorHandler) 而非不存在的 app.useError
        app.use(
            {
                e: Exception, req: HttpRequest, res: HttpResponse, _: Next =>
                    req.attributes["headersSentInHandler"] = if (res.headersSent) {
                        "true"
                    } else {
                        "false"
                    }
                    res.status(500).send("error caught")
            }
        )

        let req = HttpRequest("GET", "/boom")
        req.path = "/boom"
        req.originalUrl = "/boom"
        let res = HttpResponse()
        app.handle(req, res)

        let sentInHandler = match (req.attribute("headersSentInHandler")) {
            case Some(v) => v;
            case None => "none"
        }
        // 在非流式处理器中抛出异常时，响应头尚未发送
        @Assert(sentInHandler == "false")
        @Assert(res.statusCode == 500)
    }

    // 初始状态：新建 HttpResponse 对象 headersSent 默认为 false。
    @TestCase
    func testHeadersSentDefaultFalse(): Unit {
        let res = HttpResponse()
        @Assert(!res.headersSent)
    }

    // res.vary 追加 Vary 字段,已存在的字段不重复。RFC 7231 §7.1.4 要求 Vary 值为
    // 逗号分隔的 token 列表,拼接到响应时应在逗号后保留一个空格。早前实现用
    // "${v}, ${field}" 形式,若 v 末尾已含空格(例如已有值 "Accept, Origin ",再追
    // 加 "User-Agent"),会生成 "Accept, Origin , User-Agent"(逗号前多空格),不
    // 符合规范。修法:每次拼接时统一 trim 所有片段 + 去重 + 规范化为 "field1, field2"。
    // 本测试先手动构造一个末尾带空格的已有值,验证 vary 能规范化。
    @TestCase
    func testVaryAppendNormalizesSpacing(): Unit {
        let res = HttpResponse()
        res.set("Vary", "Accept, Origin ")
        res.vary("User-Agent")
        let v = match (res.get("Vary")) {
            case Some(v) => v
            case None => ""
        }
        // 期望:trim 所有片段 → "Accept, Origin, User-Agent"(每个逗号后一个空格)
        @Assert(v == "Accept, Origin, User-Agent")
    }

    // 正常路径:多次 vary 调用且没有异常空格时,仍应规范化。
    @TestCase
    func testVaryMultipleCallsNoTrailingSpace(): Unit {
        let res = HttpResponse()
        res.vary("Accept")
        res.vary("Origin")
        res.vary("User-Agent")
        let v = match (res.get("Vary")) {
            case Some(v) => v
            case None => ""
        }
        @Assert(v == "Accept, Origin, User-Agent")
    }

    // Vary 追加时对大小写不敏感,不重复追加同一字段。
    @TestCase
    func testVaryCaseInsensitiveDedup(): Unit {
        let res = HttpResponse()
        res.vary("Accept")
        res.vary("ACCEPT")
        res.vary("accept")
        let v = match (res.get("Vary")) {
            case Some(v) => v
            case None => ""
        }
        @Assert(v == "Accept")
    }

    // res.format 自动加 Vary: Accept,与已有 Vary 合并时不破坏既有值。
    @TestCase
    func testFormatAppendsVaryAccept(): Unit {
        let res = HttpResponse()
        let req = HttpRequest("GET", "/")
        req.headers["accept"] = "text/html"
        res.req = Some(req)
        res.format([
            ("html", { => res.send("<h1>ok</h1>") }),
            ("default", { => res.status(406).send("not acceptable") })
        ])
        let v = match (res.get("Vary")) {
            case Some(v) => v
            case None => ""
        }
        @Assert(v == "Accept")
    }
}
