# wen 路线图(对标 Express.js)

> 更新于 2026-06-15。基于源码逐项核对(`cjpm test` 233/233 全绿)。
> 图例:✅ 已实现 · ⚠️ 部分(底层已具备但未暴露 Express 风格 API)· ❌ 未实现
>
> 粗估:核心 HTTP API 已覆盖 Express 4.x 常用面 **约 85%**。路由 / 中间件 / 请求 /
> 响应 / 会话 / 视图 / 流式均较完整,缺口集中在内容协商细分、请求级缓存与 Range 助手,
> 以及 HTTPS / WebSocket 等传输层能力。

---

## 一、已实现 ✅

### 应用 Application
- `wen()` 工厂、`listen(port)` / `listen(port, onReady)`
- `use(中间件 / 路径+中间件 / 子路由 Router / 错误处理器 / 中间件数组)`
- `get/post/put/delete/patch/head/options/all`,各 3 种重载(`Middleware` / `Handler` / 数组)
- `route(path)` 链式注册(`Route` 类:`.get().post()...`)
- `param(name, handler)` 路由参数预处理
- `engine(ext, fn)` 视图引擎注册
- `set / setting / enable / disable / enabled / disabled` 配置开关
- `locals` + `setLocal / local`
- `cookieSecret`、`trustProxy`
- 服务器调优:`maxBodySize` / `readTimeoutMs` / `maxConnections`;HTTP keep-alive

### 路由 Router
- 全方法 + 3 种重载;`use` / `use(path)` / `use(path, 子 Router)`
- `param`、`useError`、精确匹配 / 前缀匹配、路径参数(`:id`)
- 子路由挂载与多级嵌套(`req.baseUrl` 自动累积)

### 请求 HttpRequest
- `method / url / path / httpVersion / originalUrl / baseUrl`
- `headers` + `get() / header()`;`query` + `queryParam()`;`params` + `param()`
- `body / bodyBytes / jsonBody / json()`
- `cookies` + `cookie()`;`signedCookie(name)` / `signedCookies()` 签名 cookie
- `files` + `file()` 文件上传
- `session`
- `ip / ips() / clientIp() / protocol() / secure() / hostname() / subdomains() / xhr()`
- `isType()`(对应 `req.is`)、`accepts()`(媒体类型协商)
- `acceptsCharsets()` / `acceptsEncodings()` / `acceptsLanguages()`(均含数组与单值两种重载)
- `fresh()` / `stale()`(条件请求新鲜度,可回 304)、`range(size)`(Range 解析,支持多区间)
- `locals` + `setLocal / local`;`attributes`;`requestId()`;`app` / `res`;`setting()`;`nextRoute()`

### 响应 HttpResponse
- `status / sendStatus`、`send / sendBytes / json / jsonp / end`
- `set / get / append / contentType / mimeType`(对应 `res.type`)`/ location / vary / links`
- `charset`(独立于 MIME 的字符集,序列化前自动并入 Content-Type)
- `cookie / clearCookie`(含 Domain / Expires / maxAge 选项)
- `redirect(location)` / `redirect(status, location)`
- `sendFile / download / attachment`(含条件请求 304、Range 206、416)
- `render`(视图)、`format`(按 Accept 分支)
- `stream`(分块写出)、`sse`(Server-Sent Events:`event / send / id / retry / comment`)
- `headersSent`、`locals`、`finished`、`suppressBody`(HEAD 请求自动省略响应体)

### 内置中间件(Express 中多为独立 npm 包)
- `jsonParser`(express.json)、`urlencodedParser`(express.urlencoded)、`textParser`
  (express.text)、`rawParser`(express.raw)、`multipart`(文件上传)
- `staticFiles`(express.static:index / maxAge / dotfiles / etag / lastModified / immutable /
  setHeaders / redirect / ETag / Last-Modified / Range)
- `cookieParser`、`session`(`MemorySessionStore` + `SessionStore` 接口)
- `cors`、`helmet`、`compression`(自带 gzip)、`logger`、`requestId`、`etag`(动态)
- `basicAuth` / `bearerAuth`

### 视图 / 工具
- 视图渲染:`app.engine` 注册自定义引擎(框架**不内置**默认模板引擎)
- 自写 JSON 解析 / 序列化(`json.cj`)、HMAC(`crypto_hmac.cj`,用于签名 cookie / session)

---

## 二、未实现 ❌

### 高优先级
- HTTPS / TLS(`listenHttps`)—— 依赖仓颉 TLS 能力或 FFI;短期替代:nginx 反向代理

### 中优先级
- `trust proxy` 的完整语义(目前仅布尔 `trustProxy`)

### 低优先级 / 生态
- WebSocket(建议作为独立模块,需握手 + 帧编解码)
- HTTP/2(协议复杂,待仓颉生态成熟或第三方库)
- 集群 / 多进程(依赖 `std.process`;替代:nginx 负载均衡 / 容器编排)
- 调试日志系统(类似 Node 的 `debug` 模块)

### Express 中间件补遗(对标 npm 生态,非核心)
- `csrf` —— CSRF 防护。Express 的 `csurf` 已弃用,现代做法是 `SameSite=Lax/Strict` cookie
  + 双提交 token;`session` + 签名 cookie 已具备底层能力,做一个薄中间件即可。
- `method-override` —— 允许 HTML 表单通过 `_method` 字段或 `X-HTTP-Method-Override`
  头模拟 PUT/DELETE。实现量很小。
- 请求体校验(`validator` / `joi` 风格)—— 目前需在 handler 里手写 `req.json()` 后判空。
  可作为独立模块或留给用户选型,框架本身不必内置。

---

## 三、建议推进顺序

1. ✅ **已完成(2026-06-15)**:`textParser` / `rawParser`、`acceptsCharsets / Encodings / Languages`。
2. ✅ **已完成(2026-06-15)**:`req.fresh` / `req.stale`、`req.range(size)`(含 `req.res` 链接)、
   `req.signedCookies()` 整表映射。
3. ✅ **已完成(2026-06-15)**:`res.charset`、静态文件选项(`etag` / `lastModified` /
   `immutable` / `setHeaders` / `redirect`)、`Router.mountpath`、
   `case sensitive routing` / `strict routing`
   (默认值匹配 Express:大小写无关、尾部斜杠无关)。
4. **需先调研仓颉标准库**:TLS(HTTPS)、process(集群)——
   确认 API 可用性后,决定原生实现还是外部替代(nginx 等)。
5. **独立模块 / 长期**:WebSocket;HTTP/2 待生态成熟。
