package urlshorten

import wen.*
import std.collection.*
import std.sync.*
import std.random.*
import std.time.*

/*
 * 真实场景示例:URL 短链服务(wen-url)。
 *
 * 选这个场景是因为它接地气、能自然把 wen 的主线能力都串起来:JSON 体解析、参数路由、
 * 类型化 JSON 响应、302 重定向、Bearer Token 鉴权、Server-Sent Events 实时推送、
 * 集中式错误处理,以及 logger/helmet/cors/requestId 这一组生产里基本必挂的中间件。
 *
 * 路由清单:
 *   GET    /                            最朴素的提交表单页(HTML)
 *   POST   /api/links                   创建短链;JSON body {"url":"...","code":"自定义?"}
 *   GET    /api/links                   列出所有短链
 *   GET    /api/links/:code             查询单条短链的元信息(含累计点击数)
 *   DELETE /api/links/:code             删除短链 —— 需要 Bearer Token
 *   GET    /api/links/:code/stream      SSE,实时推送当前点击数(每秒一次,推 10 次)
 *   GET    /:code                       短码命中:302 重定向到原 URL,并累加点击数
 *
 * 存储是进程内 HashMap + Mutex —— 仅用于演示。真实生产请换 Redis/DB。
 */

// ---- 数据模型 -------------------------------------------------------------

class Link {
    public let code: String
    public let target: String
    public var clicks: Int64
    public let createdAt: String

    init(code: String, target: String, createdAt: String) {
        this.code = code
        this.target = target
        this.clicks = 0
        this.createdAt = createdAt
    }
}

// ---- 进程内存储 ------------------------------------------------------------

class LinkStore {
    let data = HashMap<String, Link>()
    let lock = Mutex()
    let rng = Random()

    public init() {}

    // 6 位十六进制随机短码;碰撞时换一个。
    func newCode(): String {
        let hex = "0123456789abcdef".toArray()
        var v = rng.nextUInt64()
        let buf = Array<UInt8>(6, repeat: 0)
        var i = 0
        while (i < 6) {
            buf[i] = hex[Int64(v % 16u64)]
            v >>= 4
            i += 1
        }
        return String.fromUtf8(buf)
    }

    public func create(target: String, prefer: ?String): Link {
        lock.lock()
        try {
            var code = match (prefer) {
                case Some(c) => c
                case None => newCode()
            }
            while (true) {
                match (data.get(code)) {
                    case Some(_) => code = newCode()
                    case None => break
                }
            }
            let link = Link(code, target, DateTime.now().toString())
            data[code] = link
            return link
        } finally {
            lock.unlock()
        }
    }

    public func get(code: String): ?Link {
        lock.lock()
        try {
            return data.get(code)
        } finally {
            lock.unlock()
        }
    }

    public func remove(code: String): Bool {
        lock.lock()
        try {
            match (data.get(code)) {
                case Some(_) =>
                    data.remove(code)
                    return true
                case None => return false
            }
        } finally {
            lock.unlock()
        }
    }

    // 把指定短码的点击数 +1,返回新的点击数;短码不存在返回 None。
    public func bump(code: String): ?Int64 {
        lock.lock()
        try {
            match (data.get(code)) {
                case Some(link) =>
                    link.clicks += 1
                    return Some(link.clicks)
                case None => return None
            }
        } finally {
            lock.unlock()
        }
    }

    public func clicksOf(code: String): ?Int64 {
        lock.lock()
        try {
            match (data.get(code)) {
                case Some(link) => return Some(link.clicks)
                case None => return None
            }
        } finally {
            lock.unlock()
        }
    }

    public func all(): ArrayList<Link> {
        lock.lock()
        try {
            let list = ArrayList<Link>()
            for ((_, l) in data) {
                list.add(l)
            }
            return list
        } finally {
            lock.unlock()
        }
    }
}

// ---- JSON 编码辅助 --------------------------------------------------------

func linkToJson(l: Link): JsonValue {
    return JsonObj()
        .put("code", l.code)
        .put("target", l.target)
        .put("clicks", l.clicks)
        .put("createdAt", l.createdAt)
        .build()
}

// 从请求 JSON 中取一个字符串字段;缺失或类型不对返回空串。
func readStringField(j: JsonValue, key: String): String {
    match (j.get(key)) {
        case Some(v) => match (v.asString()) {
            case Some(s) => return s
            case None => return ""
        }
        case None => return ""
    }
}

// 简陋的首页 —— 仅作演示,生产里这页应该走视图引擎(app.engine)或反代直出。
func homepageHtml(): String {
    return "<!doctype html><html><head><meta charset=\"utf-8\">" +
           "<title>wen-url</title></head><body>" +
           "<h1>wen-url</h1>" +
           "<p>POST <code>/api/links</code> with JSON <code>{\"url\":\"...\"}</code> to create a short link.</p>" +
           "<p>GET <code>/{code}</code> redirects to the original URL.</p>" +
           "<p>GET <code>/api/links/{code}/stream</code> opens an SSE stream of the click count.</p>" +
           "</body></html>"
}

