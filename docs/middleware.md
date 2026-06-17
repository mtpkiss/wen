# 内置中间件参考

所有内置中间件都是返回 `Middleware` 的工厂函数,用 `app.use(...)` 注册;部分也可挂在
路由或路径前缀上。建议的注册顺序:ETag / 安全头 / 认证 / 方法重写 / CSRF 等「横切关注点」
靠前,业务路由靠后。

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

## helmet(csp!, hsts!, hstsMaxAge!, hstsIncludeSubDomains!, hstsPreload!, frameOptions!, referrerPolicy!, noSniff!, coop!, corp!)

批量下发安全响应头。设计取向:**默认只发部署无关、且不会误伤业务的头**;策略性强、易因
部署 / 内容打挂页面的头改为 opt-in(显式传值才发)。

**默认开**(`helmet()` 即发):
- `X-Content-Type-Options: nosniff`(`noSniff: true`)
- `X-Frame-Options: SAMEORIGIN`(`frameOptions: "SAMEORIGIN"`)
- `Referrer-Policy: no-referrer`(`referrerPolicy: "no-referrer"`)
- `Strict-Transport-Security: max-age=15552000; includeSubDomains`(`hsts: true`,180 天 + includeSubDomains,不带 preload)

**默认关**(需显式传值才开):
- `Content-Security-Policy`(`csp`):配错会挡掉外部脚本 / 样式 / 字体 / 图片。
- `Cross-Origin-Opener-Policy`(`coop`):隔离跨源窗口,会破坏 OAuth 弹窗等。
- `Cross-Origin-Resource-Policy`(`corp`):取 `same-origin` 会挡住别站加载你的资源(CDN / 嵌图)。

### HSTS 细调(`hstsMaxAge` / `hstsIncludeSubDomains` / `hstsPreload`)

| 参数 | 默认 | 说明 |
|---|---|---|
| `hstsMaxAge: Int64` | `15552000`(180 天) | 浏览器强制走 HTTPS 的有效期(秒)。提交 HSTS preload 列表前应改为 `31536000`(1 年) |
| `hstsIncludeSubDomains: Bool` | `true` | 是否对子域名生效 |
| `hstsPreload: Bool` | `false` | 是否带 `preload` 指令。**preload 提交被浏览器接受后不可撤销**(撤销可能耗时 1 年以上),且要求 `max-age ≥ 31536000` 与 `includeSubDomains: true`——框架不强制校验,默认关以免误开 |

```cangjie
app.use(helmet())
app.use(helmet(hsts: false, frameOptions: "DENY"))

// 生产 HSTS preload 标配:1 年 + includeSubDomains + preload。
app.use(helmet(hstsMaxAge: 31536000, hstsPreload: true))

// 显式开启 opt-in 头:
app.use(helmet(csp: "default-src 'self'", coop: "same-origin", corp: "same-origin"))
```

任何字符串参数传空串、或把布尔设为 `false`,均表示「不发送该头」。

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

> 仍保留 `jsonParser()` / `urlencodedParser()` / `cookieParser()` 工厂(现在只是
> 「提前触发解析」的薄壳),以便在中间件链里显式表达意图——但通常不必。
> `multipart(...)` 见下一节(配额与过滤)。`textParser()` / `rawParser()` 处理非默认
> 类型(纯文本 / 原始字节),仍需显式注册。

## multipart(maxFileSize!, maxFiles!, maxFields!, fileFilter!)

文件上传的**配额与过滤**。multipart 解析本身是内置的(`req.file(name)` 首次访问即触发);
本中间件的作用是给这次解析施加上限,以及白名单过滤。

| 参数 | 默认 | 行为 |
|---|---|---|
| `maxFileSize: Int64` | `-1`(不限) | 单文件最大字节数。超出 → 抛 `PayloadTooLargeException` → 默认 413 |
| `maxFiles: Int64` | `-1`(不限) | 文件总数上限。超出 → 413 |
| `maxFields: Int64` | `-1`(不限) | 字段总数上限(文件 + 文本一起算)。超出 → 413 |
| `fileFilter: ?(String, String, String) -> Bool` | `None` | 回调签名 `(fieldName, filename, contentType) -> 是否接受`;返回 `false` 的文件**静默丢弃**,不计入 `req.files` 也不算超额 |

**生效前提**:本中间件必须先于任何会触发 `req.ensureBody` 的代码注册(例如其它解析中间件、
认证中间件里如果读了 `req.attribute`,都会触发)。否则解析已完成,后塞入的选项不再生效
(`ensureBody` 是一次性闸门)。

```cangjie
// 头像上传:单文件 ≤ 2 MiB,至多 1 个文件,只接受 image/*。
app.use("/upload", multipart(
    maxFileSize: 2 * 1024 * 1024,
    maxFiles: 1,
    fileFilter: {
        _: String, _: String, ctype: String => ctype.startsWith("image/")
    }
))
app.post("/upload", { req, res =>
    match (req.file("avatar")) {
        case Some(f) => f.saveTo("./uploads/${f.filename}"); res.send("ok ${f.size()}")
        case None => res.status(400).send("no image file")
    }
})
```

> **413 与 fileFilter 的差异**:超额是协议层错误,框架直接 413,handler 不会执行;
> fileFilter 拒绝是业务策略,**静默丢弃**——handler 仍会执行,只是被拒文件不会进 `req.files`。
> 这与 multer 的语义一致。

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

## staticFiles(root, index!, maxAge!, dotfiles!, etag!, lastModified!, immutable!, setHeaders!, redirect!)

从 `root` 目录服务静态文件(GET/HEAD),**二进制安全**,自动带 `ETag` / `Last-Modified` /
`Range`,支持条件 GET(304)和分片下载(206 / 416)。

- `index`(默认 `"index.html"`):目录默认页;传空串表示禁用,目录请求交给 `next()`。
- `maxAge`(默认 `-1`):`>=0` 时加 `Cache-Control: public, max-age=N`,单位秒。
- `dotfiles`(默认 `"ignore"`):隐藏文件策略 —— `ignore` 当作不存在(交给 next),
  `deny` 返回 403,`allow` 正常服务。
- `etag`(默认 `true`):是否计算并下发 `ETag` 头。关闭后也不应答 `If-None-Match`。
- `lastModified`(默认 `true`):是否下发 `Last-Modified` 头(基于文件 mtime)。
- `immutable`(默认 `false`):`maxAge>0` 且本项为 `true` 时,`Cache-Control` 追加
  `, immutable`,告诉客户端资源在缓存期内绝不会变(适合带指纹的构建产物)。
- `setHeaders`(默认 `None`):文件发送前调用的回调 `(res, realPath) -> Unit`,可在其中
  对响应任意定制头部。
- `redirect`(默认 `true`):目录请求且 URL 不以 `/` 结尾时是否 301 重定向到带斜杠版本
  (这能让目录内 HTML 的相对路径正确解析)。关闭后目录请求一律交给 `next()`。

```cangjie
app.use("/static", staticFiles("./public", maxAge: 3600))

// 构建产物:一年强缓存 + immutable
app.use("/assets", staticFiles("./dist", maxAge: 31536000, immutable: true))

// 定制响应头(例如对字体加 CORS):
app.use("/fonts", staticFiles("./fonts", setHeaders: {
    res: HttpResponse, _: String => res.set("Access-Control-Allow-Origin", "*")
}))
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
