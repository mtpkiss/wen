# 内置中间件参考

所有内置中间件都是返回 `Middleware` 的工厂函数,用 `app.use(...)` 注册;部分也可挂在
路由或路径前缀上。建议的注册顺序:压缩/ETag/安全/限流等「横切关注点」靠前,业务路由靠后。

---

## logger()

打印每个请求的进/出一行(含最终状态码)。

```cangjie
app.use(logger())
// --> GET /users/1
// <-- GET /users/1 200
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

## rateLimit(max! = 60, windowSeconds! = 60)

固定时间窗口、按 `req.clientIp()` 限流;超额回 429 + `Retry-After`,每个响应带
`X-RateLimit-Limit/Remaining`。内存计数、线程安全。

```cangjie
app.use(rateLimit(max: 100, windowSeconds: 60))
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

## jsonParser() / urlencodedParser()

解析 `application/json` / `application/x-www-form-urlencoded` 请求体。JSON 解析到
`req.json()`(`?JsonValue`);表单字段进 `req.attribute(name)`。

```cangjie
app.use(jsonParser())
app.post("/u", { req, res =>
    let name = req.json()?.get("name")?.asString() ?? "?"   // 示意:逐层取值见 API 文档
    res.send(name)
})
```

## multipart()

解析 `multipart/form-data`(文件上传)。文本字段进 `req.attribute(name)`,文件进 `req.files`,
用 `req.file(name)` 取(`UploadedFile` 有 `filename/contentType/bytes/size()/text()/saveTo(path)`)。

```cangjie
app.use(multipart())
app.post("/upload", { req, res =>
    match (req.file("avatar")) {
        case Some(f) => f.saveTo("./uploads/${f.filename}"); res.send("saved ${f.size()} bytes")
        case None => res.status(400).send("no file")
    }
})
```

## cookieParser()

解析 `Cookie` 头到 `req.cookies`,用 `req.cookie(name)` 读取。配合 `app.cookieSecret` 与
`req.signedCookie(name)` 可读签名 Cookie。

```cangjie
app.use(cookieParser())
```

## session(store?)

会话:用签名的 `sid` Cookie 关联服务端会话数据。需先注册 `cookieParser()` 并设置
`app.cookieSecret`。默认 `MemorySessionStore`(线程安全),可实现 `SessionStore` 接入外部存储。

```cangjie
app.cookieSecret = "change-me"
app.use(cookieParser())
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
