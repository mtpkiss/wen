# wen_contrib

`wen_contrib` 是 [wen](../wen-core) 框架的**可选中间件集**。0.4.0 起从 core 拆出,
让纯 API / 后端用户能装一个更瘦的 core,需要这些「典型 Web 应用必备」中间件时再额外加依赖。

零第三方依赖,只用仓颉标准库;Cangjie 静态链接 + dead-code elimination,意味着即使
全装 `wen_contrib`,你最终二进制里只会包含你实际 `import` 并注册的中间件,不会被未用项
连累体积。

## 安装

在你的模块 `cjpm.toml` 中加 git 依赖(同时需要 core):

```toml
[dependencies]
  wen         = { git = "https://github.com/mtpkiss/wen.git", branch = "main", path = "wen-core" }
  wen_contrib = { git = "https://github.com/mtpkiss/wen.git", branch = "main", path = "wen-contrib" }
```

代码里:

```kotlin
import wen.*
import wen_contrib.*
```

## 包含的中间件

| 工厂 | 一句话 | 典型放置 |
|---|---|---|
| `helmet()` | 安全响应头(`X-Content-Type-Options` / `X-Frame-Options` / `Referrer-Policy` / HSTS;CSP/COOP/CORP opt-in) | 路由前,靠最前 |
| `cors(origin, ...)` | CORS;预检 `OPTIONS` 直接 204 短路 | 路由前,在认证 / CSRF 之前 |
| `csrf(...)` | 签名双提交 Cookie,防 CSRF;依赖 `app.cookieSecret` | 路由前,在 body 解析后 |
| `basicAuth(verify)` / `bearerAuth(verify)` | HTTP Basic / Bearer Token;校验回调由你提供,401 自动带 `WWW-Authenticate` | 受保护路由前缀 / 单路由 |
| `logger()` / `logger(format, sink)` | 请求完成后打印一行;format/sink 均可定制 | 全局,通常最外层 |
| `requestId(headerName)` | 关联请求 ID(沿用上游头或生成新 ID);写回响应头并存到 `req.requestId()` | 全局,在 `logger` 之前 |
| `methodOverride()` / `methodOverrideField()` | HTML 表单借 `X-HTTP-Method-Override` 头或 `_method` 字段把 POST 重写成 PUT/PATCH/DELETE | 路由前 |

## 推荐注册顺序

「横切关注点」靠前,业务路由靠后。一个典型生产组合:

```kotlin
let app = wen()
app.cookieSecret = "change-me-in-prod"   // csrf / 签名 cookie 都要

app.use(requestId())                      // 1. 关联 ID 先生成
app.use(logger())                         // 2. 全程日志
app.use(helmet())                         // 3. 安全头
app.use(cors("https://app.example.com", credentials: true))  // 4. CORS(预检短路)
app.use(methodOverride())                 // 5. HTML 表单兼容
app.use(methodOverrideField())            //    (头版本 + 字段版本可同时挂)
app.use(csrf())                           // 6. 写操作防护

// 之后是业务路由 / 受保护路由
app.use("/admin", basicAuth({ u, p => u == "root" && p == env("ADMIN_PASS") }))
app.get("/api/things", { req, res => res.json(...) })

app.listen(8080)
```

## 与 core 的边界

下列能力**在 [wen-core](../wen-core) 内置**,不在本包:

- 请求体解析(JSON / urlencoded / multipart)、Cookie 解析 —— 首次访问自动懒解析
- 静态文件 `staticFiles(...)`、`session(...)`、动态 `etag(...)`
- 路由、请求 / 响应、流式 / SSE、视图、文件下载

`wen_contrib` 只放**通用但非每个应用都需要**的横切中间件。

## 详细参考

每个中间件的全部选项、安全细节、边角情况见
[docs/middleware.md](https://mtpkiss.github.io/wen/middleware) 或仓库内
[../docs/middleware.md](../docs/middleware.md)。

完整 API:[docs/api.md](https://mtpkiss.github.io/wen/api)。
