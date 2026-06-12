# Wen

**Wen**(文)—— 一个用华为仓颉(Cangjie)编程语言编写的、类 Express 风格的轻量级
Web 框架。名取「文」:既呼应仓颉造字,也契合 HTTP 这一文本协议。

特点:**纯标准库、零第三方依赖**(JSON、HMAC-SHA256 等均为自带实现),API 风格贴近
Express,源码注释为详细中文。

这是 `wen` 库本体仓库(可作为 cjpm 依赖直接引用)。

## 作为依赖使用

在你的模块 `cjpm.toml` 中加入 git 依赖:

```toml
[dependencies]
  wen = { git = "https://github.com/mtpkiss/wen.git", branch = "main" }
```

## 最简示例

```cangjie
package demo

import wen.*

main(): Int64 {
    let app = wen()

    app.use(logger())
    app.use(cors())

    app.get("/", { _: HttpRequest, res: HttpResponse =>
        res.send("Hello from Wen!")
    })

    // 类型化 JSON(内置零依赖 JsonValue / JsonObj 构建器)
    app.get("/users/:id(\\d+)", { req: HttpRequest, res: HttpResponse =>
        let id = match (req.param("id")) { case Some(v) => v; case None => "?" }
        res.json(JsonObj().put("id", id).build())
    })

    app.listen(8080, { => println("Wen listening on http://localhost:8080") })
    return 0
}
```

## 完整示例

下面这份示例较全面地覆盖了各项能力(注释里给出了对应的 `curl` 调用):

