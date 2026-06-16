package wen

import std.collection.*
import std.unittest.*
import std.unittest.testmacro.*

@Test
class Routing4Test {
    // 多处理器路由:前置中间件 + 业务处理器,按数组顺序执行,next() 串起来。
    @TestCase
    func testMultipleHandlers(): Unit {
        let app = wen()
        app.get(
            "/admin",
            [
                {
                    req: HttpRequest, _: HttpResponse, next: Next =>
                        req.attributes["seen"] = "1"
                        next()
                },
                {
                    req: HttpRequest, res: HttpResponse, _: Next =>
                        let seen = match (req.attribute("seen")) {
                            case Some(v) => v;
                            case None => "0"
                        }
                        res.send("admin:${seen}")
                }
            ]
        )
        let req = HttpRequest("GET", "/admin");
        req.path = "/admin"
        let res = HttpResponse();
        app.handle(req, res)
        @Assert(res.statusCode == 200)
        @Assert(res.body == "admin:1")
    }

    // 前置中间件可短路:不调用 next 直接结束响应,后续处理器不再执行。
    @TestCase
    func testMultipleHandlersShortCircuit(): Unit {
        let app = wen()
        app.get(
            "/admin",
            [
                {
                    _: HttpRequest, res: HttpResponse, _: Next => res.status(401).send("denied")
                },
                {
                    _: HttpRequest, res: HttpResponse, _: Next => res.send("should-not-run")
                }
            ]
        )
        let req = HttpRequest("GET", "/admin");
        req.path = "/admin"
        let res = HttpResponse();
        app.handle(req, res)
        @Assert(res.statusCode == 401)
        @Assert(res.body == "denied")
    }

    // next("route"):第一个处理器调用 nextRoute() 跳过本路由剩余处理器,
    // 落到下一条匹配的路由。
    @TestCase
    func testNextRoute(): Unit {
        let app = wen()
        app.get(
            "/item",
            [
                {
                    req: HttpRequest, _: HttpResponse, _: Next => req.nextRoute()
                },
                {
                    _: HttpRequest, res: HttpResponse, _: Next => res.send("first-route-second-handler")
                }
            ]
        )
        app.get("/item", {
            _: HttpRequest, res: HttpResponse => res.send("second-route")
        })
        let req = HttpRequest("GET", "/item");
        req.path = "/item"
        let res = HttpResponse();
        app.handle(req, res)
        @Assert(res.body == "second-route")
    }

    // 可选参数 :id? —— 同一路由同时匹配带参与不带参两种路径。
    @TestCase
    func testOptionalParamPresentAndAbsent(): Unit {
        let app = wen()
        app.get(
            "/users/:id?",
            {
                req: HttpRequest, res: HttpResponse =>
                    let id = match (req.param("id")) {
                        case Some(v) => v;
                        case None => "all"
                    }
                    res.send(id)
            }
        )

        let r1 = HttpRequest("GET", "/users/42");
        r1.path = "/users/42"
        let s1 = HttpResponse();
        app.handle(r1, s1)
        @Assert(s1.body == "42")

        let r2 = HttpRequest("GET", "/users");
        r2.path = "/users"
        let s2 = HttpResponse();
        app.handle(r2, s2)
        @Assert(s2.statusCode == 200)
        @Assert(s2.body == "all")
    }

    // 可选参数缺省时,该参数不会出现在 params 中(不会误捕获后面的字面量段)。
    @TestCase
    func testOptionalParamWithTrailingLiteral(): Unit {
        let pat = PathPattern.compile("/files/:name?/info")
        // "/files/info" 应匹配(name 缺省)。
        match (pat.matchExact("/files/info")) {
            case Some(p) => @Assert(!p.contains("name"))
            case None => @Assert(false)
        }
        // "/files/readme/info" 应匹配且 name == "readme"。
        match (pat.matchExact("/files/readme/info")) {
            case Some(p) => @Assert(p["name"] == "readme")
            case None => @Assert(false)
        }
    }

    // 带正则约束的可选参数 :n(\d+)? —— 缺省可,提供时必须是数字。
    @TestCase
    func testOptionalConstrainedParam(): Unit {
        let app = wen()
        app.get(
            "/p/:n(\\d+)?",
            {
                req: HttpRequest, res: HttpResponse =>
                    let n = match (req.param("n")) {
                        case Some(v) => v;
                        case None => "none"
                    }
                    res.send(n)
            }
        )
        let r1 = HttpRequest("GET", "/p/7");
        r1.path = "/p/7"
        let s1 = HttpResponse();
        app.handle(r1, s1)
        @Assert(s1.body == "7")

        let r2 = HttpRequest("GET", "/p");
        r2.path = "/p"
        let s2 = HttpResponse();
        app.handle(r2, s2)
        @Assert(s2.body == "none")

        // 非数字不满足约束,既不能消费也无字面量可退,整体不匹配 -> 404。
        let r3 = HttpRequest("GET", "/p/abc");
        r3.path = "/p/abc"
        let s3 = HttpResponse();
        app.handle(r3, s3)
        @Assert(s3.statusCode == 404)
    }

    // app.param:匹配路由捕获到 :id 时,在处理器之前先触发预处理回调。
    @TestCase
    func testParamCallback(): Unit {
        let app = wen()
        app.param("id", {
            req: HttpRequest, _: HttpResponse, value: String => req.attributes["loaded"] = "user-${value}"
        })
        app.get(
            "/users/:id",
            {
                req: HttpRequest, res: HttpResponse =>
                    let loaded = match (req.attribute("loaded")) {
                        case Some(v) => v;
                        case None => "none"
                    }
                    res.send(loaded)
            }
        )
        let req = HttpRequest("GET", "/users/7");
        req.path = "/users/7"
        let res = HttpResponse();
        app.handle(req, res)
        @Assert(res.body == "user-7")
    }

    // app.param 回调可短路响应(例如鉴权失败),后续处理器不再执行。
    @TestCase
    func testParamCallbackShortCircuit(): Unit {
        let app = wen()
        app.param("id", {
            _: HttpRequest, res: HttpResponse, value: String => if (value == "0") {
                res.status(404).send("no such id")
            }
        })
        app.get("/users/:id", {_: HttpRequest, res: HttpResponse => res.send("ok")})
        let req = HttpRequest("GET", "/users/0");
        req.path = "/users/0"
        let res = HttpResponse();
        app.handle(req, res)
        @Assert(res.statusCode == 404)
        @Assert(res.body == "no such id")
    }
}
