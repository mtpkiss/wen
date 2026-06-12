package wen

import std.collection.*
import std.fs.*
import std.unittest.*
import std.unittest.testmacro.*

@Test
class OptionsTest {
    // res.cookie 的 Domain;以及由 maxAge 自动推导出的 Expires。
    @TestCase
    func testCookieDomainAndExpires(): Unit {
        let res = HttpResponse()
        res.cookie("sid", "v", domain: "example.com", maxAge: 3600)
        @Assert(res.setCookies.size == 1)
        let c = res.setCookies[0]
        @Expect(c.contains("Domain=example.com"))
        @Expect(c.contains("Max-Age=3600"))
        @Expect(c.contains("Expires="))         // 由 maxAge 自动推导
        @Expect(c.contains("GMT"))
    }

    // 显式传入的 expires 优先;不设 maxAge 时不会凭空产生 Expires。
    @TestCase
    func testCookieExplicitExpires(): Unit {
        let res = HttpResponse()
        res.cookie("a", "1", expires: "Wed, 01 Jan 2025 00:00:00 GMT")
        @Expect(res.setCookies[0].contains("Expires=Wed, 01 Jan 2025 00:00:00 GMT"))

        let res2 = HttpResponse()
        res2.cookie("b", "2")                    // 无 maxAge、无 expires
        @Expect(!res2.setCookies[0].contains("Expires="))
    }

    // 静态文件:maxAge 加 Cache-Control;目录请求补 index;dotfiles=deny 回 403。
    @TestCase
    func testStaticOptions(): Unit {
        // 在临时目录放一个 index.html。
        let dir = "._cjx_static_opt"
        if (!exists(dir)) {
            Directory.create(dir)
        }
        File.writeTo("${dir}/index.html", "<h1>home</h1>".toArray())

        let mwCache = staticFiles(dir, maxAge: 600, dotfiles: "deny")

        // 目录请求("/")补 index.html,并带 Cache-Control。
        let r1 = HttpRequest("GET", "/"); r1.path = "/"
        let s1 = HttpResponse(); s1.req = Some(r1)
        mwCache(r1, s1, { => () })
        @Assert(s1.finished)
        let cc = match (s1.get("Cache-Control")) { case Some(v) => v; case None => "" }
        @Assert(cc == "public, max-age=600")

        // dotfiles=deny:请求 .secret 回 403。
        let r2 = HttpRequest("GET", "/.secret"); r2.path = "/.secret"
        let s2 = HttpResponse(); s2.req = Some(r2)
        mwCache(r2, s2, { => () })
        @Assert(s2.statusCode == 403)

        // dotfiles=ignore(默认):隐藏文件当作不存在,放行(响应未结束)。
        let mwIgnore = staticFiles(dir)
        let r3 = HttpRequest("GET", "/.secret"); r3.path = "/.secret"
        let s3 = HttpResponse(); s3.req = Some(r3)
        mwIgnore(r3, s3, { => () })
        @Assert(!s3.finished)

        remove("${dir}/index.html")
        remove(dir)
    }
}