```cangjie
package demo

import wen.*

main(): Int64 {
    let app = wen()

    // ---- 全局中间件 ---------------------------------------------------------
    app.use(logger())
    app.use(helmet())           // 安全响应头(CSP / nosniff / HSTS / 防点击劫持等)
    app.use(cors())
    app.use(jsonParser())
    app.use(urlencodedParser())
    app.use(multipart())
    app.use(cookieParser())
    app.cookieSecret = "change-me-in-production"   // 签名 Cookie / session 的 HMAC 密钥
    app.use(session())                              // 会话(默认进程内存存储)

    // 参数预处理(app.param):任何匹配到 :id 的路由,在其处理器执行前先把
    // "user-<id>" 预存到请求属性里(实际项目里常用于按 id 加载用户/记录)。
    app.param("id", { req: HttpRequest, _: HttpResponse, value: String =>
        req.attributes["loadedUser"] = "user-${value}"
    })

    // ---- 路由(终结式 Handler 写法,无需 next)------------------------------

    // 纯文本响应。
    app.get("/", { _: HttpRequest, res: HttpResponse =>
        res.send("Hello from Wen!")
    })

    // 路径参数:/users/:id —— 用 req.param("id") 读取捕获到的值。
    app.get("/users/:id", { req: HttpRequest, res: HttpResponse =>
        let id = match (req.param("id")) {
            case Some(value) => value
            case None => "unknown"
        }
        res.json("{\"id\":\"${id}\"}")
    })

    // 多处理器路由(前置鉴权中间件 + 业务处理器):前者校验 token,通过才 next():
    //   curl http://localhost:8080/admin                    # 401 unauthorized
    //   curl 'http://localhost:8080/admin?token=secret'     # admin dashboard
    app.get("/admin", [
        { req: HttpRequest, res: HttpResponse, next: Next =>
            match (req.queryParam("token")) {
                case Some(t) => if (t == "secret") { next() } else { res.status(401).send("unauthorized") }
                case None => res.status(401).send("unauthorized")
            }
        },
        { _: HttpRequest, res: HttpResponse, _: Next => res.send("admin dashboard") }
    ])

    // 可选参数 :page?:/posts 与 /posts/2 都命中同一处理器。
    //   curl http://localhost:8080/posts        -> {"page":"1"}
    //   curl http://localhost:8080/posts/2      -> {"page":"2"}
    app.get("/posts/:page?", { req: HttpRequest, res: HttpResponse =>
        let page = match (req.param("page")) { case Some(v) => v; case None => "1" }
        res.json(JsonObj().put("page", page).build())
    })

    // 视图渲染(res.render):用内置 {{ key }} 引擎渲染 ./views/hello.html。
    // 先创建 ./views/hello.html,例如:<h1>你好,{{ name }}!</h1>
    //   curl 'http://localhost:8080/hello?name=世界'  -> <h1>你好,世界!</h1>
    app.get("/hello", { req: HttpRequest, res: HttpResponse =>
        let name = match (req.queryParam("name")) { case Some(v) => v; case None => "Wen" }
        res.render("hello", JsonObj().put("name", name).build())
    })

    // 内容协商(res.format):同一资源按客户端 Accept 头的 q 值挑最合适的表示。
    //   curl -H 'Accept: application/json' http://localhost:8080/info  -> {"name":"Wen"}
    //   curl -H 'Accept: text/html'        http://localhost:8080/info  -> <h1>Wen</h1>
    //   curl -H 'Accept: text/plain'       http://localhost:8080/info  -> Wen(default 兜底)
    app.get("/info", { _: HttpRequest, res: HttpResponse =>
        res.format([
            ("html", { => res.send("<h1>Wen</h1>") }),
            ("json", { => res.json(JsonObj().put("name", "Wen").build()) }),
            ("default", { => res.send("Wen") })
        ])
    })

    // UTF-8 路径参数 —— 多字节序列能被完整解码:
    //   curl --path-as-is 'http://localhost:8080/u/%E4%B8%AD'  -> {"name":"中"}
    app.get("/u/:name", { req: HttpRequest, res: HttpResponse =>
        let name = match (req.param("name")) { case Some(v) => v; case None => "?" }
        res.json("{\"name\":\"${name}\"}")
    })

    // 原始二进制响应 —— 字节原样发送,不经会破坏内容的 UTF-8 编解码往返:
    //   curl -s http://localhost:8080/ping.png | xxd | head
    app.get("/ping.png", { _: HttpRequest, res: HttpResponse =>
        res.contentType("image/png").sendBytes(
            [UInt8(137), UInt8(80), UInt8(78), UInt8(71), UInt8(13), UInt8(10), UInt8(255), UInt8(200)])
    })

    // 204 No Content —— 序列化时不带响应体、也不带 Content-Length 头:
    //   curl -i -X DELETE http://localhost:8080/items/1
    app.delete("/items/:id", { _: HttpRequest, res: HttpResponse =>
        res.status(204).end()
    })

    // 用内置的 JsonValue/JsonObj 做类型化 JSON 序列化:
    //   curl http://localhost:8080/profile  -> {"id":7,"name":"张三","admin":false}
    app.get("/profile", { _: HttpRequest, res: HttpResponse =>
        res.json(JsonObj()
            .put("id", 7)
            .put("name", "张三")
            .put("admin", false)
            .build())
    })

    // 解析 JSON 请求体并读取其中字段(jsonParser + req.json()):
    //   curl -X POST http://localhost:8080/greet \
    //        -H 'Content-Type: application/json' -d '{"name":"李四"}'
    //   -> {"hello":"李四"}
    app.post("/greet", { req: HttpRequest, res: HttpResponse =>
        let name = match (req.json()) {
            case Some(j) => match (j.get("name")) {
                case Some(v) => v.asString() ?? "?"
                case None => "?"
            }
            case None => "?"
        }
        res.json(JsonObj().put("hello", name).build())
    })

    // 文件上传(multipart/form-data):文本字段经 req.attribute 取,
    // 文件经 req.file(字段名) 取(可 saveTo 落盘)。
    //   curl -F 'title=头像' -F 'avatar=@./logo.png' http://localhost:8080/upload
    app.post("/upload", { req: HttpRequest, res: HttpResponse =>
        let title = match (req.attribute("title")) { case Some(v) => v; case None => "" }
        match (req.file("avatar")) {
            case Some(f) =>
                res.json(JsonObj()
                    .put("title", title)
                    .put("filename", f.filename)
                    .put("contentType", f.contentType)
                    .put("size", f.size())
                    .build())
            case None =>
                res.status(400).json(JsonObj().put("error", "缺少文件字段 avatar").build())
        }
    })

    // Express 风格的 app.route(path):把多个 HTTP 动词绑定到同一路径上。
    app.route("/book")
       .get({ _: HttpRequest, res: HttpResponse =>
           res.json("{\"action\":\"list\"}")
       })
       .post({ req: HttpRequest, res: HttpResponse =>
           res.status(201).json(req.body)
       })

    // 会话(session):访问计数存在服务端会话里,浏览器只持有签名的 sid Cookie。
    //   curl -c jar -b jar http://localhost:8080/counter   # count 逐次递增
    app.get("/counter", { req: HttpRequest, res: HttpResponse =>
        var n = 0
        match (req.session) {
            case Some(s) =>
                n = match (s.get("count")) { case Some(v) => parseInt(v) + 1; case None => 1 }
                s.set("count", "${n}")
            case None => ()
        }
        res.json(JsonObj().put("count", n).build())
    })

    // 签名 Cookie:写入时 HMAC 签名、读取时验签,客户端改不动。
    //   curl -c jar http://localhost:8080/sign  &&  curl -b jar http://localhost:8080/verify
    app.get("/sign", { _: HttpRequest, res: HttpResponse =>
        res.cookie("uid", "42", httpOnly: true, signed: true).send("signed")
    })
    app.get("/verify", { req: HttpRequest, res: HttpResponse =>
        let v = match (req.signedCookie("uid")) { case Some(x) => x; case None => "tampered-or-absent" }
        res.send(v)
    })

    // 用 res.sendFile 发送单个文件 —— 自带 ETag / Last-Modified / Range 支持:
    //   curl -i http://localhost:8080/home                              # 200 + ETag + Last-Modified
    //   curl -i -H 'If-None-Match: "<上一步的ETag>"' .../home            # 304 Not Modified
    //   curl -i -H 'If-Modified-Since: <上一步的Last-Modified>' .../home  # 304 Not Modified
    //   curl -i -H 'Range: bytes=0-99' http://localhost:8080/home       # 206 Partial Content
    app.get("/home", { _: HttpRequest, res: HttpResponse =>
        res.sendFile("./public/index.html")
    })

    // 附件下载(res.download):带 Content-Disposition,浏览器弹出保存对话框;
    // 因走 sendFile,同样二进制安全并支持 Range 断点续传。
    //   curl -OJ http://localhost:8080/report
    app.get("/report", { _: HttpRequest, res: HttpResponse =>
        res.download("./public/index.html", "report.html")
    })

    // 代理感知的请求信息(req.protocol/secure/clientIp/hostname/xhr)。
    // 需配合下方 app.trustProxy = true 才会采信 X-Forwarded-* 头:
    //   curl -H 'X-Forwarded-Proto: https' -H 'X-Forwarded-For: 1.1.1.1' \
    //        -H 'X-Requested-With: XMLHttpRequest' http://localhost:8080/whoami
    app.get("/whoami", { req: HttpRequest, res: HttpResponse =>
        let host = match (req.hostname()) { case Some(h) => h; case None => "" }
        res.json(JsonObj()
            .put("protocol", req.protocol())
            .put("secure", req.secure())
            .put("clientIp", req.clientIp())
            .put("hostname", host)
            .put("xhr", req.xhr())
            .build())
    })

    // Server-Sent Events(服务器推送事件):推送几条事件后结束(浏览器会自动重连)。
    app.get("/events", { _: HttpRequest, res: HttpResponse =>
        res.sse({ s: SseWriter =>
            var i = 1
            while (i <= 3) {
                s.event("tick", "count ${i}")
                i += 1
            }
            s.send("done")
        })
    })

    // 可挂载的子路由(「迷你应用」),对应 express.Router()。
    let birds = Router()
    birds.use({ req: HttpRequest, _: HttpResponse, next: Next =>
        println("[birds] ${req.method} ${req.path}")
        next()
    })
    birds.get("/", { _: HttpRequest, res: HttpResponse => res.send("Birds home page") })
    birds.get("/about", { _: HttpRequest, res: HttpResponse => res.send("About birds") })
    app.use("/birds", birds)

    // ---- 静态文件 -----------------------------------------------------------
    app.use("/static", staticFiles("./public"))

    // 集中式错误处理(最后注册)—— 把抛出的异常统一转成 JSON 响应。
    app.use({ e: Exception, _: HttpRequest, res: HttpResponse, _: Next =>
        res.status(500).json("{\"error\":\"${e.message}\"}")
    })

    // ---- 配置项 -------------------------------------------------------------
    app.maxConnections = 1024              // 并发连接上限(信号量背压)
    app.trustProxy = true                  // 信任前置反代的 X-Forwarded-* 头
    app.set("views", "./views")            // 视图根目录
    app.set("view engine", "html")         // 默认模板扩展名

    // ---- 启动服务器 ---------------------------------------------------------
    app.listen(8080, { =>
        println("Wen listening on http://localhost:8080")
    })

    return 0
}
```

