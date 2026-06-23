# wen

**Wen**(文)—— 一个用华为仓颉(Cangjie)编程语言编写的、**面向原生高性能**的
Express 风格 Web 框架。**纯标准库、零第三方依赖**(JSON、HMAC-SHA256、CSPRNG 等
均为自带实现),API 风格贴近 Express,**路由用 trie 索引(O(M),M 是请求路径段数)**,
大路由表下仍保持稳定派发耗时。

本包是 `wen` 的 **core**(必装)—— 路由 / 请求响应 / 解析 / 流式 / 文件 / 会话 / ETag。
可选中间件(`logger` / `helmet` / `csrf` / `cors` / `basicAuth` / `bearerAuth` /
`requestId` / `methodOverride`)在另一个子包 [`wen_contrib`](https://gitcode.com/cangjie/wen_contrib)。

完整仓库与文档:[github.com/mtpkiss/wen](https://github.com/mtpkiss/wen)
官方文档站:[mtpkiss.github.io/wen](https://mtpkiss.github.io/wen/)

## 安装

在你的模块 `cjpm.toml` 中加入依赖(任选其一):

中心仓:

```toml
[dependencies]
  wen = "0.4.0"
```

或 git:

```toml
[dependencies]
  wen = { git = "https://github.com/mtpkiss/wen.git", branch = "main", path = "wen-core" }
```

代码里:

```cangjie
import wen.*

main(): Int64 {
    let app = wen()
    app.get("/", { _, res => res.send("Hello from Wen!") })
    app.listen(8080)
    return 0
}
```

需要 Cangjie 编译器 **cjc 1.1.3 及以上**。

## 包含的能力(core)

- 应用与路由:`wen()` / `get/post/put/delete/...` / `use` / `param` / `route()`
  链式 / 子路由 / 多处理器
- 请求 / 响应:`req.json()` / `req.file()` / `req.cookie()` / `req.session` /
  `res.json()` / `res.sendFile()` / `res.stream()` / `res.sse()` / `res.render()`
- 内置中间件:`etag` / `multipart`(配额) / `session`(`MemorySessionStore`) /
  `staticFiles`(含 ETag / Last-Modified / Range / 304 / 206 / 416)
- 请求体 / Cookie 解析**内置**(首次访问 `req.json/attribute/file/cookie` 自动按
  Content-Type 解析,无需注册中间件)
- 视图引擎注册点 `app.engine(ext, fn)`(框架不内置默认模板引擎)
- 工具:`hmacSha256Hex` / `constantTimeEquals` / `secureRandomBytes / Hex` /
  `base64Encode / Decode` / `parseJson` / `JsonObj` / `parseQuery` / `urlDecode`

## 不在覆盖范围

由反代 / 边缘 / 基础设施层负责或选用专门库:

- **TLS / HTTPS、HTTP/2** —— 反代层终止
- **响应压缩(gzip / Brotli)** —— 反代 `gzip on;` 即可
- **限流 / 防 DDoS / WAF** —— 反代 / API 网关 / CDN
- **WebSocket** —— 独立协议;SSE(`res.sse(...)`)已覆盖大多数推送场景
- **大文件流式上传**(单文件超过百 MiB)—— 走对象存储直传或 nginx upload module
- **多层代理伪造头防护** —— `trustProxy` 当前是 `Bool`,假定单层反代部署

详见仓库 [README — 定位与边界](https://github.com/mtpkiss/wen#定位与边界)。

## 许可

Apache License 2.0(详见仓库根 `LICENSE`)。
