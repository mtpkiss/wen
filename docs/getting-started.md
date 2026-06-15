# 快速上手

## 安装

Wen 是一个 cjpm 库,在你的模块 `cjpm.toml` 中加入 git 依赖:

```toml
[dependencies]
  wen = { git = "https://github.com/mtpkiss/wen.git", branch = "main" }
```

> 需要 Cangjie 编译器 **cjc 1.1.3 及以上**。Wen 本身**零第三方依赖**(仅用标准库 `std`)。

## 第一个应用

```cangjie
package demo

import wen.*

main(): Int64 {
    let app = wen()

    app.use(logger())

    app.get("/", { _: HttpRequest, res: HttpResponse =>
        res.send("Hello from Wen!")
    })

    app.get("/users/:id", { req: HttpRequest, res: HttpResponse =>
        let id = match (req.param("id")) { case Some(v) => v; case None => "?" }
        res.json(JsonObj().put("id", id).build())
    })

    app.listen(8080, { => println("listening on http://localhost:8080") })
    return 0
}
```

构建并运行:

```bash
cjpm build
cjpm run     # 若你的模块 output-type = "executable"
```

## 核心概念

- **处理器有两种写法**:
  - `Handler`:`{ req, res => ... }`(终结式,不需要 `next`)。
  - `Middleware`:`{ req, res, next => ... }`(可调用 `next()` 把控制权交给下一层)。
- **中间件链**:`app.use(...)` 注册的中间件按顺序执行,调用 `next()` 继续,不调用则就此终止。
- **错误处理**:抛出的异常会冒泡到错误处理中间件 `{ err, req, res, next => ... }`
  (用 `app.use` 注册,放在要兜底的路由之后)。
- **路由**:支持 `:param`、可选 `:param?`、正则约束 `:param(\d+)`、通配 `*`,以及一条路径
  挂多个处理器 `app.get(path, [mw1, mw2])`。

## 一个更完整的例子

```cangjie
let app = wen()

app.use(compression())                 // gzip
app.use(etag())                        // 动态 ETag + 条件 GET
app.use(helmet())                      // 安全响应头
app.use(cors())
// JSON / 表单 / multipart / Cookie 解析已内置:req.json()/attribute()/file()/cookie() 首次访问即自动解析,无需注册

app.param("id", { req, _, value =>
    req.attributes["entity"] = "loaded:${value}"
})

app.get("/posts/:page?", { req, res =>
    let page = match (req.param("page")) { case Some(v) => v; case None => "1" }
    res.json(JsonObj().put("page", page).build())
})

app.post("/echo", { req, res =>
    match (req.json()) {
        case Some(j) => res.json(j.toJsonString())
        case None => res.status(400).send("invalid json")
    }
})

app.use({ e: Exception, _: HttpRequest, res: HttpResponse, _: Next =>
    res.status(500).json("{\"error\":\"${e.message}\"}")
})

app.listen(8080)
```

更多见:[中间件参考](./middleware.md) · [API 参考](./api.md) · [README](../README.md) 的「完整示例」。
