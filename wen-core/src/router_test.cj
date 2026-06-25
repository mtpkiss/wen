package wen

import std.collection.*
import std.unittest.*
import std.unittest.testmacro.*

@Test
class RouterTest {
    // 验证命名参数的精确匹配：模式 /users/:id 应当能匹配实际路径 /users/42，
    // 并把路径段 "42" 捕获到参数 id 上。匹配成功时取出 id，断言其值为 "42"；
    // 若返回 None 则说明匹配失败，用 @Assert(false) 让用例直接失败（注释提示“本应匹配”）。
    @TestCase
    func testParamExactMatch(): Unit {
        let pat = PathPattern.compile("/users/:id")
        match (pat.matchExact("/users/42")) {
            case Some(p) => @Assert(p["id"], "42")
            case None => @Assert(false) // 期望匹配成功，走到这里说明匹配失败
        }
    }

    // 验证精确匹配对段数的严格要求：模式 /users/:id 只有两段，
    // 而实际路径 /users/42/posts 多出一段，因此绝不能匹配成功。
    // 若意外匹配（Some 分支）则用 @Assert(false) 判定失败；正确情况应落入 None 分支。
    @TestCase
    func testParamExactMismatchExtraSegment(): Unit {
        let pat = PathPattern.compile("/users/:id")
        match (pat.matchExact("/users/42/posts")) {
            case Some(_) => @Assert(false) // 不应匹配：实际路径多出一段
            case None => @Expect(true)
        }
    }

    // 验证通配符 * 的行为：位于末尾的通配段会吞掉路径剩余的全部内容，
    // 因此模式 /files/* 能匹配 /files/a/b/c 这种多层级的尾部路径。
    // 期望走 Some 分支表示匹配成功；落入 None 则说明通配未生效，判定失败。
    @TestCase
    func testWildcardMatch(): Unit {
        let pat = PathPattern.compile("/files/*")
        match (pat.matchExact("/files/a/b/c")) {
            case Some(_) => @Expect(true)
            case None => @Assert(false) // 通配符应当匹配整个尾部路径
        }
    }

    // 验证前缀匹配（挂载场景）：以 /api 作为挂载前缀时，
    // matchPrefix 应当认为 /api/users 命中该前缀（前缀匹配只要求路径以模式开头）。
    // 期望走 Some 分支；落入 None 则说明前缀匹配未生效，判定失败。
    @TestCase
    func testPrefixMountMatches(): Unit {
        let pat = PathPattern.compile("/api")
        match (pat.matchPrefix("/api/users")) {
            case Some(_) => @Expect(true)
            case None => @Assert(false) // 前缀应当命中
        }
    }

    // 与上一用例对照：同样是 /api 对 /api/users，
    // 用 matchExact（精确匹配）时则不应命中——因为精确匹配要求整条路径完全相等，
    // 而 /api/users 比模式 /api 多出内容。若意外走 Some 分支则判定失败，正确应落入 None。
    @TestCase
    func testPrefixNotExact(): Unit {
        let pat = PathPattern.compile("/api")
        match (pat.matchExact("/api/users")) {
            case Some(_) => @Assert(false) // 精确匹配应当失败
            case None => @Expect(true)
        }
    }

    // 验证字面量段不匹配的情形：模式 /a/b 的第二段是字面量 "b"，
    // 与实际路径 /a/c 的第二段 "c" 不同，因此不应匹配。
    // 若意外走 Some 分支则判定失败，正确应落入 None。
    @TestCase
    func testLiteralMismatch(): Unit {
        let pat = PathPattern.compile("/a/b")
        match (pat.matchExact("/a/c")) {
            case Some(_) => @Assert(false) // 字面量段不同，不应匹配
            case None => @Expect(true)
        }
    }

