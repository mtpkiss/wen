package wen

import std.collection.*
import std.unittest.*
import std.unittest.testmacro.*

/*
 * 测试小属性配置:res.charset、静态文件选项、Router.mountpath、
 * case sensitive routing / strict routing。
 */

// ---- res.charset ----

@Test
class CharsetTest {
    // 默认 charset 为空字符串(关闭)。
    @TestCase
    func testCharsetDefaultEmpty(): Unit {
        let res = HttpResponse()
        @Assert(res.charset == "")
    }

    // applyCharsetIfSet:Content-Type 未带 charset 时追加。
    @TestCase
    func testAppendsCharsetWhenAbsent(): Unit {
        let res = HttpResponse()
        res.headers["Content-Type"] = "text/plain"
        res.charset = "utf-8"
        applyCharsetIfSet(res)
        match (res.headers.get("Content-Type")) {
            case Some(v) => @Assert(v == "text/plain; charset=utf-8")
            case None => @Assert(false)
        }
    }

    // 已带 charset 时不追加。
    @TestCase
    func testPreservesExistingCharset(): Unit {
        let res = HttpResponse()
        res.headers["Content-Type"] = "text/html; charset=iso-8859-1"
        res.charset = "utf-8"
        applyCharsetIfSet(res)
        match (res.headers.get("Content-Type")) {
            case Some(v) => @Assert(v == "text/html; charset=iso-8859-1")
            case None => @Assert(false)
        }
    }

    // charset 为空时不动 Content-Type。
    @TestCase
    func testEmptyCharsetIsNoOp(): Unit {
        let res = HttpResponse()
        res.headers["Content-Type"] = "text/plain"
        applyCharsetIfSet(res)
        match (res.headers.get("Content-Type")) {
            case Some(v) => @Assert(v == "text/plain")
            case None => @Assert(false)
        }
    }
}

// ---- Router.mountpath ----

@Test
class MountpathTest {
    // 顶级 Router 默认 mountpath 为空串。
    @TestCase
    func testTopLevelMountpathEmpty(): Unit {
        let r = Router()
        @Assert(r.mountpath == "")
    }

    // app.use(path, sub) 设置 sub.mountpath。
    @TestCase
    func testAppUseSetsMountpath(): Unit {
        let app = wen()
        let sub = Router()
        sub.get("/", {_: HttpRequest, res: HttpResponse => res.send("ok")})
        app.use("/api", sub)
        @Assert(sub.mountpath == "/api")
    }

    // router.use(path, sub) 也设置 sub.mountpath。
    @TestCase
    func testRouterUseSetsMountpath(): Unit {
        let outer = Router()
        let inner = Router()
        outer.use("/v1", inner)
        @Assert(inner.mountpath == "/v1")
    }

    // 多次挂载以最后一次为准。
    @TestCase
    func testRemountOverrides(): Unit {
        let app = wen()
        let sub = Router()
        app.use("/a", sub)
        app.use("/b", sub)
        @Assert(sub.mountpath == "/b")
    }
}

// ---- case sensitive routing ----

@Test
class CaseSensitiveRoutingTest {
    // 默认(关闭)→ 大小写无关:/Users 命中 /users 路由。
    @TestCase
    func testDefaultCaseInsensitive(): Unit {
        let app = wen()
        app.get("/users", {_: HttpRequest, res: HttpResponse => res.send("ok")})
        let req = HttpRequest("GET", "/Users")
        req.path = "/Users"
        let res = HttpResponse()
        app.handle(req, res)
        @Assert(res.statusCode == 200)
    }

    // 开启后:/Users 不命中 /users 路由(404)。
    @TestCase
    func testEnabledRejectsDifferentCase(): Unit {
        let app = wen()
        app.enable("case sensitive routing")
        app.get("/users", {_: HttpRequest, res: HttpResponse => res.send("ok")})
        let req = HttpRequest("GET", "/Users")
        req.path = "/Users"
        let res = HttpResponse()
        app.handle(req, res)
        @Assert(res.statusCode == 404)
    }

    // 开启后相同大小写仍正常命中。
    @TestCase
    func testEnabledSameCaseMatches(): Unit {
        let app = wen()
        app.enable("case sensitive routing")
        app.get("/users", {_: HttpRequest, res: HttpResponse => res.send("ok")})
        let req = HttpRequest("GET", "/users")
        req.path = "/users"
        let res = HttpResponse()
        app.handle(req, res)
        @Assert(res.statusCode == 200)
    }
}

// ---- strict routing ----

