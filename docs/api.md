---
title: API 参考
nav_order: 4
---

# API 参考

简明 API 速览。所有核心类型都在 `wen` 包内,`import wen.*` 即可。
**0.4.0 起**:`helmet` / `csrf` / `cors` / `basicAuth` / `bearerAuth` / `logger`
/ `requestId` / `methodOverride` / `methodOverrideField` 等可选中间件在
`wen_contrib` 子包,使用前 `import wen_contrib.*`,详见 [中间件参考](./middleware.md)。

## 函数类型

| 类型 | 形状 | 说明 |
|---|---|---|
| `Next` | `() -> Unit` | 推进到下一层中间件 |
| `Handler` | `(HttpRequest, HttpResponse) -> Unit` | 终结式处理器(无 next) |
| `Middleware` | `(HttpRequest, HttpResponse, Next) -> Unit` | 通用中间件 |
| `ErrorHandler` | `(Exception, HttpRequest, HttpResponse, Next) -> Unit` | 错误处理中间件 |
| `ParamHandler` | `(HttpRequest, HttpResponse, String) -> Unit` | `app.param` 回调 |
| `ViewEngine` | `(String, JsonValue) -> String` | 视图引擎(模板路径, 数据)→ 渲染串 |

## Application —— `wen()`

### 路由与中间件

- `use(Middleware)` / `use(path, Middleware)` / `use(Array<Middleware>)` / `use(path, Array<Middleware>)`
- `use(path, Router)` —— 挂载子路由(mergeParams)
- `use(ErrorHandler)` —— 注册错误处理
- `get/post/put/delete/patch/head/options/all(path, Handler | Middleware | Array<Middleware>)`
- `route(path): Route` —— 同一路径绑定多个动词(链式)
- `param(name, ParamHandler)` —— 参数预处理
- `engine(ext, ViewEngine)` —— 注册视图引擎

### 设置与字段

- `set(key, value)` / `setting(key): ?String`
- `enable/disable(key)` / `enabled/disabled(key): Bool`
- `locals: HashMap<String, Any>` / `setLocal(key, value)` / `local(key): ?Any`
- 字段:`trustProxy: Bool`、`cookieSecret: String`、`legacyCookieSecrets: Array<String>`、
  `maxBodySize: Int64`、`readTimeoutMs: Int64`、`maxConnections: Int64`

> `cookieSecret` 是当前**签发主密钥**;`legacyCookieSecrets` 仅作**验签 fallback**,
> 用于密钥在线轮换。部署流程:`cookieSecret = "new", legacyCookieSecrets = ["old"]` →
> 等持旧 cookie 客户端续期 / 过期被切到 new → 清空 legacy 完成轮换。session sid
> cookie 走同一验签路径,自动受益。对应 Express `cookie-parser(['new','old'])`。

### 派发与启动

- `handle(req, res)` —— 跑完整条链(便于无 socket 测试)
- `listen(port)` / `listen(port, onReady)` —— 阻塞调用,通常在协程里 `spawn`
- `close(timeoutMs! = 5000)` —— 优雅关闭:停接新连接,等在途请求 drain 完成或超时;
  幂等;listen 之前调用是无操作

## HttpRequest

### 字段

`method`、`url`、`path`、`httpVersion`、`headers`、`query`、`params`、`body`、`bodyBytes`、
`attributes`(String 存储)、`locals`(Any 存储)、`cookies`、`jsonBody`、`ip`、`app`、
`files`、`session`。

### 方法

- `header(name)/get(name): ?String` —— 大小写无关
- `param(name): ?String` / `queryParam(name): ?String`
- `setAttribute(k, v)` / `attribute(k): ?String`
- `setLocal(k, v)` / `local(k): ?Any`
- `cookie(name): ?String` / `signedCookie(name): ?String` / `signedCookies(): HashMap<String, String>`
- `json(): ?JsonValue` —— 自动解析 `application/json` 请求体(无需中间件)
- `file(name): ?UploadedFile` —— 自动解析 `multipart/form-data`(无需中间件)
- `requestId(): ?String` — 仅在用 `wen_contrib.requestId()` 中间件后有值
- `setting(key): ?String`
- `hostname(): ?String` / `isType(t): Bool`
- `accepts(t): Bool` / `accepts(types: Array<String>): ?String`(带 q 值最佳匹配)
- `acceptsCharsets / acceptsEncodings / acceptsLanguages` —— 各两个重载:
  `(Array<String>): ?String` 按 q 值返回最佳匹配,`(String): Bool` 判定单值是否可接受
- `fresh(): Bool` / `stale(): Bool` —— 条件请求新鲜度:GET/HEAD 配合响应的 `ETag` /
  `Last-Modified` 与请求的 `If-None-Match` / `If-Modified-Since` 校验,可用于回 304
- `range(size: Int64): RangeRequest` —— 解析 `Range` 头;返回 enum
  `Satisfiable(Array<ByteRange>) | Unsatisfiable | Malformed | NoRange`(`ByteRange { start, end }`)
