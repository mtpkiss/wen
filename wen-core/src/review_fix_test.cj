package wen

import std.collection.*
import std.fs.*
import std.time.*
import std.unittest.*
import std.unittest.testmacro.*

/*
 * 评审 2026-06-23 报告 P0/P1/P2 各项修复的回归测试。
 * 每个 @TestCase 都对应 report/wen-engineering-review-2026-06-23.md 里某一条。
 * 测试当前应"红"(暴露 bug),修复源码后转"绿"。
 */
@Test
class ReviewFixTest {
    // ============================================================
    // P0-1 signed cookie 含 + / % / ; 等"writer 不编码、reader 却 urlDecode" 字符时,
    //      签名验证应仍能取回原值。当前 ensureCookies 隐式 urlDecode 会把 + 变空格,
    //      导致重算 HMAC 与签名段不匹配 → signedCookie 永远返回 None。
    // ============================================================
    @TestCase
    func testP0_1_SignedCookieWithPlusChar(): Unit {
        let app = wen()
        app.cookieSecret = "the-secret"
        let value = "a+b"
        let signed = "${value}.${hmacSha256Hex(app.cookieSecret, value)}"
        let req = HttpRequest("GET", "/")
        req.app = Some(app)
        req.headers["cookie"] = "x=${signed}"
        match (req.signedCookie("x")) {
            case Some(v) => @Assert(v == "a+b")
            case None => @Assert(false)
        }
    }

    @TestCase
    func testP0_1_SignedCookieWithPercentLiteral(): Unit {
        let app = wen()
        app.cookieSecret = "the-secret"
        let value = "raw%20literal"
        let signed = "${value}.${hmacSha256Hex(app.cookieSecret, value)}"
        let req = HttpRequest("GET", "/")
        req.app = Some(app)
        req.headers["cookie"] = "x=${signed}"
        match (req.signedCookie("x")) {
            case Some(v) => @Assert(v == "raw%20literal")
            case None => @Assert(false)
        }
    }

    // ============================================================
    // P0-2 UploadedFile.filename 必须归一为 basename(剥 / 与 \),
    //      避免业务 `file.saveTo("uploads/" + file.filename)` 被穿越。
    // ============================================================
    @TestCase
    func testP0_2_FilenameStripsForwardSlash(): Unit {
        let body = "--BOUNDARY\r\n" + "Content-Disposition: form-data; name=\"f\"; filename=\"../../../etc/passwd\"\r\n" +
            "Content-Type: text/plain\r\n\r\n" + "evil\r\n" + "--BOUNDARY--\r\n"
        let req = HttpRequest("POST", "/upload")
        req.headers["content-type"] = "multipart/form-data; boundary=BOUNDARY"
        req.bodyBytes = body.toArray()
        match (req.file("f")) {
            case Some(f) => @Assert(f.filename == "passwd")
            case None => @Assert(false)
        }
    }

    @TestCase
    func testP0_2_FilenameStripsBackslash(): Unit {
        let body = "--BOUNDARY\r\n" + "Content-Disposition: form-data; name=\"f\"; filename=\"..\\..\\evil.txt\"\r\n" +
            "Content-Type: text/plain\r\n\r\n" + "x\r\n" + "--BOUNDARY--\r\n"
        let req = HttpRequest("POST", "/upload")
        req.headers["content-type"] = "multipart/form-data; boundary=BOUNDARY"
        req.bodyBytes = body.toArray()
        match (req.file("f")) {
            case Some(f) => @Assert(f.filename == "evil.txt")
            case None => @Assert(false)
        }
    }

    // ============================================================
    // P0-3 HEAD 在 onExhausted 兜底(404 / 405)路径上必须 suppress body。
    // ============================================================
    @TestCase
    func testP0_3_HeadOn404SuppressesBody(): Unit {
        let app = wen()
        app.get("/x", {req: HttpRequest, res: HttpResponse => res.send("x")})
        let req = HttpRequest("HEAD", "/no-such")
        req.path = "/no-such"
        let res = HttpResponse()
        app.handle(req, res)
        @Assert(res.statusCode == 404)
        @Assert(res.suppressBody)
    }

    @TestCase
    func testP0_3_HeadOn405SuppressesBody(): Unit {
        let app = wen()
        app.post("/only-post", {req: HttpRequest, res: HttpResponse => res.send("x")})
        let req = HttpRequest("HEAD", "/only-post")
        req.path = "/only-post"
        let res = HttpResponse()
        app.handle(req, res)
        @Assert(res.statusCode == 405)
        @Assert(res.suppressBody)
    }