    // HEAD 请求落到不存在的路径,router 兜底走 404。HTTP 契约要求 HEAD 响应永远
    // 不带 body,即便是错误兜底路径也不能例外。断言响应码是 404 且 suppressBody
    // 标志为 true(序列化层据此把 body 抹掉)。
    @TestCase
    func testHeadOn404SuppressesBody(): Unit {
        let app = wen()
        app.get("/x", {_: HttpRequest, res: HttpResponse => res.send("x")})
        let req = HttpRequest("HEAD", "/no-such")
        req.path = "/no-such"
        let res = HttpResponse()
        app.handle(req, res)
        @Assert(res.statusCode == 404)
        @Assert(res.suppressBody)
    }

    // 同上,但场景换成 405:路径只注册了 POST,客户端发 HEAD,router 应回
    // 405 Method Not Allowed,同样不能带 body。HEAD body 抑制要在所有错误兜底路
    // 径上一致生效,不能只覆盖正常的 GET → HEAD 派生路径。
    @TestCase
    func testHeadOn405SuppressesBody(): Unit {
        let app = wen()
        app.post("/only-post", {_: HttpRequest, res: HttpResponse => res.send("x")})
        let req = HttpRequest("HEAD", "/only-post")
        req.path = "/only-post"
        let res = HttpResponse()
        app.handle(req, res)
        @Assert(res.statusCode == 405)
        @Assert(res.suppressBody)
    }