## 能力一览

- **路由**:`get/post/put/delete/patch/head/options/all` 及终结式 `Handler`;命名参数
  `:param`、可选参数 `:param?`、内联正则约束 `:param(\d+)`、通配符 `*`;一条路径挂多个
  处理器(`[mw1, mw2]`)、`req.nextRoute()`(等价 Express 的 `next("route")`)跳过当前路由;
  `app.route(path)` 链式、`app.param(name, fn)` 参数预处理、可挂载子路由
  `app.use(path, Router)`(含 mergeParams);自动 `HEAD`/`OPTIONS`、`405 + Allow`。
- **中间件**:中间件链 `(req, res, next)`、全局/路径挂载、数组批量挂载、错误处理中间件
  `(err, req, res, next)`、`Plugin` 系统。内置:`logger / cors / helmet(安全头) /
  compression(gzip 压缩) / jsonParser / urlencodedParser / multipart(文件上传) /
  cookieParser / staticFiles / session`。
- **请求**:`headers/query/params/cookies`、字符串 `attributes` 与类型化 `locals`、
  `body/bodyBytes`、`json()`(解析后的 `JsonValue`)、`file(name)/files`(上传)、
  `signedCookie(name)`、`session`;`hostname()/isType()`、`accepts()` 与 `accepts([...])`
  (带 q 值的最佳匹配);代理感知 `protocol()/secure()/ips()/clientIp()/subdomains()/xhr()`
  (配合 `app.trustProxy`)。
