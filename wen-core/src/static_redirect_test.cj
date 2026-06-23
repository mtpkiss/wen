package wen

import std.collection.*
import std.fs.*
import std.unittest.*
import std.unittest.testmacro.*

/*
 * 测试 staticFiles 的 redirect 选项:目录请求未带尾斜杠时是否 301 重定向。
 * 默认 true(对齐 Express 行为);设为 false 时改为放行(next)。
 */
@Test
class StaticRedirectTest {
    // 建立结构: <dir>/sub/index.html(下面所有用例共享)。
    func setupTree(): String {
        let dir = "._cjx_static_redir"
        if (!exists(dir)) {
            Directory.create(dir)
        }
        let sub = "${dir}/sub"
        if (!exists(sub)) {
            Directory.create(sub)
        }
        File.writeTo("${sub}/index.html", "<h1>home</h1>".toArray())
        return dir
    }

    func teardown(dir: String): Unit {
        let sub = "${dir}/sub"
        if (exists("${sub}/index.html")) {
            remove("${sub}/index.html")
        }
        if (exists(sub)) {
            remove(sub)
        }
        if (exists(dir)) {
            remove(dir)
        }
    }

    // 默认(redirect=true):请求 /sub(无尾斜杠)且映射到目录 -> 301 到 /sub/。
    @TestCase
    func testDirRedirectDefault(): Unit {
        let dir = setupTree()
        let mw = staticFiles(dir)
        let req = HttpRequest("GET", "/sub");
        req.path = "/sub"
        req.originalUrl = "/sub"
        let res = HttpResponse();
        res.req = Some(req)
        mw(req, res, {=> ()})
        @Assert(res.statusCode == 301)
        match (res.get("Location")) {
            case Some(v) => @Assert(v == "/sub/")
            case None => @Assert(false)
        }
        teardown(dir)
    }

    // 重定向时保留查询串。
    @TestCase
    func testDirRedirectPreservesQuery(): Unit {
        let dir = setupTree()
        let mw = staticFiles(dir)
        let req = HttpRequest("GET", "/sub?x=1&y=2")
        req.path = "/sub"
        req.originalUrl = "/sub?x=1&y=2"
        let res = HttpResponse();
        res.req = Some(req)
        mw(req, res, {=> ()})
        @Assert(res.statusCode == 301)
        match (res.get("Location")) {
            case Some(v) => @Assert(v == "/sub/?x=1&y=2")
            case None => @Assert(false)
        }
        teardown(dir)
    }

    // 挂载到 /static 下时,Location 用 originalUrl 而非已剥前缀的 path。
    @TestCase
    func testDirRedirectRespectsMount(): Unit {
        let dir = setupTree()
        let mw = staticFiles(dir)
        // 模拟挂载在 /static 下后,req.path 被剥成 /sub,但 originalUrl 仍是 /static/sub。
        let req = HttpRequest("GET", "/static/sub")
        req.path = "/sub"
        req.originalUrl = "/static/sub"
        let res = HttpResponse();
        res.req = Some(req)
        mw(req, res, {=> ()})
        @Assert(res.statusCode == 301)
        match (res.get("Location")) {
            case Some(v) => @Assert(v == "/static/sub/")
            case None => @Assert(false)
        }
        teardown(dir)
    }

    // redirect=false:目录请求改为 next 放行,响应未结束。
    @TestCase
    func testDirRedirectDisabled(): Unit {
        let dir = setupTree()
        let mw = staticFiles(dir, redirect: false)
        let req = HttpRequest("GET", "/sub");
        req.path = "/sub"
        req.originalUrl = "/sub"
        let res = HttpResponse();
        res.req = Some(req)
        // Cangjie 闭包无法捕获外部 var,这里用 req.attributes 做信号。
        mw(req, res, {=> req.attributes["nextCalled"] = "1"})
        match (req.attribute("nextCalled")) {
            case Some(v) => @Assert(v == "1")
            case None => @Assert(false)
        }
        @Assert(!res.finished)
        teardown(dir)
    }

    // URL 已带尾斜杠时:照常追加 index.html 并提供文件,不重定向。
    @TestCase
    func testDirWithTrailingSlashServesIndex(): Unit {
        let dir = setupTree()
        let mw = staticFiles(dir)
        let req = HttpRequest("GET", "/sub/");
        req.path = "/sub/"
        req.originalUrl = "/sub/"
        let res = HttpResponse();
        res.req = Some(req)
        mw(req, res, {=> ()})
        @Assert(res.statusCode == 200)
        match (res.bodyBytes) {
            case Some(b) => @Assert(String.fromUtf8(b).contains("home"))
            case None => @Assert(false)
        }
        teardown(dir)
    }

    // 真实文件请求路径不受影响(仍按常规返回文件)。
    @TestCase
    func testFileRequestUnaffected(): Unit {
        let dir = setupTree()
        File.writeTo("${dir}/plain.txt", "hello".toArray())
        let mw = staticFiles(dir)
        let req = HttpRequest("GET", "/plain.txt");
        req.path = "/plain.txt"
        req.originalUrl = "/plain.txt"
        let res = HttpResponse();
        res.req = Some(req)
        mw(req, res, {=> ()})
        @Assert(res.statusCode == 200)
        match (res.bodyBytes) {
            case Some(b) => @Assert(String.fromUtf8(b) == "hello")
            case None => @Assert(false)
        }
        remove("${dir}/plain.txt")
        teardown(dir)
    }
}