    // 挂载子路由时,挂载路径不能含可选参数段(":ver?"):匹配阶段可选段会贪婪吞
    // 掉一段,与 stripMountPath 计算子路由相对路径的语义产生冲突 — 同一个请求,
    // 挂载层和子路由层会对路径切分有分歧。注册阶段就直接抛异常拒绝,而不是等到
    // 运行时才出现难以排查的错位 bug。
    @TestCase
    func testMountWithOptionalParamRejected(): Unit {
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

    // 前缀中间件 mw1 同步调用 next() 之后才抛异常的场景:next 已经把流水线推进
    // 过,mw1 此时抛出的异常必须能被 error layer 接住,而不能被静默丢失。
    //
    // 用一个不写响应也不调 next 的 mw2 作为推进目标,避免 mw1 next() 时整条链立
    // 刻结束、让 mw1 之后的 throw 落在另一种生命周期窗口里 — 这样能准确验证
    // "先 next 再 throw" 这条特定路径上的异常确实会冒到 error layer。
    @TestCase
    func testPrefixHandlerNextThenThrowReachesErrorHandler(): Unit {
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

    // 同名 app.param 注册多次,所有 handler 都应按注册顺序依次执行,而不是只保留
    // 最后一个(这是 Express 等成熟框架的同款语义)。这条断言注册两个 "id" handler,
    // 匹配 /x/42 后日志里应该 h1 与 h2 两条都在,且顺序与注册顺序一致。
    @TestCase
    func testMultipleParamHandlersForSameName(): Unit {
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

    // wen 默认 mergeParams = true(对齐 Express 同名配置):父级 prefix 中间件
    // 捕获的 params 会沿用到子层路由的 handler。这意味着 `/x/:userId` 中间件 +
    // `/x/:account` 路由同时存在时,handler 内的 req.params 会同时含 "userId" 与
    // "account" 两个名字,值都是路径段实际值("100")。这是文档化行为而非缺陷;
    // 断言两个名字都能取到,锁住默认配置不破。
    @TestCase
    func testMergeParamsKeepsBothNames(): Unit {
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

    // app.all(path, h) 是"任何方法都走 h"的快捷注册。当 h 不响应而是 next()
    // 放行、且这条路径只有这一条 all 注册时,后续没有 layer 接住 — 兜底应该回
    // 405(意为"路径存在但本方法没有具体 handler"),而非 404("路径不存在")。
    // 这条断言确认 methodsForPath 把 all 注册算入"路径已知"集合。
    @TestCase
    func testAllRouteWithNextReturns405(): Unit {
        let app = wen()
        app.all("/x", {_: HttpRequest, _: HttpResponse, next: Next => next()})
        let req = HttpRequest("GET", "/x")
        req.path = "/x"
        let res = HttpResponse()
        app.handle(req, res)
        @Assert(res.statusCode == 405)
    }

    // 子路由内注册的 GET 应被父级 HEAD-fallback 看到:
    //
    //     let sub = Router()
    //     sub.get("/items", h)
    //     app.use("/api", sub)
    //     // 客户端发 HEAD /api/items → 应被 fallback 到 sub 的 GET 路由
    //
    // 早先实现 hasMethodForPath 只查顶级 router 自身的 layers,看不到 prefix-mount
    // layer 之下子 router 的方法,HEAD /api/items 直接走兜底 405。Express 行为是
    // HEAD 自动覆盖任意层级的 GET。修法:hasMethodForPath 在遇 prefix-mount layer
    // 时剥前缀递归查子 router。
    @TestCase
    func testHeadFallbackRecursesIntoSubRouter(): Unit {
        let app = wen()
        let sub = Router()
        sub.get("/items", {_: HttpRequest, res: HttpResponse => res.send("hello")})
        app.use("/api", sub)
        let req = HttpRequest("HEAD", "/api/items")
        req.path = "/api/items"
        let res = HttpResponse()
        app.handle(req, res)
        @Assert(res.statusCode == 200)
        // HEAD 响应不带 body。
        @Assert(res.suppressBody)
    }

    // 通配段 "*" 只能出现在路径末尾。注册 `/files/*/raw` 时,匹配阶段 wildcard 段
    // 会贪婪吞掉路径剩余的所有段,后面的字面段 "raw" 永远不参与匹配 — 实际语义等
    // 于 `/files/*`,与"中间段任意、末尾必须 raw"的用户意图完全不符。注册阶段直
    // 接抛异常,把"看不见的偏差"前置成"看得见的报错"。
    @TestCase
    func testWildcardRejectedInMiddleSegment(): Unit {
        var caught = false
        try {
            let _ = PathPattern.compile("/files/*/raw")
        } catch (_: Exception) {
            caught = true
        }
        @Assert(caught)
    }

    // 参数段冒号后必须有参数名:`/users/:` 这种 typo 在旧实现下静默通过,后续
    // `req.param("")` 才取得到,debug 困难。注册阶段就拒。
    @TestCase
    func testEmptyParamNameRejected(): Unit {
        var caught = false
        try {
            let _ = PathPattern.compile("/users/:")
        } catch (_: Exception) {
            caught = true
        }
        @Assert(caught)
    }

    // 子路由内的方法应进入 405 时的 Allow 头:
    //
    //     let sub = Router()
    //     sub.post("/items", h)
    //     app.use("/api", sub)
    //     // 客户端发 GET /api/items → 405,Allow 头必须含 POST
    //
    // 早先 methodsForPath 看不到子路由的方法,onExhausted 走 "methods 空 && hasAll
    // 为 false → 404" 分支。修后应回 405 且 Allow 头含 POST(RFC 7231 §6.5.5
    // 要求 405 必须给出准确 Allow)。
    @TestCase
    func testAllowHeaderIncludesSubRouterMethods(): Unit {
        let app = wen()
        let sub = Router()
        sub.post("/items", {_: HttpRequest, res: HttpResponse => res.send("ok")})
        app.use("/api", sub)
        let req = HttpRequest("GET", "/api/items")
        req.path = "/api/items"
        let res = HttpResponse()
        app.handle(req, res)
        @Assert(res.statusCode == 405)
        match (res.get("Allow")) {
            case Some(v) => @Assert(v.contains("POST"))
            case None => @Assert(false)
        }
    }

    // allowHeader 由 `s += ", " + m` O(n²) 改为累积 buffer。本测试覆盖多方法注册
    // 下 Allow 头的精确格式:方法间以 ", "(逗号空格)分隔,首尾不能多出 ", ",
    // 不能出现 ", ,"(空 token)或 ",,"(漏空格)。注册 POST/PUT/DELETE 时还会自
    // 动补 OPTIONS;因无 GET 故不补 HEAD — 四个方法 token = 三个分隔符。改 buffer
    // 实现的典型 bug 是首段误加分隔符或末段漏分隔符,这条会立即暴露。
    @TestCase
    func testAllowHeaderExactFormatNoDanglingSeparator(): Unit {
        let app = wen()
        app.post("/r", {_: HttpRequest, res: HttpResponse => res.send("ok")})
        app.put("/r", {_: HttpRequest, res: HttpResponse => res.send("ok")})
        app.delete("/r", {_: HttpRequest, res: HttpResponse => res.send("ok")})
        let req = HttpRequest("GET", "/r")
        req.path = "/r"
        let res = HttpResponse()
        app.handle(req, res)
        @Assert(res.statusCode == 405)
        match (res.get("Allow")) {
            case Some(v) =>
                @Assert(!v.startsWith(", "))
                @Assert(!v.endsWith(", "))
                @Assert(!v.contains(",,"))
                @Assert(!v.contains(", ,"))
                @Assert(v.contains("POST"))
                @Assert(v.contains("PUT"))
                @Assert(v.contains("DELETE"))
                @Assert(v.contains("OPTIONS"))
                @Assert(!v.contains("HEAD"))
                let parts = v.split(", ")
                @Assert(parts.size == 4)
                for (p in parts) {
                    @Assert(!p.isEmpty())
                }
            case None => @Assert(false)
        }
    }

    // stripMountPath / buildMountPrefix 由 `rebuilt += "/" + parts[i]` O(n²) 改为
    // ArrayList<UInt8>。本测试覆盖深挂载(3 段挂载前缀 + 余 2 段)下两件事:
    //   1) 子路由 handler 看到的 req.path 是剥前缀后的相对路径,精确为 "/items/list";
    //   2) req.baseUrl 是挂载前缀的精确重建,等于 app.use 的注册路径;
    // 改 buffer 实现的典型 bug 是丢首段斜杠(rebuilt 起手忘记 "/")或多写一段。
    @TestCase
    func testDeepMountStripPathAndBuildBaseUrl(): Unit {
        let app = wen()
        let sub = Router()
        let captured = ArrayList<String>()
        sub.get(
            "/items/list",
            {
                req: HttpRequest, res: HttpResponse =>
                    captured.add(req.path)
                    captured.add(req.baseUrl)
                    res.send("ok")
            }
        )
        app.use("/api/v1/store", sub)
        let req = HttpRequest("GET", "/api/v1/store/items/list")
        req.path = "/api/v1/store/items/list"
        let res = HttpResponse()
        app.handle(req, res)
        @Assert(res.statusCode == 200)
        @Assert(captured.size == 2)
        @Assert(captured[0] == "/items/list")
        @Assert(captured[1] == "/api/v1/store")
    }

    // stripMountPath 必须保留原路径尾斜杠 — 否则子路由 strict routing 完全失效。
    // 改 buffer 实现时,尾斜杠 if/else 分支若被漏写,这条会立即失败。
    @TestCase
    func testDeepMountStripPreservesTrailingSlash(): Unit {
        let app = wen()
        let sub = Router()
        let captured = ArrayList<String>()
        sub.get(
            "/items/",
            {
                req: HttpRequest, res: HttpResponse =>
                    captured.add(req.path)
                    res.send("ok")
            }
        )
        app.use("/api/v1/store", sub)
        let req = HttpRequest("GET", "/api/v1/store/items/")
        req.path = "/api/v1/store/items/"
        let res = HttpResponse()
        app.handle(req, res)
        @Assert(captured.size == 1)
        @Assert(captured[0] == "/items/")
    }
}
