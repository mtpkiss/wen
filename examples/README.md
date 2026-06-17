# wen examples

这里放真实场景的可运行示例,每个示例都是一个独立的 cjpm 子包,通过 `path = "../"`
引用本仓库根目录的 `wen` 框架本体——和 `benchmark/` 的组织方式一致。

## 当前示例

### `urlshorten` —— URL 短链服务

一个最小但完整的 URL 短链服务,选这个场景是因为它接地气、能把 wen 的主线能力都
串起来——JSON 体解析、参数路由、类型化 JSON 响应、302 重定向、Bearer Token
鉴权、Server-Sent Events 实时推送、集中式错误处理,以及生产里基本必挂的
`logger / helmet / cors / requestId` 这一组中间件。

#### 路由清单

| 方法 | 路径 | 作用 | 涉及的框架能力 |
|---|---|---|---|
| `GET` | `/` | 朴素的提交说明页 | `res.contentType` + `res.send` |
| `POST` | `/api/links` | 创建短链 | `req.json()` 解析、`JsonObj` 构建、`res.status(201).json(...)` |
| `GET` | `/api/links` | 列出全部 | `JsonArray` + 类型化 JSON |
| `GET` | `/api/links/:code` | 查询单条 | 路径参数 `:code` + `req.param(...)` |
| `DELETE` | `/api/links/:code` | 删除单条 | `bearerAuth` 中间件 + 数组式多处理器路由 |
| `GET` | `/api/links/:code/stream` | SSE 推送实时点击数 | `res.sse` + `SseWriter` |
| `GET` | `/:code` | 短码命中 → 302 重定向 | `res.redirect(302, ...)` + 兜底路由顺序 |

兜底全局错误处理把任何未捕获的异常映射成 `500 + {"error":"..."}`。

#### 运行

```bash
cd examples
cjpm run
# wen-url listening on http://localhost:8080
```

#### 调用示例

创建一个短链:

```bash
curl -X POST -H 'Content-Type: application/json' \
  -d '{"url":"https://github.com/mtpkiss/wen"}' \
  http://localhost:8080/api/links
# {"link":{"code":"a1b2c3","target":"https://github.com/mtpkiss/wen","clicks":0,"createdAt":"..."},"shortUrl":"http://localhost:8080/a1b2c3"}
```

也可以指定一个自定义短码(冲突时会自动改成随机的):

```bash
curl -X POST -H 'Content-Type: application/json' \
  -d '{"url":"https://example.com","code":"hello"}' \
  http://localhost:8080/api/links
```

点几下短链(会 302 重定向,顺手累加点击数):

```bash
curl -i http://localhost:8080/hello
# HTTP/1.1 302 Found
# Location: https://example.com
```

查看元信息:

```bash
curl http://localhost:8080/api/links/hello
# {"code":"hello","target":"https://example.com","clicks":3,"createdAt":"..."}
```

订阅实时点击数(SSE,推 10 秒后结束):

```bash
curl -N http://localhost:8080/api/links/hello/stream
# event: clicks
# data: 3
#
# event: clicks
# data: 3
# ...
```

删除短链(需要 Bearer Token,示例里写死成 `wen-url-admin`):

```bash
curl -X DELETE -H 'Authorization: Bearer wen-url-admin' \
  http://localhost:8080/api/links/hello
# 204 No Content
```

#### 不在覆盖范围之内的事

这个示例是**演示框架用法**的,不是一个生产可用的短链服务。下列事情有意没做:

- 存储是进程内 `HashMap` + `Mutex`,重启即丢——生产请走 Redis / 关系库
- 输入 URL 没有校验,不做去重,不做 phishing 域名拉黑
- 鉴权 token 是硬编码字符串——生产请走 KMS / 配置中心 + 用户体系
- 不限速、不防刷——按 `README` 的"不在覆盖范围"清单,这事是反代 / 网关该管的
- SSE 实现是 `sleep` 轮询;并发用户多的话应走外部 pub/sub
