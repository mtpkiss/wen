package wen

/**
 * 中间件链「向下传递控制权」的回调。
 *
 * 一个无参无返回的函数。调用 next() 表示「当前这一层处理完毕,把控制权交给链中
 * 下一个匹配的层」。是否调用 next 决定请求是继续向后流动还是就此终止——某个中
 * 间件直接写回响应而不调用 next,后续层就不会执行。
 *
 * Next 是 [[Middleware]] / [[ErrorHandler]] 签名里的第三个/第四个参数,也是
 * 整个框架调度模型的核心契约。
 */
public type Next = () -> Unit

/**
 * 框架里最通用的处理单元,形如 (请求, 响应, next)。
 *
 * 无论是路由处理函数、插件,还是全局中间件,最终都归一成这同一种形状——这与
 * Express 的 `(req, res, next)` 完全对应。统一成一种类型,调度器才能用同一套
 * 逻辑串联它们。也接受 [[Handler]],框架自动用一个包装器补上被忽略的 next。
 *
 * **同步执行契约 (P0-K 1.0 锁定)**:Middleware 当前是同步的——函数返回前,当前
 * 层被视为"未完成"(下一层不会自动推进,必须显式调 next())。仓颉的协程模型成
 * 熟前,Middleware 没有 async/await 等价。若用户有重 IO,建议在中间件内
 * `spawn { ... }` 自行调度,不要让框架主调度等。
 *
 * 1.x 内**可**平行加 `AsyncMiddleware = (...) -> Future<Unit>` 等别名而不破坏
 * Middleware;但**不会**把 Middleware 改名为 SyncMiddleware,以避免现有应用的
 * import / 类型注解大面积变更。这与 Koa 1→2 从 `(ctx, next)` →
 * `async (ctx, next) => await next()` 的破坏式迁移形成对照——Koa 是反面教材。
 */
public type Middleware = (HttpRequest, HttpResponse, Next) -> Unit

/**
 * 「终结型」处理器,形如 (请求, 响应),相比 [[Middleware]] 少了 next 参数。
 *
 * 适用于那些必然会自己产出响应、不打算把控制权再往后传的处理函数——既然不会调用
 * next,干脆在签名里就省掉它,让业务代码写起来更干净。框架内部会用一个包装器把它
 * 适配成标准 Middleware(补上一个被忽略的 next)后再纳入调度。
 */
public type Handler = (HttpRequest, HttpResponse) -> Unit

/**
 * 「错误处理型」中间件,形如 (异常, 请求, 响应, next),对应 Express 的
 * `(err, req, res, next)`。比普通 [[Middleware]] 多了第一个异常参数,专门用来处理
 * 请求处理过程中抛出的错误。
 *
 * 行为要点:这类中间件只在「有异常正在传播」时才会被触发——正常请求流中它会被跳过。
 * 在错误处理器内部调用 [[Next]] 并不会前进到普通中间件,而是把同一个异常继续交给链
 * 上的下一个错误处理器;若后面再没有错误处理器,则落到框架默认的 500 响应兜底。借此
 * 可以串联多个错误处理器,实现分级 / 兜底的错误处理。
 *
 * 第一个参数是基类 `Exception`,**按异常子类型分发需自行 `match`**;不认识的类型应交给
 * `next(...)` 继续向后传,而非一律吞掉:
 * ```
 * app.useError({ err, _, res, next =>
 *     match (err) {
 *         case he: HttpException => res.status(he.status).send(he.message) // 已知:映射状态码
 *         case _: MyDomainException => res.status(422).send("domain error") // 自定义业务异常
 *         case _ => next(err) // 不认识 → 交给下一个错误处理器 / 默认 500 兜底
 *     }
 * })
 * ```
 */
public type ErrorHandler = (Exception, HttpRequest, HttpResponse, Next) -> Unit

/**
 * 「参数预处理」回调,对应 Express 的 `app.param(name, fn)`。
 *
 * 当某条匹配的路由捕获到同名参数时,会在执行该路由处理器之前触发一次(同一请求、同
 * 一参数名只触发一次),拿到 (请求, 响应, 该参数的值)。常用于集中校验参数、按参数加
 * 载资源并存入 req.locals 等;回调内可直接结束响应来短路后续处理,或抛出异常交给错
 * 误处理流水线。
 */
public type ParamHandler = (HttpRequest, HttpResponse, String) -> Unit

/**
 * 「视图引擎」契约,对应 Express 的模板引擎。
 *
 * 入参为「已解析好的模板文件绝对/相对路径」与「渲染数据(用框架自带的 [[JsonValue]]
 * 表示)」,返回渲染后的字符串(通常是 HTML)。引擎自行负责读取该模板文件。通过
 * `app.engine(ext, fn)` 为某扩展名注册;未注册时 `res.render` 抛异常——框架自身不内
 * 置默认引擎。
 */
public type ViewEngine = (String, JsonValue) -> String

/**
 * 「请求体解析器」契约,形如 (请求) -> Unit。
 *
 * 当请求的主 Content-Type 与注册时指定的类型匹配时,框架在懒解析请求体阶段
 * ([[HttpRequest]].ensureBody)调用它,由它读取 req.body / req.bodyBytes 并把解析
 * 结果写回请求对象(通常经 req.setLocal 暂存对象供下游取用)。经
 * `app.bodyParser(contentType, fn)` 注册;可扩展或覆盖内置的 json / urlencoded /
 * multipart 解析。
 */
public type BodyParser = (HttpRequest) -> Unit