@Test
class StrictRoutingTest {
    // 默认(关闭)→ /foo 与 /foo/ 视为同一路由。
    @TestCase
    func testDefaultIgnoresTrailingSlash(): Unit {
        let app = wen()
        app.get("/foo", {_: HttpRequest, res: HttpResponse => res.send("ok")})
        let req = HttpRequest("GET", "/foo/")
        req.path = "/foo/"
        let res = HttpResponse()
        app.handle(req, res)
        @Assert(res.statusCode == 200)
    }

    // 开启后:/foo 路由不匹配 /foo/ 请求(404)。
    @TestCase
    func testEnabledRejectsTrailingSlashMismatch(): Unit {
        let app = wen()
        app.enable("strict routing")
        app.get("/foo", {_: HttpRequest, res: HttpResponse => res.send("ok")})
        let req = HttpRequest("GET", "/foo/")
        req.path = "/foo/"
        let res = HttpResponse()
        app.handle(req, res)
        @Assert(res.statusCode == 404)
    }

    // 开启后:模式 /foo/ 不匹配请求 /foo。
    @TestCase
    func testEnabledPatternWithSlashRejectsBare(): Unit {
        let app = wen()
        app.enable("strict routing")
        app.get("/foo/", {_: HttpRequest, res: HttpResponse => res.send("ok")})
        let req = HttpRequest("GET", "/foo")
        req.path = "/foo"
        let res = HttpResponse()
        app.handle(req, res)
        @Assert(res.statusCode == 404)
    }

    // 开启后两端形态一致仍匹配。
    @TestCase
    func testEnabledSameTrailingMatches(): Unit {
        let app = wen()
        app.enable("strict routing")
        app.get("/foo/", {_: HttpRequest, res: HttpResponse => res.send("ok")})
        let req = HttpRequest("GET", "/foo/")
        req.path = "/foo/"
        let res = HttpResponse()
        app.handle(req, res)
        @Assert(res.statusCode == 200)
    }
}

// ---- staticFiles 新选项(只覆盖不需要真实文件的部分;读文件路径由现有测试覆盖) ----

@Test
class StaticOptionsTest {
    // immutable + maxAge>0 时 Cache-Control 含 immutable;applyFileResponse 关闭 ETag。
    // 这里只验证 applyFileResponse 的 etag/sendLastModified 开关行为(不依赖磁盘)。
    @TestCase
    func testApplyFileResponseEtagOff(): Unit {
        let res = HttpResponse()
        let bytes: Array<UInt8> = [UInt8(72), UInt8(105)]
        applyFileResponse(res, bytes, "text/plain", Some("Fri, 12 Jun 2026 00:00:00 GMT"), etag: false)
        match (res.headers.get("ETag")) {
            case Some(_) => @Assert(false)
            case None => @Assert(true)
        }
        // Last-Modified 仍发送
        match (res.headers.get("Last-Modified")) {
            case Some(_) => @Assert(true)
            case None => @Assert(false)
        }
    }

    @TestCase
    func testApplyFileResponseLastModifiedOff(): Unit {
        let res = HttpResponse()
        let bytes: Array<UInt8> = [UInt8(72), UInt8(105)]
        applyFileResponse(res, bytes, "text/plain", Some("Fri, 12 Jun 2026 00:00:00 GMT"), sendLastModified: false)
        match (res.headers.get("Last-Modified")) {
            case Some(_) => @Assert(false)
            case None => @Assert(true)
        }
        // ETag 默认仍发送
        match (res.headers.get("ETag")) {
            case Some(_) => @Assert(true)
            case None => @Assert(false)
        }
    }
}

// ---- 子路由继承顶层 strict / case sensitive 设置 ----

@Test
class SubRouterSettingsTest {
    // 顶层 app 开启 "strict routing" 后,所有挂载的子路由都应继承这一设置:子路由
    // 内部的路径匹配也按严格末尾斜杠规则。这里把 "/foo" 路由挂在 "/api" 前缀下,
    // 客户端发 "/api/foo/" 末尾多带斜杠,strict 模式下应判 404 — 而不是被宽容地
    // 命中。若设置传递缺失,子路由会按默认非严格规则把请求当 "/foo" 处理,本测
    // 试就会得到 200,触发回归。
    @TestCase
    func testSubRouterInheritsStrictSetting(): Unit {
        let app = wen()
        app.enable("strict routing")
        let sub = Router()
        sub.get("/foo", {_: HttpRequest, res: HttpResponse => res.send("ok")})
        app.use("/api", sub)
        let req = HttpRequest("GET", "/api/foo/")
        req.path = "/api/foo/"
        let res = HttpResponse()
        app.handle(req, res)
        @Assert(res.statusCode == 404)
    }
}
