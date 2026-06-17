package bench

import wen.*
import std.collection.*
import std.time.*

/*
 * Wen 框架微基准(micro-benchmark)。
 *
 * 度量的是「用户真正会高频触达的公开 API」的单次耗时:对象分配、路由匹配、请求
 * 派发、JSON 编解码、URL/Base64 编解码。不含 socket I/O —— 网络吞吐请用外部压测
 * 工具(见 README)对真实跑起来的服务器施压。
 *
 * 方法:每项先跑 warmup 轮(不计时,预热分配器/缓存),再跑 N 轮计时,用单调时钟
 * MonoTime 量总耗时,折算成 ns/op 与 ops/s。每轮都把结果汇入一个 sink 并最终打印,
 * 防止优化器把「结果没人用」的循环体整段消除(dead-code elimination)。
 */

// ---- 计时与格式化 ----------------------------------------------------------

func runBench(name: String, n: Int64, warmup: Int64, body: () -> Int64): Int64 {
    var acc = 0
    var w = 0
    while (w < warmup) {
        acc ^= body() + w
        w += 1
    }
    let start = MonoTime.now()
    var i = 0
    while (i < n) {
        // 把循环下标折进 sink:既防止优化器认定结果无人使用而消除循环体,
        // 也避免「常量返回值 XOR 偶数次恰好抵消为 0」造成 sink 失真。
        acc ^= body() + i
        i += 1
    }
    let totalNs = (MonoTime.now() - start).toNanoseconds()
    let nsPerOp = Float64(totalNs) / Float64(n)
    let opsPerSec = if (nsPerOp > 0.0) { Int64(1000000000.0 / nsPerOp) } else { 0 }
    println(padRight(name, 34) + padLeft(groupThousands(n), 12) +
            padLeft(fmt2(nsPerOp) + " ns", 16) + padLeft(groupThousands(opsPerSec) + "/s", 18))
    return acc
}

func section(title: String): Unit {
    println("")
    println(title)
    println("--------------------------------------------------------------------------------")
}

func padRight(s: String, w: Int64): String {
    var out = s
    var k = s.size
    while (k < w) {
        out += " "
        k += 1
    }
    return out
}

func padLeft(s: String, w: Int64): String {
    var out = ""
    var k = s.size
    while (k < w) {
        out += " "
        k += 1
    }
    return out + s
}

// 千位分隔,例如 1234567 -> "1,234,567"。
func groupThousands(n: Int64): String {
    if (n < 0) {
        return "-" + groupThousands(-n)
    }
    let s = n.toString()
    let len = s.size
    var out = ""
    var i = 0
    while (i < len) {
        if (i > 0 && (len - i) % 3 == 0) {
            out += ","
        }
        out += s[i..(i + 1)]
        i += 1
    }
    return out
}

// 保留两位小数(四舍五入)。
func fmt2(f: Float64): String {
    var x = f
    if (x < 0.0) {
        x = 0.0
    }
    let scaled = Int64(x * 100.0 + 0.5)
    let intPart = scaled / 100
    let frac = scaled % 100
    var fracStr = frac.toString()
    if (frac < 10) {
        fracStr = "0" + fracStr
    }
    return intPart.toString() + "." + fracStr
}

// 构造一个含 k 条静态路由(/r0../r{k-1})的应用,用于度量「路由表规模 → 派发耗时」。
func buildAppWithRoutes(k: Int64): Application {
    let app = wen()
    var j = 0
    while (j < k) {
        app.get("/r${j}", { _: HttpRequest, res: HttpResponse => res.send("ok") })
        j += 1
    }
    return app
}

