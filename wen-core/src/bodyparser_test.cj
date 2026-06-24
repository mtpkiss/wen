package wen

import std.collection.*
import std.unittest.*
import std.unittest.testmacro.*

/*
 * 测试可插拔的请求体解析器(app.bodyParser):自定义类型被懒解析触发、主 Content-Type
 * 剥参数匹配、覆盖内置 json、未注册类型不解析,以及未注册时回落到内置解析。
 * 均经 app.handle 派发(req.app 已关联),在路由处理器内由访问器(attribute/json)
 * 懒触发 ensureBody。
 */
@Test
class BodyParserTest {
    // 注册一个内置三类之外的自定义解析器:访问 req.attribute 时被自动触发。
    @TestCase
    func testCustomParserInvoked(): Unit {
        let app = wen()
        app.bodyParser("application/x-greeting", {
            req: HttpRequest => req.setAttribute("greeting", "HELLO " + req.body)
        })
        app.post("/g", {
            req: HttpRequest, res: HttpResponse => res.send(req.attribute("greeting") ?? "none")
        })
        let req = HttpRequest("POST", "/g")
        req.path = "/g"
        req.headers["content-type"] = "application/x-greeting"
        req.body = "world"
        let res = HttpResponse()
        app.handle(req, res)
        @Assert(res.body == "HELLO world")
    }

    // 主 Content-Type 匹配时忽略 charset 等参数:注册 "application/x-greeting" 也能命中
    // 请求头 "application/x-greeting; charset=utf-8"。
    @TestCase
    func testParserMatchesIgnoringParams(): Unit {
        let app = wen()
        app.bodyParser("application/x-greeting", {
            req: HttpRequest => req.setAttribute("greeting", "HI " + req.body)
        })
        app.post("/g", {
            req: HttpRequest, res: HttpResponse => res.send(req.attribute("greeting") ?? "none")
        })
        let req = HttpRequest("POST", "/g")
        req.path = "/g"
        req.headers["content-type"] = "application/x-greeting; charset=utf-8"
        req.body = "there"
        let res = HttpResponse()
        app.handle(req, res)
        @Assert(res.body == "HI there")
    }

    // 自定义解析器可覆盖内置 json:这里的解析器不填 jsonBody,只设一个标记;
    // 因此内置 json 不再运行(req.json() 为 None)。
    @TestCase
    func testOverrideBuiltinJson(): Unit {
        let app = wen()
        app.bodyParser("application/json", {
            req: HttpRequest => req.setAttribute("custom", "overridden")
        })
        app.post(
            "/j",
            {
                req: HttpRequest, res: HttpResponse =>
                    let marker = req.attribute("custom") ?? "builtin"
                    let jsonSeen = match (req.json()) {
                        case Some(_) => "json"
                        case None => "nojson"
                    }
                    res.send("${marker}/${jsonSeen}")
            }
        )
        let req = HttpRequest("POST", "/j")
        req.path = "/j"
        req.headers["content-type"] = "application/json"
        req.body = "{\"a\":1}"
        let res = HttpResponse()
        app.handle(req, res)
        @Assert(res.body == "overridden/nojson")
    }

    // 未注册、且非内置三类的类型:不做任何解析(attribute 取不到值)。
    @TestCase
    func testUnregisteredTypeNotParsed(): Unit {
        let app = wen()
        app.post("/x", {
            req: HttpRequest, res: HttpResponse => res.send(req.attribute("anything") ?? "none")
        })
        let req = HttpRequest("POST", "/x")
        req.path = "/x"
        req.headers["content-type"] = "application/x-unknown"
        req.body = "raw payload"
        let res = HttpResponse()
        app.handle(req, res)
        @Assert(res.body == "none")
    }

    // 不注册任何自定义解析器:内置 json 解析照常工作(回落路径)。
    @TestCase
    func testBuiltinFallbackStillWorks(): Unit {
        let app = wen()
        app.post("/j", {
            req: HttpRequest, res: HttpResponse => res.send(match (req.json()) {
                case Some(j) => match (j.get("k")) {
                    case Some(v) => v.asString() ?? "?"
                    case None => "?"
                }
                case None => "none"
            })
        })
        let req = HttpRequest("POST", "/j")
        req.path = "/j"
        req.headers["content-type"] = "application/json"
        req.body = "{\"k\":\"v\"}"
        let res = HttpResponse()
        app.handle(req, res)
        @Assert(res.body == "v")
    }

    // RFC 6839 §3.1 规定 "+json" 结构化后缀(如 application/vnd.api+json、
    // application/ld+json、application/hal+json)都应被当作 JSON 处理。当前若
    // 硬编码 `mainType == "application/json"`,这类常见的 API 类型不会被解析 —
    // jsonBody = None,业务以为"没有 JSON 字段"走默认分支(典型:默认 admin=false),
    // 等同安全回退被绕过。这条断言 application/vnd.api+json 的 body 同样进 jsonBody。
    @TestCase
    func testJsonParserHandlesVndApiJsonSuffix(): Unit {
        let app = wen()
        app.use(jsonParser())
        app.post(
            "/",
            {
                req: HttpRequest, res: HttpResponse =>
                    let name = match (req.json()) {
                        case Some(j) => match (j.get("name")) {
                            case Some(v) => v.asString() ?? "?"
                            case None => "?"
                        }
                        case None => "?"
                    }
                    res.send(name)
            }
        )
        let req = HttpRequest("POST", "/")
        req.path = "/"
        req.headers["content-type"] = "application/vnd.api+json"
        req.body = "{\"name\":\"bob\"}"
        let res = HttpResponse()
        app.handle(req, res)
        @Assert(res.body == "bob")
    }
}
