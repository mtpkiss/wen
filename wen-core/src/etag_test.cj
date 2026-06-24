package wen

import std.collection.*
import std.fs.*
import std.unittest.*
import std.unittest.testmacro.*

@Test
class EtagTest {
    // res.send 的动态响应:首次得到 ETag,带 If-None-Match 回送则 304。
    @TestCase
    func testSendConditional(): Unit {
        let app = wen()
        app.use(etag())
        app.get("/", {_: HttpRequest, res: HttpResponse => res.send("hello world")})

        let r1 = HttpRequest("GET", "/");
        r1.path = "/"
        let s1 = HttpResponse();
        app.handle(r1, s1)
        @Assert(s1.statusCode == 200)
        let tag = match (s1.get("ETag")) {
            case Some(v) => v;
            case None => ""
        }
        @Expect(!tag.isEmpty())

        let r2 = HttpRequest("GET", "/");
        r2.path = "/"
        r2.headers["if-none-match"] = tag
        let s2 = HttpResponse();
        app.handle(r2, s2)
        @Assert(s2.statusCode == 304)
        @Assert(s2.body == "")
    }

    // res.json 同样获得 ETag;内容不同则 ETag 不同(不会误判 304)。
    @TestCase
    func testJsonEtagDiffers(): Unit {
        let app = wen()
        app.use(etag())
        app.get("/a", {_: HttpRequest, res: HttpResponse => res.json(JsonObj().put("v", 1).build())})
        app.get("/b", {_: HttpRequest, res: HttpResponse => res.json(JsonObj().put("v", 2).build())})

        let ra = HttpRequest("GET", "/a");
        ra.path = "/a"
        let sa = HttpResponse();
        app.handle(ra, sa)
        let ta = match (sa.get("ETag")) {
            case Some(v) => v;
            case None => ""
        }

        let rb = HttpRequest("GET", "/b");
        rb.path = "/b"
        let sb = HttpResponse();
        app.handle(rb, sb)
        let tb = match (sb.get("ETag")) {
            case Some(v) => v;
            case None => ""
        }

        @Expect(!ta.isEmpty())
        @Assert(ta != tb)

        // 用 /a 的 ETag 去请求 /b,不应命中 304。
        let rb2 = HttpRequest("GET", "/b");
        rb2.path = "/b"
        rb2.headers["if-none-match"] = ta
        let sb2 = HttpResponse();
        app.handle(rb2, sb2)
        @Assert(sb2.statusCode == 200)
    }

    // 非 GET 不加 ETag。
    @TestCase
    func testNonGetNoEtag(): Unit {
        let app = wen()
        app.use(etag())
        app.post("/", {_: HttpRequest, res: HttpResponse => res.send("created")})
        let req = HttpRequest("POST", "/");
        req.path = "/"
        let res = HttpResponse();
        app.handle(req, res)
        match (res.get("ETag")) {
            case Some(_) => @Assert(false)
            case None => @Expect(true)
        }
    }

    // 文件响应已自带 ETag,中间件不重复处理(仍是文件那套 ETag,响应 200)。
    @TestCase
    func testFileResponseNotDoubled(): Unit {
        let app = wen()
        app.use(etag())
        app.get("/x", {
            _: HttpRequest, res: HttpResponse => res.contentType("text/plain").sendBytes("data".toArray())
        })
        // sendBytes 不带 ETag,故这里中间件会补;另用真实文件场景已在 file_response_test 覆盖。
        let req = HttpRequest("GET", "/x");
        req.path = "/x"
        let res = HttpResponse();
        app.handle(req, res)
        @Assert(res.statusCode == 200)
        @Expect(!(match (res.get("ETag")) { case Some(v) => v; case None => "" }).isEmpty())
    }

    // staticFiles 中间件默认使用弱 ETag(W/"size-mtime" 格式),而不是对整个文件
    // 内容算 hash。弱 ETag 只用文件元数据,代价恒定 O(1),对大文件友好;强 ETag
    // 要读整个文件,大文件高并发会吃满内存,Range 请求取末字节也会被迫拉全文。
    // 这条断言中间件发出的 ETag 头以 "W/" 开头,证明走的是弱 ETag 路径。
    @TestCase
    func testStaticFilesUsesWeakETag(): Unit {
        let app = wen()
        app.use("/s", staticFiles("./test_data_static"))
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

    // staticFiles 默认应发 `X-Content-Type-Options: nosniff`。一旦用户把 staticFiles
    // 对外提供用户上传目录,攻击者上传带 `<script>` 的 SVG,浏览器会把 image/svg+xml
    // 当 HTML 渲染 — 存储型 XSS 入口。nosniff 头明确禁止 MIME 嗅探,让浏览器拒绝
    // 按非声明 Content-Type 解析。框架替业务把这道默认头加上,免得用户在不知情时
    // 把 staticFiles 接到上传目录上踩坑。
    @TestCase
    func testStaticFilesSendsNoSniffByDefault(): Unit {
        let app = wen()
        app.use("/s", staticFiles("./test_data_static"))
        let dir = "./test_data_static"
        try {
            Directory.create(Path(dir), recursive: true)
        } catch (_: Exception) {
            ()
        }
        let testFile = "${dir}/probe-nosniff.txt"
        File.writeTo(testFile, "hi".toArray())
        let req = HttpRequest("GET", "/s/probe-nosniff.txt")
        req.path = "/s/probe-nosniff.txt"
        let res = HttpResponse()
        app.handle(req, res)
        @Assert(res.statusCode == 200)
        @Assert(res.get("X-Content-Type-Options") == Some("nosniff"))
    }

    // nosniff: false 时允许关闭该头(某些极少数场景下需要保留浏览器 MIME 嗅探,
    // 框架不替业务决定 — 给一个逃生口)。
    @TestCase
    func testStaticFilesNoSniffCanBeDisabled(): Unit {
        let app = wen()
        app.use("/s", staticFiles("./test_data_static", nosniff: false))
        let dir = "./test_data_static"
        try {
            Directory.create(Path(dir), recursive: true)
        } catch (_: Exception) {
            ()
        }
        let testFile = "${dir}/probe-no-nosniff.txt"
        File.writeTo(testFile, "hi".toArray())
        let req = HttpRequest("GET", "/s/probe-no-nosniff.txt")
        req.path = "/s/probe-no-nosniff.txt"
        let res = HttpResponse()
        app.handle(req, res)
        @Assert(res.statusCode == 200)
        @Assert(res.get("X-Content-Type-Options").isNone())
    }
}
