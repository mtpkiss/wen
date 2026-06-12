# 更新日志

本项目遵循 [语义化版本](https://semver.org/lang/zh-CN/)。

## [0.2.0] - 2026-06-12

一次大幅扩充,将 Wen 从基础雏形补成一个较完整、类 Express 的零依赖框架。

### 新增

- **JSON**:内置零依赖 `JsonValue`(对象保序)+ `parseJson` + `toJsonString` + `JsonObj`
  构建器;`res.json` 支持类型化值,`jsonParser` 解析请求体到 `req.json()`。
- **文件与缓存**:`res.sendFile/download`、`staticFiles` 二进制安全;自动 `ETag` +
  `If-None-Match` → 304、`Last-Modified` + `If-Modified-Since` → 304、`Range` 分片(206/416)。
  动态响应经 `etag()` 中间件也获得条件 GET。
- **路由完整性**:可选参数 `:name?`、一条路径多处理器、`req.nextRoute()`(next("route"))、
  `app.param(name, fn)`。
- **代理感知请求**:`req.protocol/secure/ips/clientIp/subdomains/xhr` + `app.trustProxy`。
- **内容协商**:`req.accepts` 升级为带 q 值的最佳匹配、`req.accepts([...])`、`res.format`。
- **视图渲染**:`res.render` + `app.engine` + 内置 `{{ key }}` 模板引擎。
- **中间件**:`helmet`(安全头)、`compression`(自写 gzip)、`rateLimit`(限流)、
  `basicAuth`/`bearerAuth`(认证)、`requestId`、`multipart`(文件上传)、`session`(签名
  sid + 内存 store)、`etag`。
- **会话与安全**:HMAC-SHA256 签名 Cookie(`res.cookie(signed: true)` / `req.signedCookie`)、
  `session()`、自写 `base64Encode/Decode`、`hmacSha256Hex`。
- **响应细节**:`res.jsonp/vary/links`、带状态码的 `res.redirect`、cookie 的
  `domain`/`expires`(`maxAge` 自动推导 Expires)、自动 `Date` 响应头。
- **静态文件选项**:`index`、`maxAge`(Cache-Control)、`dotfiles` 策略。
- **应用设置**:`app.enable/disable/enabled/disabled`。
- 全部源码注释改写为详细中文;新增 `docs/` 文档与 154 项单元测试。

### 修复

- `sendFile`/`staticFiles` 二进制资源经 UTF-8 往返被破坏。
- `urlDecode` 破坏多字节 UTF-8(中文等)。

### 健壮性

- 并发连接上限(信号量背压)、请求走私防护(CL+TE → 400)、`204/304` 不带响应体与
  Content-Length。

### 说明

- 仍为**纯标准库零依赖**:JSON、HMAC-SHA256、gzip 均为自写,且封装在单文件「替换缝」内,
  日后可一键切换到官方 `stdx`。
- TLS/HTTPS 不在框架内实现(交给 nginx 反代或 stdx);gzip 已自写。
- 基于 cjc 1.1.3 构建测试。

## [0.1.0] - 2026-06-12

- 首次发布:类 Express 的核心(中间件链、路由、错误处理、cookie/cors/logger/static/body
  解析、流式与 SSE、子路由挂载、自动 HEAD/OPTIONS/405)。