- 代理感知(配合 `app.trustProxy`):`protocol(): String`、`secure(): Bool`、
  `ips(): ArrayList<String>`、`clientIp(): String`、`subdomains(): ArrayList<String>`、`xhr(): Bool`
- `nextRoute()` —— 跳过当前路由的剩余处理器(等价 `next("route")`)

## HttpResponse

### 状态与头

- `status(code): HttpResponse`
- `set(name, value)` / `set(headers: HashMap)` / `get(name): ?String`
- `contentType(value)` / `mimeType(shorthand)` / `location(url)`
- `append(name, value)` / `vary(field)`

### Cookie

- `cookie(name, value, path!, maxAge!, httpOnly!, secure!, sameSite!, domain!, expires!, signed!)`
- `clearCookie(name, path!)`

### 发送

- `send(text)` / `sendBytes(data)` / `sendStatus(code)` / `end()`
- `json(String | JsonValue | JsonObj)`
- `redirect(location)` / `redirect(status, location)`
- `sendFile(path)` / `attachment([filename])` / `download(path[, filename])`
- `render(name [, data])` —— 视图渲染
- `format([(type, () -> Unit)...])` —— 内容协商
- `stream((StreamWriter) -> Unit)` / `sse((SseWriter) -> Unit)`

### 字段

- `statusCode: Int64`、`body: String`
- `charset: String` —— 独立于 MIME 的字符集,序列化前自动并入 `Content-Type`
- `headers: HashMap<String, String>` —— **case-insensitive** 访问(0.4.0 起);
  通过 `set / get / append / has / remove` 操作,大小写惯例(`Content-Type` / `ETag` /
  `WWW-Authenticate`)保留为输出 key
- `headersSent: Bool`、`finished: Bool`、`locals: HashMap<String, Any>`
- `suppressBody: Bool` —— HEAD 请求自动置 true,框架在序列化时省略响应体

## 异常类型

- `HttpException(status: Int64, message: String)` /
  `HttpException(status, message, headers: HashMap<String, String>)` —— 抛出后框架据
  `status` 回状态码、`message` 作响应体、`headers` 自动套到响应头。典型用法:

  ```cangjie
  let h = HashMap<String, String>(); h["Retry-After"] = "60"
  throw HttpException(429, "rate limited", h)   // → 429 + Retry-After: 60
  ```

  `401 + WWW-Authenticate`、`405 + Allow`、`503 + Retry-After` 同理。`open class`,可继承
  自定义子类。
- `PayloadTooLargeException <: HttpException` —— 请求体或上传超 `app.maxBodySize` /
  `multipart` 配额时抛(默认 413)
- `BadRequestException <: HttpException` —— 协议解析错误(默认 400)
- `JsonException <: Exception` —— `parseJson` 解析失败
- `IllegalStateException <: Exception` —— 非法 API 顺序(如对同一对 `(req, res)` 重复调用 `app.handle`)

## JSON

- `JsonValue` 枚举:`asString/asBool/asInt/asFloat(): ?T`、`isNull()`、`get(key)`、`at(i)`、
  `size()`、`keys()`、`toJsonString()`
- `JsonObj`:链式 `.put(key, value).build()`(`value` 可为 `String/Int64/Float64/Bool/JsonValue`)
- 顶层:`parseJson(text): JsonValue`(失败抛 `JsonException`)、`jsonOf(...)`、
  `jsonArray(items)`、`jsonNull(): JsonValue`

## 其它公开类型 / 工具

- **类型**:`Router`、`Route`、`UploadedFile`、`Session`、`SessionStore`、`MemorySessionStore`、
  `StreamWriter`、`SseWriter`、`ResponseConnection`(扩展点 interface)、
  `HttpMethod`(常量类:`GET/POST/PUT/DELETE/PATCH/HEAD/OPTIONS/ALL`)、
  `MultipartOptions`(`multipart(...)` 配额结构,详见 [中间件参考](./middleware.md#multipartmaxfilesize-maxfiles-maxfields-filefilter-wen))、
  `ByteRange { start, end }`、`RangeRequest` enum
- **加密 / 安全**:`hmacSha256Hex(key, msg)`、`constantTimeEquals(a, b)`(防时序侧信道)、
  `secureRandomBytes(n): Array<UInt8>`、`secureRandomHex(n): String`(CSPRNG;
  自定义 session id / token 等用此,不要用 `std.random.Random`)
- **编码 / 解析**:`base64Encode/Decode`、`parseJson`、`parseQuery`、`urlDecode`
- **MIME**:`contentTypeFor(value): String`、`registerMimeType(ext, mimeType): Unit`
  —— 注册自定义扩展名 → MIME 映射,被 `staticFiles` / `res.contentType` 等使用
- **HTTP 工具**:`reasonPhrase(status): String`

> JSON / HMAC-SHA256 / 安全随机数均为零依赖自写,封装在单文件「替换缝」内,日后可
> 整体切换到官方 `stdx`。压缩(gzip)与 TLS 不自写,交给 nginx 等边缘。
