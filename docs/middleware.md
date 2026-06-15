# 内置中间件参考

所有内置中间件都是返回 `Middleware` 的工厂函数,用 `app.use(...)` 注册;部分也可挂在
路由或路径前缀上。建议的注册顺序:压缩/ETag/安全等「横切关注点」靠前,业务路由靠后。

---

## logger() / logger(format)

每个请求**完成后**打一行,默认 `METHOD path status durationMs`。需要别的字段或上色时,
传入 `format` 函数(拿到 `req`、`res`、处理耗时毫秒,返回整行)自行排版——核心不为每个
字段塞开关。

```cangjie
app.use(logger())
// GET /users/1 200 3ms

// 自定义:加 IP、只打慢请求、上 ANSI 颜色……都由你决定
app.use(logger({ req, res, ms => "${req.method} ${req.path} ${res.statusCode} ${ms}ms ip=${req.clientIp()}" }))
```

## requestId(headerName! = "X-Request-Id")

为每个请求关联一个 ID:请求已带该头则沿用,否则生成随机 ID;写回响应头,`req.requestId()` 读取。

```cangjie
app.use(requestId())
app.get("/", { req, res => res.send(req.requestId() ?? "") })
```

## cors() / cors(origin)

加 `Access-Control-Allow-*` 头;`OPTIONS` 预检直接以 204 应答,不再下传。

```cangjie
app.use(cors())              // 允许任意来源
app.use(cors("https://a.com"))
```

## helmet(csp!, hsts!, frameOptions!, referrerPolicy!, noSniff!)

批量下发安全响应头(CSP、`X-Content-Type-Options`、HSTS、`X-Frame-Options`、`Referrer-Policy`、
跨源策略等)。具名参数可定制;字符串传空串、布尔传 false 表示不发送该头。

```cangjie
app.use(helmet())
app.use(helmet(hsts: false, frameOptions: "DENY"))
```

## compression(threshold! = 256)

按 `Accept-Encoding: gzip` 自动压缩文本类响应(达到阈值且能减小体积时),设
`Content-Encoding: gzip` 与 `Vary: Accept-Encoding`。基于自写 DEFLATE,零依赖。建议靠前注册。

```cangjie
app.use(compression())
```

## etag()

为 200 的 GET/HEAD 动态响应(`send/json/sendBytes`)按内容算 `ETag`;`If-None-Match` 命中
则回 304。已带 ETag(文件响应)或已压缩则跳过。建议放在 `compression()` 之后。

```cangjie
app.use(compression())
app.use(etag())
```

## basicAuth(verify, realm!) / bearerAuth(verify, realm!)

HTTP Basic / Bearer 认证。校验回调返回 `Bool`;失败回 401 + `WWW-Authenticate`。Basic 成功后
把用户名存入 `req.attribute("authUser")`。

```cangjie
app.get("/admin", [
    basicAuth({ u: String, p: String => u == "admin" && p == "secret" }),
    { _: HttpRequest, res: HttpResponse, _: Next => res.send("ok") }
])

app.get("/api", [
    bearerAuth({ t: String => t == "my-token" }),
    { _: HttpRequest, res: HttpResponse, _: Next => res.send("ok") }
])
```

## 请求体 / Cookie 解析(已内置,无需注册)

JSON、表单(`x-www-form-urlencoded`)、文件上传(`multipart/form-data`)、Cookie 的解析都是
**内置**的:框架在你**首次访问**对应数据时,按请求的 `Content-Type` 自动解析一次(空体 /
类型不匹配则什么都不做;结果会缓存)。因此**不需要**再 `app.use(...)` 任何解析中间件。

```cangjie
app.post("/u", { req, res =>
    let name = req.json()?.get("name")?.asString() ?? "?"   // JSON:自动解析
    res.send(name)
})

app.post("/upload", { req, res =>
    match (req.file("avatar")) {                            // multipart:自动解析
        case Some(f) => f.saveTo("./uploads/${f.filename}"); res.send("saved ${f.size()} bytes")
        case None => res.status(400).send("no file")
    }
})

app.get("/c", { req, res => res.send(req.cookie("sid") ?? "anon") })   // Cookie:自动解析
```

读取入口:JSON → `req.json()`;表单 / multipart 文本字段 → `req.attribute(name)`;上传文件 →
`req.file(name)` / `req.files`;Cookie → `req.cookie(name)` / `req.signedCookie(name)`。

> 仍保留 `jsonParser()` / `urlencodedParser()` / `multipart()` / `cookieParser()` 工厂(现在只是
> 「提前触发解析」的薄壳),以便在中间件链里显式表达意图——但通常不必。`textParser()` /
> `rawParser()` 处理非默认类型(纯文本 / 原始字节),仍需显式注册。

## session(store?)

会话:用签名的 `sid` Cookie 关联服务端会话数据。设置 `app.cookieSecret` 即可(Cookie 解析已内置)。
默认 `MemorySessionStore`(线程安全),可实现 `SessionStore` 接入外部存储。

> 📚 **扩展指南**: 如需将会话数据存储到 Redis、数据库等外部存储，请参考  
> [Session 存储扩展指南](./session-store-extensions.md)

```cangjie
app.cookieSecret = "change-me"
app.use(session())
app.get("/counter", { req, res =>
    match (req.session) {
        case Some(s) =>
            let n = (match (s.get("n")) { case Some(v) => parseInt(v); case None => 0 }) + 1
            s.set("n", "${n}")
            res.json(JsonObj().put("n", n).build())
        case None => res.send("no session")
    }
})
```

## staticFiles(root, index!, maxAge!, dotfiles!)

从 `root` 目录服务静态文件(GET/HEAD),二进制安全,自动带 `ETag`/`Last-Modified`/`Range`。
- `index`:目录默认页(默认 `index.html`)。
- `maxAge`:`>=0` 时加 `Cache-Control: public, max-age=N`。
- `dotfiles`:隐藏文件策略 `ignore`(默认)/`deny`(403)/`allow`。

```cangjie
app.use("/static", staticFiles("./public", maxAge: 3600))
```

---

## 自定义中间件

中间件就是一个 `(req, res, next)`:

```cangjie
app.use({ req: HttpRequest, _: HttpResponse, next: Next =>
    println("${req.method} ${req.path}")
    next()
})
```

错误处理中间件多一个异常参数,且只在有异常传播时运行:

```cangjie
app.use({ e: Exception, _: HttpRequest, res: HttpResponse, _: Next =>
    res.status(500).send(e.message)
})
```