    // ============================================================
    // P1-1 HTTP 版本字符串必须严格 ^HTTP/\d+\.\d+$;shouldKeepAlive 必须精确匹配
    //      "HTTP/1.1",不可用 contains("1.1") 子串匹配。
    // ============================================================
    @TestCase
    func testP1_1_RejectMalformedHttpVersion(): Unit {
        let server = HttpServer(wen())
        let raw = "GET / xx1.1\r\nHost: x\r\n\r\n".toArray()
        var caught = false
        try {
            server.parseRequest(raw)
        } catch (_: BadRequestException) {
            caught = true
        }
        @Assert(caught)
    }

    @TestCase
    func testP1_1_RejectHttpVersionMissingSlash(): Unit {
        let server = HttpServer(wen())
        let raw = "GET / HTTP-1.1\r\nHost: x\r\n\r\n".toArray()
        var caught = false
        try {
            server.parseRequest(raw)
        } catch (_: BadRequestException) {
            caught = true
        }
        @Assert(caught)
    }

    @TestCase
    func testP1_1_ShouldKeepAliveStrictMatch(): Unit {
        let server = HttpServer(wen())
        let req = HttpRequest("GET", "/")
        req.httpVersion = "HTTP/2.1.1"
        @Assert(!server.shouldKeepAlive(req))
        let req2 = HttpRequest("GET", "/")
        req2.httpVersion = "HTTP/1.1"
        @Assert(server.shouldKeepAlive(req2))
    }

    // ============================================================
    // P1-2 Host 头出现第二次必须 400(与 Content-Type 多值检测对齐),
    //      防止代理 / wen 看到不同 vhost 的走私利用。
    // ============================================================
    @TestCase
    func testP1_2_RejectMultipleHostHeaders(): Unit {
        let server = HttpServer(wen())
        let raw = "GET / HTTP/1.1\r\nHost: a.com\r\nHost: b.com\r\n\r\n".toArray()
        var caught = false
        try {
            server.parseRequest(raw)
        } catch (_: BadRequestException) {
            caught = true
        }
        @Assert(caught)
    }

    // ============================================================
    // P1-5 app.use("/api/:ver?", sub):mount 路径不支持 optional 段,
    //      注册时报错(避免 stripMountPath 与可选参数贪婪吞段的歧义)。
    // ============================================================
    @TestCase
    func testP1_5_MountWithOptionalParamRejected(): Unit {
        let app = wen()
        let sub = Router()
        sub.get("/", {_: HttpRequest, res: HttpResponse => res.send("ok")})
        var caught = false
        try {
            app.use("/api/:ver?", sub)
        } catch (_: Exception) {
            caught = true
        }
        @Assert(caught)
    }

    // ============================================================
    // P1-6 prefix handler 先 next() 再 throw 时,异常应到达 error handler,而非被吞。
    // ============================================================
    @TestCase
    func testP1_6_PrefixHandlerNextThenThrowReachesErrorHandler(): Unit {
        let app = wen()
        let errSeen = ArrayList<String>()
        // mw1:先 next(),再抛异常 — 旧实现:CAS 失败 → 异常静默丢。
        app.use(
            "/api",
            {
                _: HttpRequest, _: HttpResponse, next: Next =>
                    next()
                    throw Exception("boom")
            }
        )
        // mw2:不调 next 不写响应,使 res 未 finished;这样 mw1 抛出的异常进流水线后,
        // error layer 还能被实际触发。
        app.use("/api", {_: HttpRequest, _: HttpResponse, _: Next => ()})
        app.use(
            {
                e: Exception, _: HttpRequest, res: HttpResponse, _: Next =>
                    errSeen.add(e.message)
                    res.status(500).send("err")
            }
        )
        let req = HttpRequest("GET", "/api/x")
        req.path = "/api/x"
        let res = HttpResponse()
        app.handle(req, res)
        @Assert(errSeen.size == 1)
        @Assert(errSeen[0] == "boom")
    }

    // ============================================================
    // P1-7 子路由必须继承顶层 strict / case sensitive 设置。
    // ============================================================
    @TestCase
    func testP1_7_SubRouterInheritsStrictSetting(): Unit {
        let app = wen()
        app.enable("strict routing")
        let sub = Router()
        sub.get("/foo", {_: HttpRequest, res: HttpResponse => res.send("ok")})
        app.use("/api", sub)
        // strict 下,父级前缀 /api 后,sub 应该看到 "/foo/" 不匹配 "/foo"
        let req = HttpRequest("GET", "/api/foo/")
        req.path = "/api/foo/"
        let res = HttpResponse()
        app.handle(req, res)
        @Assert(res.statusCode == 404)
    }

