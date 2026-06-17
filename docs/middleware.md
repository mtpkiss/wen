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

## etag()

为 200 的 GET/HEAD 动态响应(`send/json/sendBytes`)按内容算 `ETag`;`If-None-Match` 命中
则回 304。已带 ETag(文件响应)或已带 `Content-Encoding`(如被边缘压缩)则跳过。

```cangjie
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

## methodOverride(headerName! = "X-HTTP-Method-Override") / methodOverrideField(field! = "_method")

让 HTML 表单(只能发 GET / POST)借助一个请求头、隐藏字段或查询串把方法改写为
`PUT` / `DELETE` / `PATCH`,从而复用同一套 RESTful 路由。

- `methodOverride()` 从请求头读取(默认 `X-HTTP-Method-Override`),适合 AJAX / 网关;
  头值含多个时取第一个。
- `methodOverrideField()` 从表单字段(优先)或查询串读取(默认 `_method`),适合 HTML 表单。

安全约束(与 Express 一致):**仅当原始方法为 POST 时**才允许重写——`GET` 等安全方法
不应被悄悄改成有副作用的动词;目标必须是已知 HTTP 方法,否则忽略。重写发生时,原方法
存入 `req.attribute("originalMethod")` 备查。两者都应在「路由注册之前」用 `app.use(...)`
挂为全局中间件,这样路由匹配时看到的已是重写后的方法。

```cangjie
app.use(methodOverride())          // 读 X-HTTP-Method-Override 头
app.use(methodOverrideField())     // 读 _method 字段 / 查询串

app.delete("/items/:id", { req, res =>
    let om = req.attribute("originalMethod") ?? "?"   // 通常是 "POST"
    res.send("deleted ${req.param("id") ?? "?"} (was ${om})")
})
```

## csrf(cookieName!, field!, signed!, httpOnly!, secure!, sameSite!)

对应 Express 生态的 csurf,采用**签名双提交 Cookie**。服务端为浏览器签发一个随机 token,
经 HMAC 签名的 Cookie(默认 `_csrf`,`HttpOnly` + `SameSite=Lax`)下发;对**非安全方法**
(POST/PUT/PATCH/DELETE)的请求,必须通过另一渠道回传同一 token——请求头 `X-CSRF-Token` /
`X-XSRF-Token`,或表单字段 / 查询串 `_csrf`。两者一致才放行,否则回 403。

- 安全方法(GET/HEAD/OPTIONS)只确保 token 存在并下发 Cookie,不做校验;token 暴露到
  `req.attribute("csrfToken")`,把它渲染进表单隐藏字段 / 页面 meta 标签,供后续请求回传。
- `signed=true`(默认)需先设 `app.cookieSecret`;设为 `false` 则为朴素双提交,便于前端 JS
  直接读 Cookie 回填请求头,但失去防 Cookie 篡改能力。

```cangjie
app.cookieSecret = "change-me"
app.use(csrf())

app.get("/form", { req, res =>
    let token = req.attribute("csrfToken") ?? ""
    res.send("<form method=POST action=/save>" +
        "<input type=hidden name=_csrf value=\"${token}\">" +
        "<input name=note><button>save</button></form>")
})
app.post("/save", { _, res => res.send("saved") })   // 校验通过才会到这里
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
