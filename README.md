# Wen

**Wen**(文)—— 一个用华为仓颉(Cangjie)编程语言编写的、类 Express 风格的轻量级
Web 框架。名取「文」:既呼应仓颉造字,也契合 HTTP 这一文本协议。

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

    app.get("/users/:id(\\d+)", { req: HttpRequest, res: HttpResponse =>
        let id = match (req.param("id")) { case Some(v) => v; case None => "?" }
        res.json("{\"id\":\"${id}\"}")
    })

    app.listen(8080, { => println("Wen listening on http://localhost:8080") })
    return 0
}
```

## 能力一览

- 中间件链(`(req, res, next)`)、全局/路径挂载、`Plugin` 系统。
- 路由:命名参数 `:param`、内联正则约束 `:param(\d+)`、通配符 `*`、`app.route(path)`
  链式、可挂载子路由 `app.use(path, Router)`。
- 错误处理中间件 `(err, req, res, next)`。
- 请求:`headers/query/params/cookies`、类型化 `locals`(挂任意对象)、`bodyBytes`、
  `ip`、`hostname()`、`isType()`、`accepts()`。
- 响应:`send/json/sendBytes/sendFile/redirect`、`cookie/clearCookie`、`set` 批量、
  `mimeType/append/location`,以及流式 `stream` 与 Server-Sent Events `sse`。
- 内置中间件:`logger / cors / jsonParser / urlencodedParser / cookieParser / staticFiles`。
- 服务器:基于标准库 `std.net`,零第三方依赖;HTTP/1.1 keep-alive、chunked 请求体、
  请求体大小上限与读超时。

## 构建与测试

```bash
cjpm build
cjpm test
```

## License

MIT,详见 [LICENSE](LICENSE)。