    // ============================================================
    // P1-11 staticFiles 默认改用弱 ETag(W/"<size>-<mtime>"),避开全文 hash。
    // ============================================================
    @TestCase
    func testP1_11_StaticFilesUsesWeakETag(): Unit {
        // 测试用 mw_static_files_test 已有的 public 目录,通过 staticFiles 取
        // 一个已知存在的文件,断言 ETag 头以 "W/" 开头。
        let app = wen()
        app.use("/s", staticFiles("./test_data_static"))
        // 临时建立一个测试文件
        let dir = "./test_data_static"
        try {
            Directory.create(Path(dir), recursive: true)
        } catch (_: Exception) {
            ()
        }
        let testFile = "${dir}/probe.txt"
        File.writeTo(testFile, "hi".toArray())
        let req = HttpRequest("GET", "/s/probe.txt")
        req.path = "/s/probe.txt"
        let res = HttpResponse()
        app.handle(req, res)
        @Assert(res.statusCode == 200)
        match (res.get("ETag")) {
            case Some(v) => @Assert(v.startsWith("W/\""))
            case None => @Assert(false)
        }
    }

    // ============================================================
    // P1-12 multipart 字段参数:name="a; b" 引号内的分号不应被切坏。
    // ============================================================
    @TestCase
    func testP1_12_MultipartFieldNameWithSemicolonInQuotes(): Unit {
        let body = "--BOUNDARY\r\n" + "Content-Disposition: form-data; name=\"a; b\"\r\n\r\n" + "value\r\n" +
            "--BOUNDARY--\r\n"
        let req = HttpRequest("POST", "/")
        req.headers["content-type"] = "multipart/form-data; boundary=BOUNDARY"
        req.bodyBytes = body.toArray()
        match (req.attribute("a; b")) {
            case Some(v) => @Assert(v == "value")
            case None => @Assert(false)
        }
    }

    // ============================================================
    // P2-A buildHeadBlock 应按插入顺序遍历 headers,而非 HashMap 的不定顺序。
    // ============================================================
    @TestCase
    func testP2_A_HeaderOrderIsInsertionOrder(): Unit {
        let res = HttpResponse()
        res.set("X-A", "1")
        res.set("X-B", "2")
        res.set("X-C", "3")
        res.set("X-D", "4")
        let bytes = buildHeadBlock(res)
        let s = String.fromUtf8(bytes)
        let ia = s.indexOf("X-A")
        let ib = s.indexOf("X-B")
        let ic = s.indexOf("X-C")
        let id = s.indexOf("X-D")
        match ((ia, ib, ic, id)) {
            case (Some(a), Some(b), Some(c), Some(d)) => @Assert(a < b && b < c && c < d)
            case _ => @Assert(false)
        }
    }

    // ============================================================
    // P2-B res.set/status/cookie/redirect/end/json 在 finished 后应跳过(警告)。
    // ============================================================
    @TestCase
    func testP2_B_StatusAfterFinishedIsNoop(): Unit {
        let res = HttpResponse()
        res.send("ok") // finished=true
        let savedStatus = res.statusCode
        res.status(500)
        @Assert(res.statusCode == savedStatus)
    }

    // 注:res.set 在 finished 后**不**被屏蔽 — server 序列化阶段(ensureDateHeader、
    // 自动 Content-Length、charset)仍需在 res.finished=true 之后写头。仅 status / cookie /
    // redirect / send / sendBytes 这些"用户面"的语义改动接口在 finished 后才告警跳过。
    @TestCase
    func testP2_B_SetAfterFinishedAllowed(): Unit {
        let res = HttpResponse()
        res.send("ok")
        res.set("X-Late", "v")
        match (res.get("X-Late")) {
            case Some(v) => @Assert(v == "v")
            case None => @Assert(false)
        }
    }

    // ============================================================
    // P2-D formatHttpDate 输出严格 ASCII 三字母前缀(脱钩 std locale)。
    // ============================================================
    @TestCase
    func testP2_D_FormatHttpDateAsciiAbbrev(): Unit {
        let t = DateTime.of(year: 2026, month: Month.January, dayOfMonth: 1, hour: 0, minute: 0, second: 0)
        let s = formatHttpDate(t)
        // 期望形如 "Thu, 01 Jan 2026 00:00:00 GMT"
        @Assert(s.contains("Jan"))
        @Assert(s.contains("2026"))
        @Assert(s.endsWith("GMT"))
    }

