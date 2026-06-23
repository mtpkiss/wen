package wen

/*
 * 框架范围内共享的核心「函数类型」契约定义。
 *
 * 这几个类型别名是整个 Wen 框架的骨架约定，处理请求的各个环节都围绕它们展开：
 *
 * - `Next`：一个无参无返回的回调。调用它表示「当前这一层处理完毕，把控制权
 *   交给中间件链中下一个匹配的层」。是否调用 next 决定了请求是继续向后流动
 *   还是就此终止（例如某个中间件直接写回响应而不调用 next，后续层就不会执行）。
 *
 * - `Middleware`：框架里最通用的处理单元，形如 (请求, 响应, next)。无论是路由
 *   处理函数、插件，还是全局中间件，最终都归一成这同一种形状——这与 Express 的
 *   `(req, res, next)` 完全对应。统一成一种类型，调度器才能用同一套逻辑串联它们。
 */
public type Next = () -> Unit

// **同步执行契约(P0-K 1.0 锁定)**:Middleware 当前是同步的 — 函数返回前,
// 当前层被视为"未完成"(下一层不会自动推进,必须显式调 next())。仓颉的协程
// 模型成熟前,Middleware 没有 async/await 等价。若用户有重 IO,建议在中间件
// 内 `spawn { ... }` 自行调度,不要让框架主调度等。
//
// 1.x 内**可**平行加 `AsyncMiddleware = (...) -> Future<Unit>` 等别名而不
// 破坏 Middleware;但**不会**把 Middleware 改名为 SyncMiddleware,以避免现有
// 应用的 import / 类型注解大面积变更。这与 Koa 1→2 从 `(ctx, next)` →
// `async (ctx, next) => await next()` 的破坏式迁移形成对照 — Koa 是反面教材。
public type Middleware = (HttpRequest, HttpResponse, Next) -> Unit

// 「终结型」处理器：形如 (请求, 响应)，相比 Middleware 少了 next 参数。
// 它适用于那些必然会自己产出响应、不打算把控制权再往后传的处理函数——既然
// 不会调用 next，干脆在签名里就省掉它，让业务代码写起来更干净。框架内部会用
// 一个包装器把它适配成标准 Middleware（补上一个被忽略的 next）后再纳入调度。
public type Handler = (HttpRequest, HttpResponse) -> Unit

// 「错误处理型」中间件，形如 (异常, 请求, 响应, next)，对应 Express 的
// `(err, req, res, next)`。它比普通中间件多了第一个异常参数，专门用来处理
// 请求处理过程中抛出的错误。
//
// 行为要点：这类中间件只在「有异常正在传播」时才会被触发——正常请求流中它会
// 被跳过。在错误处理器内部调用 next() 并不会前进到普通中间件，而是把同一个
// 异常继续交给链上的下一个错误处理器；若后面再没有错误处理器，则落到框架
// 默认的 500 响应兜底。借此可以串联多个错误处理器，实现分级 / 兜底的错误处理。
public type ErrorHandler = (Exception, HttpRequest, HttpResponse, Next) -> Unit

// 「参数预处理」回调,对应 Express 的 `app.param(name, fn)`。当某条匹配的路由捕获
// 到同名参数时,会在执行该路由处理器之前触发一次(同一请求、同一参数名只触发一次),
// 拿到 (请求, 响应, 该参数的值)。常用于集中校验参数、按参数加载资源并存入 req.locals
// 等;回调内可直接结束响应来短路后续处理,或抛出异常交给错误处理流水线。
public type ParamHandler = (HttpRequest, HttpResponse, String) -> Unit

// 「视图引擎」契约,对应 Express 的模板引擎。入参为「已解析好的模板文件绝对/相对
// 路径」与「渲染数据(用框架自带的 JsonValue 表示)」,返回渲染后的字符串(通常是
// HTML)。引擎自行负责读取该模板文件。通过 app.engine(ext, fn) 为某扩展名注册;
// 未注册时 res.render 抛异常——框架自身不内置默认引擎。
public type ViewEngine = (String, JsonValue) -> String

// 「请求体解析器」契约:形如 (请求) -> Unit。当请求的主 Content-Type 与注册时指定的
// 类型匹配时,框架在懒解析请求体阶段(HttpRequest.ensureBody)调用它,由它读取
// req.body / req.bodyBytes 并把解析结果写回请求对象(通常经 req.setLocal 暂存对象供
// 下游取用)。经 app.bodyParser(contentType, fn) 注册;可扩展或覆盖内置的
// json / urlencoded / multipart 解析。
public type BodyParser = (HttpRequest) -> Unit