main(): Int64 {
    let app = wen()
    let store = LinkStore()

    // ---- 全局中间件 ------------------------------------------------------
    app.use(requestId())
    app.use(logger())
    app.use(helmet())
    app.use(cors())

    // ---- 首页 ------------------------------------------------------------
    app.get("/", { _: HttpRequest, res: HttpResponse =>
        res.contentType("text/html; charset=utf-8").send(homepageHtml())
    })

    // ---- 创建短链 --------------------------------------------------------
    // curl -X POST -H 'Content-Type: application/json' \
    //      -d '{"url":"https://example.com/some/very/long/path"}' \
    //      http://localhost:8080/api/links
    app.post("/api/links", { req: HttpRequest, res: HttpResponse =>
        let body = match (req.json()) {
            case Some(j) => j
            case None =>
                res.status(400).json(JsonObj().put("error", "expect JSON body").build())
                return
        }
        let target = readStringField(body, "url")
        if (target.isEmpty()) {
            res.status(400).json(JsonObj().put("error", "missing 'url'").build())
            return
        }
        let prefer: ?String = match (body.get("code")) {
            case Some(v) => v.asString()
            case None => None
        }
        let link = store.create(target, prefer)
        res.status(201).json(JsonObj()
            .put("link", linkToJson(link))
            .put("shortUrl", "http://localhost:8080/${link.code}")
            .build())
    })

    // ---- 列出所有短链 ----------------------------------------------------
    // curl http://localhost:8080/api/links
    app.get("/api/links", { _: HttpRequest, res: HttpResponse =>
        let items = ArrayList<JsonValue>()
        for (l in store.all()) {
            items.add(linkToJson(l))
        }
        res.json(JsonObj()
            .put("items", JsonArray(items))
            .put("total", items.size)
            .build())
    })

    // ---- 查询单条短链 ----------------------------------------------------
    // curl http://localhost:8080/api/links/abc123
    app.get("/api/links/:code", { req: HttpRequest, res: HttpResponse =>
        let code = match (req.param("code")) { case Some(v) => v; case None => "" }
        match (store.get(code)) {
            case Some(link) => res.json(linkToJson(link))
            case None => res.status(404).json(JsonObj().put("error", "not found").build())
        }
    })

    // ---- 删除短链(Bearer Token 鉴权) ----------------------------------
    // curl -X DELETE -H 'Authorization: Bearer wen-url-admin' \
    //      http://localhost:8080/api/links/abc123
    app.delete("/api/links/:code", [
        bearerAuth({ token: String => token == "wen-url-admin" }),
        { req: HttpRequest, res: HttpResponse, _: Next =>
            let code = match (req.param("code")) { case Some(v) => v; case None => "" }
            if (store.remove(code)) {
                res.status(204).end()
            } else {
                res.status(404).json(JsonObj().put("error", "not found").build())
            }
        }
    ])

    // ---- SSE 实时点击数推送 ---------------------------------------------
    // curl -N http://localhost:8080/api/links/abc123/stream
    //
    // 实现细节:这里在 handler 里阻塞 10 秒,每秒推一帧。生产里如果短码很冷或在线
    // 用户多,应当走外部 pub/sub(Redis Pub/Sub、NATS 之类)而非 sleep 轮询。
    app.get("/api/links/:code/stream", { req: HttpRequest, res: HttpResponse =>
        let code = match (req.param("code")) { case Some(v) => v; case None => "" }
        match (store.get(code)) {
            case Some(_) => ()
            case None =>
                res.status(404).json(JsonObj().put("error", "not found").build())
                return
        }
        res.sse({ s: SseWriter =>
            var i = 0
            while (i < 10) {
                let n = match (store.clicksOf(code)) {
                    case Some(c) => c
                    case None => 0
                }
                s.event("clicks", "${n}")
                sleep(Duration.second)
                i += 1
            }
            s.send("end")
        })
    })

    // ---- 短码兜底重定向(注册顺序在前面具体路由之后)----------------------
    // curl -i http://localhost:8080/abc123
    app.get("/:code", { req: HttpRequest, res: HttpResponse =>
        let code = match (req.param("code")) { case Some(v) => v; case None => "" }
        match (store.bump(code)) {
            case Some(_) =>
                match (store.get(code)) {
                    case Some(link) => res.redirect(302, link.target)
                    case None => res.status(404).json(JsonObj().put("error", "no such code").build())
                }
            case None =>
                res.status(404).json(JsonObj().put("error", "no such code").build())
        }
    })

    // ---- 集中式错误处理 -------------------------------------------------
    app.use({ e: Exception, _: HttpRequest, res: HttpResponse, _: Next =>
        res.status(500).json(JsonObj().put("error", e.message).build())
    })

    app.listen(8080, { =>
        println("wen-url listening on http://localhost:8080")
    })
    return 0
}
