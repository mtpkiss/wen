package wen

import std.collection.*
import std.fs.*
import std.unittest.*
import std.unittest.testmacro.*

@Test
class ViewTest {
    // 内置引擎:{{ key }} 顶层字段插值。
    @TestCase
    func testSimpleInterpolation(): Unit {
        let html = renderTemplate("<h1>Hi {{ name }}!</h1>", JsonObj().put("name", "Wen").build())
        @Assert(html == "<h1>Hi Wen!</h1>")
    }

    // 支持用 "." 取嵌套对象字段。
    @TestCase
    func testNestedKey(): Unit {
        let data = parseJson("{\"user\":{\"name\":\"alice\"}}")
        let html = renderTemplate("name={{ user.name }}", data)
        @Assert(html == "name=alice")
    }

    // 缺失的键替换为空串;数字/布尔按其文本插值。
    @TestCase
    func testMissingAndScalars(): Unit {
        let data = JsonObj().put("n", 42).put("ok", true).build()
        @Assert(renderTemplate("[{{ missing }}]", data) == "[]")
        @Assert(renderTemplate("{{ n }}-{{ ok }}", data) == "42-true")
    }

    // 插值默认做 HTML 转义,防止注入。
    @TestCase
    func testHtmlEscape(): Unit {
        let data = JsonObj().put("x", "<b>&\"'").build()
        @Assert(renderTemplate("{{ x }}", data) == "&lt;b&gt;&amp;&quot;&#39;")
    }

    // 未闭合的 {{ 原样保留,不报错。
    @TestCase
    func testUnclosedBraces(): Unit {
        @Assert(renderTemplate("a {{ b", JsonObj().build()) == "a {{ b")
    }

    // res.render:经 app.handle 渲染一个磁盘上的模板文件。
    @TestCase
    func testResRenderWithEngineSetting(): Unit {
        let path = "._cjx_view_hello.html"
        File.writeTo(path, "<p>Hello, {{ name }}</p>".toArray())

        let app = wen()
        app.set("views", ".")
        app.set("view engine", "html")
        app.get("/hello", { _: HttpRequest, res: HttpResponse =>
            // 视图名不带扩展名,由 "view engine" 补成 ._cjx_view_hello.html。
            res.render("._cjx_view_hello", JsonObj().put("name", "张三").build())
        })

        let req = HttpRequest("GET", "/hello"); req.path = "/hello"
        let res = HttpResponse(); app.handle(req, res)
        @Assert(res.statusCode == 200)
        @Assert(res.body == "<p>Hello, 张三</p>")
        let ct = match (res.headers.get("Content-Type")) { case Some(v) => v; case None => "" }
        @Expect(ct.contains("text/html"))
        remove(path)
    }

    // app.engine:可为某扩展名注册自定义引擎,render 时优先使用它。
    @TestCase
    func testCustomEngine(): Unit {
        let path = "._cjx_view_custom.tmpl"
        File.writeTo(path, "ignored-template-content".toArray())

        let app = wen()
        app.set("views", ".")
        app.engine("tmpl", { _: String, data: JsonValue =>
            // 自定义引擎:无视模板内容,直接据数据产出。
            let title = match (data.get("title")) {
                case Some(v) => match (v.asString()) { case Some(s) => s; case None => "?" }
                case None => "?"
            }
            "CUSTOM:${title}"
        })
        app.get("/c", { _: HttpRequest, res: HttpResponse =>
            res.render("._cjx_view_custom.tmpl", JsonObj().put("title", "Hi").build())
        })

        let req = HttpRequest("GET", "/c"); req.path = "/c"
        let res = HttpResponse(); app.handle(req, res)
        @Assert(res.body == "CUSTOM:Hi")
        remove(path)
    }
}