main(): Int64 {
    // 各项迭代次数:越快的操作给越多轮,使总计时落在易测量的区间。
    let nFast = 500000
    let nMed = 200000
    let nDispatch = 100000
    let nSlow = 50000
    let warm = 10000

    var sink = 0

    println("================================================================================")
    println(" Wen 框架微基准  (cjc 1.1.3 cjnative, release)")
    println("================================================================================")
    println(padRight("benchmark", 34) + padLeft("iters", 12) + padLeft("ns/op", 16) + padLeft("ops/sec", 18))

    // ---- 0. 标尺 -----------------------------------------------------------
    // 给后面的数字提供参照系:noop 是「闭包调用 + 计时循环」的纯开销地板;单个
    // HashMap 分配是 Cangjie 集合分配的单位成本 —— 对象构造/派发耗时基本是它的倍数。
    section("0. 标尺 (解读其余数字的参照)")
    sink += runBench("noop (闭包调用基线)", nFast, warm, {
        => 1
    })
    sink += runBench("单个 HashMap<String,String> 分配", nFast, warm, {
        =>
        HashMap<String, String>().size
    })

    // ---- 1. 对象分配 -------------------------------------------------------
    // 每个请求都要新建 HttpRequest(内含 6 张 HashMap + 多个 ArrayList/Array)与
    // HttpResponse。这是派发耗时的「地板价」,单列出来便于看清派发里有多少花在纯分配上。
    section("1. 对象分配 (每请求必付)")
    sink += runBench("HttpRequest + HttpResponse 构造", nFast, warm, {
        =>
        let req = HttpRequest("GET", "/")
        let res = HttpResponse()
        req.path.size + res.statusCode
    })

    // ---- 2. 路由匹配(纯匹配器,不含派发)---------------------------------
    let pStatic = PathPattern.compile("/users/profile/settings")
    let pParam = PathPattern.compile("/users/:id/posts/:pid")
    let pWild = PathPattern.compile("/files/*")
    section("2. 路由匹配 (PathPattern.matchExact)")
    sink += runBench("静态三段 /users/profile/settings", nFast, warm, {
        =>
        match (pStatic.matchExact("/users/profile/settings")) {
            case Some(m) => m.size
            case None => -1
        }
    })
    sink += runBench("双参数 /users/:id/posts/:pid", nFast, warm, {
        =>
        match (pParam.matchExact("/users/42/posts/99")) {
            case Some(m) => m.size
            case None => -1
        }
    })
    sink += runBench("通配 /files/*", nFast, warm, {
        =>
        match (pWild.matchExact("/files/img/logo.png")) {
            case Some(m) => m.size
            case None => -1
        }
    })
    sink += runBench("pathSegments 拆分(5 段)", nFast, warm, {
        =>
        pathSegments("/api/v1/users/42/posts").size
    })

    // ---- 3. 请求派发(app.handle:匹配 + 处理器执行)----------------------
    let appSmall = wen()
    appSmall.get("/", { _: HttpRequest, res: HttpResponse => res.send("hi") })
    appSmall.get("/users/:id", { _: HttpRequest, res: HttpResponse => res.send("u") })
    appSmall.get("/users/profile/settings", { _: HttpRequest, res: HttpResponse => res.send("s") })
    appSmall.get("/users/:id/posts/:pid", { req: HttpRequest, res: HttpResponse =>
        let id = match (req.param("id")) { case Some(v) => v; case None => "?" }
        res.json(JsonObj().put("id", id).build())
    })
    appSmall.post("/echo", { req: HttpRequest, res: HttpResponse => res.json(req.body) })

    section("3. 请求派发 (app.handle = 匹配 + 处理器)")
    sink += runBench("派发 静态命中", nDispatch, warm, {
        =>
        let req = HttpRequest("GET", "/users/profile/settings")
        let res = HttpResponse()
        appSmall.handle(req, res)
        res.statusCode + res.body.size
    })
    sink += runBench("派发 双参数命中 + JSON", nDispatch, warm, {
        =>
        let req = HttpRequest("GET", "/users/42/posts/99")
        let res = HttpResponse()
        appSmall.handle(req, res)
        res.statusCode + res.body.size
    })
    sink += runBench("派发 未命中 (404)", nDispatch, warm, {
        =>
        let req = HttpRequest("GET", "/nope/nope")
        let res = HttpResponse()
        appSmall.handle(req, res)
        res.statusCode
    })

    // 路由表规模对派发的影响。trie 索引让命中耗时与规模解耦:1/10/50/100/500 条命中
    // 最后一条应当几乎等耗时(派发为 O(M+K),M=请求段数、K=候选数,与总路由数无关)。
    let app1 = buildAppWithRoutes(1)
    let app10 = buildAppWithRoutes(10)
    let app50 = buildAppWithRoutes(50)
    let app100 = buildAppWithRoutes(100)
    let app500 = buildAppWithRoutes(500)
    section("4. 路由表规模 → 派发耗时 (trie 索引:命中应与规模解耦)")
    sink += runBench("1 条路由 (命中)", nDispatch, warm, {
        =>
        let req = HttpRequest("GET", "/r0")
        let res = HttpResponse()
        app1.handle(req, res)
        res.statusCode
    })
    sink += runBench("10 条路由 (命中最后)", nDispatch, warm, {
        =>
        let req = HttpRequest("GET", "/r9")
        let res = HttpResponse()
        app10.handle(req, res)
        res.statusCode
    })
    sink += runBench("50 条路由 (命中最后)", nSlow, warm, {
        =>
        let req = HttpRequest("GET", "/r49")
        let res = HttpResponse()
        app50.handle(req, res)
        res.statusCode
    })
    sink += runBench("100 条路由 (命中最后)", nSlow, warm, {
        =>
        let req = HttpRequest("GET", "/r99")
        let res = HttpResponse()
        app100.handle(req, res)
        res.statusCode
    })
    sink += runBench("500 条路由 (命中最后)", nSlow, warm, {
        =>
        let req = HttpRequest("GET", "/r499")
        let res = HttpResponse()
        app500.handle(req, res)
        res.statusCode
    })
    // 500 条路由下的 404:trie 直接返回空候选,不再扫全表,也应与规模无关。
    sink += runBench("500 条路由 (未命中 404)", nSlow, warm, {
        =>
        let req = HttpRequest("GET", "/nope")
        let res = HttpResponse()
        app500.handle(req, res)
        res.statusCode
    })

    // ---- 4a. 典型中间件链开销(贴近真实业务管线)---------------------------
    // logger 会 println 到 stdout,在 bench 里会产生 I/O 噪声,这里不挂;其余 4 个中间件
    // 是动态响应里最常并用的横切关注点。
    let appMw = wen()
    appMw.use(requestId())
    appMw.use(cors())
    appMw.use(helmet())
    appMw.use(etag())
    appMw.get("/hi", {_: HttpRequest, res: HttpResponse => res.send("hi")})
    section("4a. 典型中间件链 (requestId + cors + helmet + etag) 派发")
    sink += runBench("命中 + 4 中间件链", nDispatch, warm, {
        =>
        let req = HttpRequest("GET", "/hi")
        let res = HttpResponse()
        appMw.handle(req, res)
        res.statusCode + res.body.size
    })

    // ---- 5. JSON 序列化 ----------------------------------------------------
    section("5. JSON 序列化 (JsonObj -> String)")
    sink += runBench("小对象 (3 字段)", nMed, warm, {
        =>
        JsonObj().put("id", 7).put("name", "张三").put("admin", false).build().toJsonString().size
    })
    sink += runBench("中对象 (5 字段 + 数组)", nMed, warm, {
        =>
        let tags = ArrayList<JsonValue>()
        tags.add(jsonOf("a"))
        tags.add(jsonOf("b"))
        tags.add(jsonOf("c"))
        JsonObj()
            .put("id", 100)
            .put("name", "wen-framework")
            .put("tags", jsonArray(tags))
            .put("score", 9.5)
            .put("active", true)
            .build()
            .toJsonString()
            .size
    })

    // ---- 6. JSON 解析 ------------------------------------------------------
    let jSmall = "{\"id\":7,\"name\":\"Alice\",\"admin\":false}"
    let jMedium = "[{\"id\":1,\"name\":\"Alice\",\"roles\":[\"admin\",\"user\"]}," +
                  "{\"id\":2,\"name\":\"Bob\",\"roles\":[\"user\"]}," +
                  "{\"id\":3,\"name\":\"Carol\",\"roles\":[\"user\",\"editor\"]}]"
    section("6. JSON 解析 (String -> JsonValue)")
    sink += runBench("小文档 (3 字段)", nMed, warm, {
        =>
        parseJson(jSmall).size()
    })
    sink += runBench("中文档 (3 对象数组)", nSlow, warm, {
        =>
        parseJson(jMedium).size()
    })
    sink += runBench("解析 + 再序列化 往返", nSlow, warm, {
        =>
        parseJson(jMedium).toJsonString().size
    })

    // ---- 7. URL / Base64 编解码 -------------------------------------------
    let raw = Array<UInt8>(48, repeat: 0)
    var bi = 0
    while (bi < 48) {
        raw[bi] = UInt8((bi * 7 + 3) % 256)
        bi += 1
    }
    let b64 = base64Encode(raw)
    section("7. URL / Base64 编解码")
    sink += runBench("urlDecode ASCII", nFast, warm, {
        =>
        urlDecode("a%20b+c%2Fd%3De").size
    })
    sink += runBench("urlDecode UTF-8 (你好世界)", nMed, warm, {
        =>
        urlDecode("%E4%BD%A0%E5%A5%BD%E4%B8%96%E7%95%8C").size
    })
    sink += runBench("base64 编码 (48B)", nMed, warm, {
        =>
        base64Encode(raw).size
    })
    sink += runBench("base64 解码 (64ch)", nMed, warm, {
        =>
        base64Decode(b64).size
    })

    println("")
    println("================================================================================")
    println("完成。sink=${sink}  (仅用于阻止死代码消除,无业务含义)")
    return 0
}
