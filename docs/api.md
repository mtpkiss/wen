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
- 字段:`trustProxy: Bool`、`cookieSecret: String`、`maxBodySize: Int64`、
  `readTimeoutMs: Int64`、`maxConnections: Int64`

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
- `cookie(name): ?String` / `signedCookie(name): ?String`
- `json(): ?JsonValue` —— 自动解析 `application/json` 请求体(无需中间件)
- `file(name): ?UploadedFile` —— 自动解析 `multipart/form-data`(无需中间件)
- `requestId(): ?String` — 仅在用 `wen_contrib.requestId()` 中间件后有值
- `setting(key): ?String`
- `hostname(): ?String` / `isType(t): Bool`
- `accepts(t): Bool` / `accepts(types: Array<String>): ?String`(带 q 值最佳匹配)
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

## JSON

- `JsonValue` 枚举:`asString/asBool/asInt/asFloat(): ?T`、`isNull()`、`get(key)`、`at(i)`、
  `size()`、`keys()`、`toJsonString()`
- `JsonObj`:链式 `.put(key, value).build()`(`value` 可为 `String/Int64/Float64/Bool/JsonValue`)
- 顶层:`parseJson(text): JsonValue`、`jsonOf(...)`、`jsonArray(items)`

## 其它公开类型 / 工具

- `Router`、`Route`、`UploadedFile`、`Session`、`SessionStore`、`MemorySessionStore`、
  `StreamWriter`、`SseWriter`
- 工具:`hmacSha256Hex(key, msg)`、`base64Encode/Decode`、
  `parseJson`、`parseQuery`、`urlDecode`、`contentTypeFor`、`reasonPhrase`

> 这两处实现(JSON / HMAC-SHA256)均为零依赖自写,封装在单文件「替换缝」内,日后可
> 整体切换到官方 `stdx`。压缩(gzip)与 TLS 不自写,交给 nginx 等边缘。
