package wen

import std.collection.*
import std.fs.*
import std.unittest.*
import std.unittest.testmacro.*

@Test
class ViewTest {
    // app.engine:为某扩展名注册自定义引擎,res.render 时按扩展名查表调用它。
    @TestCase
    func testCustomEngine(): Unit {
        let path = "._cjx_view_custom.tmpl"
        File.writeTo(path, "ignored-template-content".toArray())

        let app = wen()
        app.set("views", ".")
        app.engine(
            "tmpl",
            {
                _: String, data: JsonValue =>
                    // 自定义引擎:无视模板内容,直接据数据产出。
                    let title = match (data.get("title")) {
                        case Some(v) => match (v.asString()) {
                            case Some(s) => s;
                            case None => "?"
                        }
                        case None => "?"
                    }
                    "CUSTOM:${title}"
            }
        )
        app.get("/c", {
            _: HttpRequest, res: HttpResponse => res.render("._cjx_view_custom.tmpl",
                JsonObj().put("title", "Hi").build())
        })

        let req = HttpRequest("GET", "/c");
        req.path = "/c"
        let res = HttpResponse();
        app.handle(req, res)
        @Assert(res.body == "CUSTOM:Hi")
        let ct = match (res.headers.get("Content-Type")) {
            case Some(v) => v;
            case None => ""
        }
        @Expect(ct.contains("text/html"))
        remove(path)
    }

    // view engine 设置 + 不带扩展名的视图名:res.render 自动补全扩展名。
    @TestCase
    func testViewEngineSetting(): Unit {
        let path = "._cjx_view_hello.html"
        File.writeTo(path, "ignored".toArray())

        let app = wen()
        app.set("views", ".")
        app.set("view engine", "html")
        app.engine(
            "html",
            {
                _: String, data: JsonValue =>
                    let name = match (data.get("name")) {
                        case Some(v) => match (v.asString()) {
                            case Some(s) => s;
                            case None => "?"
                        }
                        case None => "?"
                    }
                    "<p>Hello, ${name}</p>"
            }
        )
        app.get("/hello", {
            _: HttpRequest, res: HttpResponse => res.render("._cjx_view_hello", JsonObj().put("name", "张三").build())
        })

        let req = HttpRequest("GET", "/hello");
        req.path = "/hello"
        let res = HttpResponse();
        app.handle(req, res)
        @Assert(res.statusCode == 200)
        @Assert(res.body == "<p>Hello, 张三</p>")
        remove(path)
    }

    // 未注册引擎的扩展名 -> res.render 抛异常,顶层派发将其转为 500。
    @TestCase
    func testUnregisteredEngineThrows(): Unit {
        let app = wen()
        app.set("views", ".")
        app.get("/x", {
            _: HttpRequest, res: HttpResponse => res.render("missing.html")
        })
        let req = HttpRequest("GET", "/x");
        req.path = "/x"
        let res = HttpResponse()
        app.handle(req, res)
        @Assert(res.statusCode == 500)
    }
}