- **响应**:`send/json/sendBytes/sendStatus/redirect/end`;`json` 支持字符串与类型化
  `JsonValue/JsonObj`;`cookie`(可 `signed` 签名)/`clearCookie`、`set` 批量、
  `mimeType/contentType/append/location`;`render`(视图渲染)、`format`(内容协商)、
  `attachment/download`(附件下载);流式 `stream` 与 Server-Sent Events `sse`。
- **文件与缓存**:`sendFile / download / staticFiles` 均**二进制安全**(原始字节,不经
  UTF-8 往返);自动 `ETag` + `If-None-Match` → 304、`Last-Modified` + `If-Modified-Since`
  → 304、`Range` 分片下载(206 / 416)。
- **JSON**:内置零依赖 `JsonValue`(对象保序)+ `parseJson` + `toJsonString` + `JsonObj`
  链式构建器,访问器 `asString/asInt/asFloat/asBool/get/at/size/keys`;正确处理转义、
  `\u` 与代理对。
- **视图渲染**:`res.render` + `app.engine(ext, fn)` + `app.set("views"/"view engine")`;
  内置极简 `{{ key }}` 模板引擎(支持 `a.b.c` 嵌套字段、默认 HTML 转义防注入),也可
  接入任意第三方引擎。
- **会话与安全**:HMAC-SHA256 **签名 Cookie**、`session()`(默认线程安全的内存存储,
  可实现 `SessionStore` 接入 Redis/DB)、`helmet()` 一组安全响应头(CSP / nosniff /
  HSTS / 防点击劫持等)。
- **服务器**:基于标准库 `std.net`,**零第三方依赖**;HTTP/1.1 keep-alive、chunked
  请求体、并发连接上限(信号量背压)、请求体大小上限与读超时;请求走私防护
  (同时带 Content-Length 与 Transfer-Encoding → 400)、`204/304` 不带响应体与
  Content-Length。

## 构建与测试

```bash
cjpm build
cjpm test
```

## License

MIT,详见 [LICENSE](LICENSE)。