    // ============================================================
    // P2-G 多次 app.param 同名应都被触发,而非只保留最后一个。
    // ============================================================
    @TestCase
    func testP2_G_MultipleParamHandlersForSameName(): Unit {
        let app = wen()
        let log = ArrayList<String>()
        app.param("id", {_: HttpRequest, _: HttpResponse, v: String => log.add("h1:${v}")})
        app.param("id", {_: HttpRequest, _: HttpResponse, v: String => log.add("h2:${v}")})
        app.get("/x/:id", {_: HttpRequest, res: HttpResponse => res.send("ok")})
        let req = HttpRequest("GET", "/x/42")
        req.path = "/x/42"
        let res = HttpResponse()
        app.handle(req, res)
        @Assert(log.size == 2)
        @Assert(log[0] == "h1:42")
        @Assert(log[1] == "h2:42")
    }

    // P2-H 设计取舍:wen 默认 mergeParams=true(与 Express mergeParams:true 一致),
    // 父级 prefix 捕获的 params 沿用到子层。这意味着 `/x/:userId` 中间件 + `/x/:account`
    // 路由场景下,handler 内 req.params 同时含两个名 — 这是文档化行为,非缺陷。
    @TestCase
    func testP2_H_MergeParamsKeepsBothNames(): Unit {
        let app = wen()
        let seen = ArrayList<String>()
        app.use("/x/:userId", {_: HttpRequest, _: HttpResponse, next: Next => next()})
        app.get(
            "/x/:account",
            {
                req: HttpRequest, res: HttpResponse =>
                    for ((k, _) in req.params) {
                        seen.add(k)
                    }
                    res.send("ok")
            }
        )
        let req = HttpRequest("GET", "/x/100")
        req.path = "/x/100"
        let res = HttpResponse()
        app.handle(req, res)
        // mergeParams=true 下,两个 param 名都在,值都为 "100"。
        @Assert(seen.size == 2)
        match (req.param("account")) {
            case Some(v) => @Assert(v == "100")
            case None => @Assert(false)
        }
        match (req.param("userId")) {
            case Some(v) => @Assert(v == "100")
            case None => @Assert(false)
        }
    }

    // ============================================================
    // P2-I app.all(path, h) 唯一注册时,h 调 next() 后应返 405 而非 404。
    // ============================================================
    @TestCase
    func testP2_I_AllRouteWithNextReturns405(): Unit {
        let app = wen()
        app.all("/x", {_: HttpRequest, _: HttpResponse, next: Next => next()})
        let req = HttpRequest("GET", "/x")
        req.path = "/x"
        let res = HttpResponse()
        app.handle(req, res)
        @Assert(res.statusCode == 405)
    }

    // ============================================================
    // P2-K bytesToHex 行为应保持不变(回归保险)— 预期等同于已有 hmacSha256Hex 输出。
    // ============================================================
    @TestCase
    func testP2_K_BytesToHexBehaviourUnchanged(): Unit {
        let bytes: Array<UInt8> = [UInt8(0), UInt8(15), UInt8(16), UInt8(255), UInt8(170)]
        let s = bytesToHex(bytes)
        @Assert(s == "000f10ffaa")
    }

    // ============================================================
    // P2-M appendInt64 对负 v 不应抛(避免时间回拨触发全局 SecureRandom 构造失败)。
    // ============================================================
    @TestCase
    func testP2_M_AppendInt64HandlesNegative(): Unit {
        let buf = ArrayList<UInt8>()
        var threw = false
        try {
            appendInt64(buf, -1)
            appendInt64(buf, Int64.Min)
        } catch (_: Exception) {
            threw = true
        }
        @Assert(!threw)
        @Assert(buf.size == 16)
    }

    // ============================================================
    // P2-O JSON parseNumber 应拒绝 RFC 8259 不允许的前导零 / 裸小数点。
    // ============================================================
    @TestCase
    func testP2_O_RejectsLeadingZero(): Unit {
        var caught = false
        try {
            parseJson("00123")
        } catch (_: Exception) {
            caught = true
        }
        @Assert(caught)
    }

    @TestCase
    func testP2_O_RejectsBareDot(): Unit {
        var caught = false
        try {
            parseJson(".5")
        } catch (_: Exception) {
            caught = true
        }
        @Assert(caught)
    }

    // ============================================================
    // P2-S sendFile 文件不存在抛异常前应清掉 Content-Type 等用户钩子设置的头,
    //      避免上层 500 错误响应残留误导性头。
    // ============================================================
    @TestCase
    func testP2_S_SendFileMissingClearsHeaders(): Unit {
        let res = HttpResponse()
        res.set("Cache-Control", "public, max-age=3600")
        res.set("Content-Type", "image/png")
        var threw = false
        try {
            res.sendFile("./this-file-does-not-exist.bin")
        } catch (_: Exception) {
            threw = true
        }
        @Assert(threw)
        // 期望:抛异常前已把 Content-Type / Cache-Control 清掉。
        @Assert(res.get("Cache-Control").isNone())
    }
}
