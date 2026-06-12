# Wen

**Wen**(文)—— 一个用华为仓颉(Cangjie)编程语言编写的、类 Express 风格的轻量级
Web 框架。名取「文」:既呼应仓颉造字,也契合 HTTP 这一文本协议。

特点:**纯标准库、零第三方依赖**(JSON、HMAC-SHA256 等均为自带实现),API 风格贴近
Express,源码注释为详细中文。

这是 `wen` 库本体仓库(可作为 cjpm 依赖直接引用)。

## 作为依赖使用

在你的模块 `cjpm.toml` 中加入 git 依赖:

```toml
[dependencies]
  wen = { git = "https://github.com/mtpkiss/wen.git", branch = "main" }
```

然后 `import wen.*` 即可:

```cangjie
package demo

import wen.*

main(): Int64 {
    let app = wen()

    app.use(logger())
    app.use(cors())

    app.get("/", { _: HttpRequest, res: HttpResponse =>
        res.send("Hello from Wen!")
    })

    // 类型化 JSON(内置零依赖 JsonValue / JsonObj 构建器)
    app.get("/users/:id(\\d+)", { req: HttpRequest, res: HttpResponse =>
        let id = match (req.param("id")) { case Some(v) => v; case None => "?" }
        res.json(JsonObj().put("id", id).build())
    })

    app.listen(8080, { => println("Wen listening on http://localhost:8080") })
    return 0
}
```

## 能力一览

- **路由**:`get/post/put/delete/patch/head/options/all` 及终结式 `Handler`;命名参数
  `:param`、可选参数 `:param?`、内联正则约束 `:param(\d+)`、通配符 `*`;一条路径挂多个
  处理器(`[mw1, mw2]`)、`req.nextRoute()`(等价 Express 的 `next("route")`)跳过当前路由;
  `app.route(path)` 链式、`app.param(name, fn)` 参数预处理、可挂载子路由
  `app.use(path, Router)`(含 mergeParams);自动 `HEAD`/`OPTIONS`、`405 + Allow`。
- **中间件**:中间件链 `(req, res, next)`、全局/路径挂载、数组批量挂载、错误处理中间件
  `(err, req, res, next)`、`Plugin` 系统。内置:`logger / cors / helmet(安全头) /
  jsonParser / urlencodedParser / multipart(文件上传) / cookieParser / staticFiles / session`。
- **请求**:`headers/query/params/cookies`、字符串 `attributes` 与类型化 `locals`、
  `body/bodyBytes`、`json()`(解析后的 `JsonValue`)、`file(name)/files`(上传)、
  `signedCookie(name)`、`session`;`hostname()/isType()`、`accepts()` 与 `accepts([...])`
  (带 q 值的最佳匹配);代理感知 `protocol()/secure()/ips()/clientIp()/subdomains()/xhr()`
  (配合 `app.trustProxy`)。
- **响应**:`send/json/sendBytes/sendStatus/redirect/end`;`json` 支持字符串与类型化
  `JsonValue/JsonObj`;`cookie`(可 `signed` 签名)/`clearCookie`、`set` 批量、
  `mimeType/contentType/append/location`;`render`(视图渲染)、`format`(内容协商)、
  `attachment/download`(附件下载);流式 `stream` 与 Server-Sent Events `sse`。
- **文件与缓存**:`sendFile / download / staticFiles` 均**二进制安全**(原始字节,不经
  UTF-8 往返);自动 `ETag` + `If-None-Match` → 304、`Last-Modified` + `If-Modified-Since`
  → 304、`Range` 分片下载(206 / 416)。
- **JSON**:内置零依赖 `JsonValue`(对象保序)+ `parseJson` + `toJsonString` + `JsonObj`
  链式构建器,访问器 `asString/asInt/asFloat/asBool/get/at/size/keys`;正确处理转义、
  `\u` 与代理对。
- **视图渲染**:`res.render` + `app.engine(ext, fn)` + `app.set("views"/"view engine")`;
  内置极简 `{{ key }}` 模板引擎(支持 `a.b.c` 嵌套字段、默认 HTML 转义防注入),也可
  接入任意第三方引擎。
- **会话与安全**:HMAC-SHA256 **签名 Cookie**、`session()`(默认线程安全的内存存储,
  可实现 `SessionStore` 接入 Redis/DB)、`helmet()` 一组安全响应头(CSP / nosniff /
  HSTS / 防点击劫持等)。
- **服务器**:基于标准库 `std.net`,**零第三方依赖**;HTTP/1.1 keep-alive、chunked
  请求体、并发连接上限(信号量背压)、请求体大小上限与读超时;请求走私防护
  (同时带 Content-Length 与 Transfer-Encoding → 400)、`204/304` 不带响应体与
  Content-Length。

## 构建与测试

```bash
cjpm build
cjpm test
```

## License

MIT,详见 [LICENSE](LICENSE)。
