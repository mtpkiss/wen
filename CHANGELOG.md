# 更新日志

本项目遵循 [语义化版本](https://semver.org/lang/zh-CN/)。

## [Unreleased]

(尚无未发布的改动)

## [0.4.0] - 2026-06-23 — 1.0 锁定就绪

定位为「1.0 锁定前最后一个安全 / API 表面收敛版本」。本批基于四轮深度审查
(round1 50 项 / round2 / round3 复核 / 白盒测试 / 1.0 架构治理)系统落地
**Top 5 安全修复** + **10 项 P0 锁定项**;无可远程触发的崩溃 / 数据损坏。
**包含若干破坏性变更**,详见下方"破坏性"段。

### 安全 / 协议级修复

- **chunked trailer drain — 堵 RFC 7230 §4.1.2 走私通道(P1-A / round3 P1-12)**:
  之前 `size=0` 终止块后只消费一个 CRLF。若客户端发了 trailer 字段
  (`name: value\r\n`...`\r\n\r\n`),wen 把 trailer 字节留在 buf,被下次 readMessage
  当作下一个请求的开头解析,与上游代理对"哪几个字节属于上一个请求"的解读分歧 —
  构成请求走私通道。修复:size=0 后循环读取行直到看到空行;trailer 字段不解析
  但必须 drain 干净;trailer 累计字节有 `maxHeaderBytes` 上限防 DoS。同时修白盒
  报告 G1(trailer 读到一半 EOF 时旧实现返 `Some(残缺帧)`,现在返 `None`)。
- **拒绝多个 `Content-Type` 头,堵类型混淆(P1-D)**:RFC 7231 §3.1.1.5 明确
  Content-Type 必须是单值;wen 之前沿用 RFC 7230 的同名头合并规则,会把
  `application/json` + `image/png` 合并成 `application/json, image/png` —
  `decodeBodyTextIfApplicable` 用 `startsWith` 仍命中 `application/json`,把 PNG
  二进制当 UTF-8 解码进 `req.body`,业务据此判定"是 JSON"实际是 PNG。修复:头部
  合并入口检测,出现第二次 Content-Type 直接 400。
- **form / multipart 跳过 framework-reserved attribute 键(P1-B / round3 P1-10)**:
  framework 内置中间件用 `req.attributes` 存内部状态(`authUser` / `csrfToken` /
  `originalMethod` / `requestId` / `text`)。urlencoded form 解析直接
  `parseQuery(body, attributes)`,multipart 文本字段直接 `attributes[name] = value`
  — 攻击者 POST `authUser=admin` 即可覆盖框架内部状态,下游若用 `req.attribute("authUser")`
  判定身份即被绕过。修复:新增 `isFrameworkReservedAttribute(key)` 判定保留键,form
  / multipart 解析路径跳过这些键;`setAttribute` 显式 API 不在拦截范围(信任边界
  由调用方承担)。

### 1.0 锁定准备(P0 系列)

> 这些改动旨在把 1.0 后 SemVer 锁定前的「API 表面、状态机契约、扩展点」收齐,
> 避免一两年后再用 major 版本翻新。多数为**接续 round2/3/工程评审**报告点出的
> 设计取舍最后窗口。

- **`Application.legacyCookieSecrets: Array<String>` 支持密钥在线轮换(P0-A)**:
  `cookieSecret: String` 单值锁住后无法在线轮换 — 改密钥即作废所有已签发 cookie
  / session。新增 `legacyCookieSecrets` 仅作验签 fallback;`cookieSecret` 仍是
  签发主密钥,不破坏现有 API。`verifySignedCookie` 先尝试主密钥,失败再依次试
  legacy 列表 — 任一匹配即视为有效。部署流程:`cookieSecret = "new",
  legacyCookieSecrets = ["old"]` → 等持旧 cookie 客户端续期 / 过期被切到 new →
  清空 legacy 完成轮换。对应 Express `cookie-parser(['new','old'])` 同款语义。
  session sid cookie 走同一验签路径,自动受益。
- **`HttpResponse.headers` 改 case-insensitive 访问器(P0-B / round2 P2-2 / round3 P2-7)**:
  之前 `public let headers: HashMap<String, String>` case-sensitive,会让
  `res.set("X-Foo","a") + res.append("x-foo","b")` 输出两行同名头。改用 dual map
  设计:`headers` 按用户提供的原始大小写存(输出保留惯例如 `Content-Type` /
  `WWW-Authenticate` / `ETag`),`headersLookup` (lowercase → 原始 key) 做去重索引。
  公开 `set / get / append / has / remove` 全部 case-insensitive;字段降级为同包
  可见。framework 内部 18 处 `res.headers[k] = v` 已统一迁移到 `set()`。
- **`HttpException` 加 `headers: HashMap<String, String>` 字段 + 兜底套头(P0-D)**:
  典型场景 `429 + Retry-After: 60` / `401 + WWW-Authenticate` / `405 + Allow` /
  `503 + Retry-After`。1.0 前预留字段免得未来加破坏 SemVer。兜底:router 默认
  `onError` 把 `he.headers` 套到 res 上;server.handleConnection 的 writeError
  同样把 he.headers 套上。既有 `HttpException(status, msg)` 构造仍可用,默认
  headers 为空 map;子类(`PayloadTooLargeException` / `BadRequestException`)签名
  不变。
- **`SessionStore.touch` 默认实现 + Session.dirty flag(P0-E / round2 P2-7)**:
  接口加 `touch(id)` **带默认实现**(转调 load + save) — 不破坏既有自定义存储。
  Redis 等高级实现可重写为单条 EXPIRE。session 中间件根据 `Session.dirty` 决定
  `save vs touch`:`set`/`remove` 置 dirty,`regenerate` 也置 dirty。无脏请求只
  touch 不重写整张 hash,顺手修 round2 P2-7 写放大。
- **HttpServer 4 个服务器配置字段去 public(P0-L)**:`maxBodySize` / `readTimeoutMs`
  / `maxConnections` / `maxHeaderBytes` 之前在 `Application` 和 `HttpServer` 各有
  一份,用户不知道"哪个才是真生效的值"。降为同包可见,用户配置统一走
  `app.xxx`;HttpServer 是内部 detail。极少数直接 `HttpServer(app)` 构造 + 改字段
  的用户代码需迁移。
- **13 个内部工具函数去 public(P0-F)**:`reasonPhrase` / `splitOnce` / `trimWs`
  / `listContains` / `base64Encode` / `base64Decode` / `lastIndexOfDot` /
  `pathSegments` / `resolveWithinRoot` (util.cj) + `parseQuery` / `parseInt` /
  `urlDecode` (server.cj) + `hmacSha256Hex` (crypto_hmac.cj) — 之前公开但都是包内
  辅助。1.0 锁定后任何签名变化都是 SemVer 破坏,提前缩 API 表面避免永久 freeze
  错误抽象。同包代码(framework + 测试)不受影响。

### 性能

- **ConnReader 改 readStart 指针 + 阈值化 compact(#42 / 工程评审 §1.4)**:之前
  `dropFront` 每条 keep-alive 请求都把剩余字节整段拷回 ArrayList 头部 — O(n)/请求,
  长 pipeline 退化为 O(n²)。改用 `readStart` 指针推进(O(1))+ 累计废字节 ≥
  `maxHeaderBytes` 时一次性物理 compact,摊销 O(1)/请求。配套 `headerSeparatorIndex`
  / `findCRLF` / `sliceList` / `dropFront` 收编为 ConnReader 方法,统一按"逻辑下标
  0 = readStart"工作;`readChunked` 用 `byteAt(i)` 抽象不再直接触碰物理偏移。
- **`hexVal` / `isHexByte` 集中到 util.cj(#45)**:与已有 `b64Val` 并列,作为包内
  字节级 hex 工具的单一来源(`json.cj` readHex4 原本就是同包引用,无需改动调用点)。

### 文档化的契约(1.0 锁定但无代码变化)

- **`Application.handle` 显式契约"req 不可复用"(P0-H 替代改名 / round3 P3-原P1-3)**:
  每对 `(req, res)` 只能 handle 一次。原因:`req.bodyParsed` / `req.cookiesParsed`
  是一次性闸门;`req.res` 互相引用,二次调用篡改前一次链;`res.finished` /
  `headersSent` / `hijacked` 是单调标志位。测试场景每条用例都要 new 一对,不要复用。
  改名 `handle → inject` 涉及 157 处调用,价值低(纯 cosmetic),用文档化替代。
- **Middleware 同步执行契约 + 1.x async 演进路径(P0-K)**:1.0 锁定前明确
  Middleware 是同步的(返回前视为"未完成",next() 必须显式调);仓颉协程模型
  未成熟前无 async/await 等价,重 IO 建议中间件内自己 spawn。1.x 内**可**平行加
  `AsyncMiddleware` 别名;**不会**把 Middleware 改名为 SyncMiddleware(避免 import
  大改)。避免 Koa 1→2 的破坏式迁移重演。
- **`JsonValue` enum 1.0 锁定语言限制说明(P0-G 撤回)**:原计划 enum 限 internal
  只暴露访问器 / 工厂,但 `public type ViewEngine = (String, JsonValue) -> String`
  等公开类型契约要求用户必须持有 JsonValue;仓颉 enum 公开则分支必公开,语言层面
  无法既保 public 又隐藏分支。退路:文档化"用户应优先用 asString/asInt/get/at/keys
  等访问器,而非 case JsonString(s) 直接 match",来日加 `JsonBigInt` 等分支时只
  破坏 match 用户。

### Core 收缩(P0-J,Express 5 拆 csurf 同款模式)

- **wen 仓改 cjpm workspace + wen-contrib 子包(Phase 1 / Phase 2)**:Express 4→5
  把 `body-parser` / `cookie-parser` / `csurf` 移出 core 是因为安全策略变化频繁,
  绑死 core 后小补丁要等框架 release。wen 在 1.0 锁定前一次性把"会随安全态势 /
  行业惯例频繁迭代"的 7 个可选中间件拆到 `wen_contrib` 子包,core 收敛到协议
  + 数据流必需的最小集。
- **顶层目录结构改造**:
    - `cjpm.toml` 改 `[workspace] members = ["wen-core", "wen-contrib"]`
    - `wen-core/`(原 `src/` 整体搬过来)— 主框架 `package wen`
    - `wen-contrib/` — 可选中间件 `package wen_contrib`,via path deps 引主包
    - `demo/`(新)— 独立 executable 演示项目,deps wen + wen_contrib
    - `examples/cjpm.toml` + `benchmark/cjpm.toml` 的 `wen` path 从 `../` 改 `../wen-core`
- **wen_contrib 包含的 7 个中间件**:
    - `helmet`(安全响应头)
    - `csrf`(双提交 Cookie)
    - `cors`(跨域)
    - `basicAuth` / `bearerAuth`(认证)
    - `logger`(请求日志)
    - `requestId`(请求关联 ID)
    - `methodOverride` / `methodOverrideField`(HTML 表单方法重写)
- **wen 主包保留的中间件**:`cookieParser` / `jsonParser` / `urlencodedParser` /
  `textParser` / `rawParser` / `multipart` / `staticFiles` / `session` / `etag`
  — 这些是协议层 / 核心数据流必需,与 HTTP 框架本身的"分发 + 解析"职责直接绑定。
- **wen_contrib 内 helper inline**:`mw_requestid` 内 inline 一份 `toHex64` —
  避免把 `session.cj` 的私有 helper 提升到 wen 主包的 public API。
- **wen 主包内 5 个 P0-F internal 函数恢复 public**(跨包依赖):`splitOnce` /
  `base64Encode` / `base64Decode` / `constantTimeEquals` / `hmacSha256Hex`。其它 8 个
  P0-F internal 函数继续 internal(`reasonPhrase` / `trimWs` / `listContains` /
  `lastIndexOfDot` / `pathSegments` / `resolveWithinRoot` / `parseQuery` /
  `parseInt` / `urlDecode`)。

### 破坏性变更

> 1.0 锁定前最后窗口的破坏性收敛,2.0 前 1.x 仍向前兼容。

- **`helmet` / `csrf` / `cors` / `basicAuth` / `bearerAuth` / `logger` / `requestId`
  / `methodOverride` / `methodOverrideField` 不再从 `import wen.*` 直接可见**。
  用户应用须新增 `wen_contrib` 依赖 + `import wen_contrib.*`。这是
  `Express 4 + body-parser` → `Express 5 + 内置 / 拆 csurf` 的同款迁移模式。
- `public let HttpResponse.headers` → `let headers`(同包可见)。用户代码若曾直接
  `res.headers["X-Y"] = "z"` 读写,需迁移到 `res.set("X-Y", "z")` / `res.get("X-Y")`
  / `res.append / res.has / res.remove`。新访问器全部 case-insensitive。
- `public var HttpServer.maxBodySize` / `readTimeoutMs` / `maxConnections` /
  `maxHeaderBytes` → 同包可见 `var`。直接 `HttpServer(app).maxBodySize = ...` 的极少数
  高级用户需改走 `app.maxBodySize = ...`(Application 主路径)。
- `public func reasonPhrase` / `splitOnce` / `trimWs` / `listContains` /
  `base64Encode` / `base64Decode` / `lastIndexOfDot` / `pathSegments` /
  `resolveWithinRoot` / `parseQuery` / `parseInt` / `urlDecode` / `hmacSha256Hex`
  改 internal。若用户曾直接调用任一函数,1.0 升级时需自己实现等价物。
- `SessionStore` 接口加 `touch(id)` 方法 — 提供默认实现,既有自定义存储零变化即可
  工作(默认转调 load + save);Redis / DB 实现可重写为单条 EXPIRE 提速。

### 已修但不在本批次的关联缺陷

(详见上一批 commit `7d0aef4` "批量修复请求走私 / 并发 / 状态机审查问题":round1 50
项缺陷 25 项修复 + 复核)



## [0.3.0] - 2026-06-17

定位升级为「面向原生高性能」的一个版本:Router 改 trie 索引(派发耗时与路由表规模
解耦),补齐 graceful shutdown、CSRF / methodOverride / multipart 配额等生产关切的
中间件,并收敛默认行为(helmet 改 opt-in、移出 compression / rateLimit / res.links
等越界功能)。**包含破坏性变更**,详见下方。

- **Router 改 trie 索引,派发耗时 O(M)(M=请求段数),不随路由表规模线性增长**:
  在不破坏 Layer 抽象的前提下,给 Router 加三档索引——`prefixLayerIndices`(中间件,
  顺序敏感)、`errorLayerIndices`(错误层)、`routeTrie`(精确路由)。trie 仅做候选过滤,
  真实参数捕获与 `caseSensitive` / `strict` / 正则约束仍由 `PathPattern.matchExact`
  二次保证,**261 个既有测试零退步**。同时 `methodsForPath` / `hasMethodForPath` 也走
  trie 加速,Allow 头与 405 判定提速。
  - 实测(`benchmark/`):50 条路由命中最后一条从 92μs → **16μs(5.6× 提升)**;404 路径
    从 24μs → 13μs;1/10/50 条路由命中耗时**几乎相同**——派发已与路由表规模解耦。
  - 1 条极小路由表场景因 trie 固定开销有约 5μs 退化,真实业务可忽略。
- **README 定位升级为「原生高性能」**:从"中小型 RESTful"扩到"任意规模",
  支撑 trie 改造后的实际能力。
- **README 新增「定位与边界」段**:把"反代后置 + 不覆盖 TLS / 压缩 / 限流 / WebSocket /
  流式大文件 / 多层代理 / handler 超时"这些设计取舍前置声明,与 Express 自身的"专注
  HTTP 应用、运维关切交给生态"哲学一致。
- **`res.cookie` 自动给 `SameSite=None` 补 `Secure`**:Chrome 80+ / Firefox / Safari
  对 `SameSite=None` 缺 `Secure` 一律拒绝;现在调用 `res.cookie(..., sameSite: "None")`
  即使没传 `secure: true` 也会自动补上 `Secure`,以防呆。大小写不敏感;显式传
  `secure: true` 时仍只输出一次。
- **新增 `app.close(timeoutMs!)` 优雅关闭**:对应 Express + Node 生态里的 SIGTERM 排空。
  机制:置 shutdown 信号 → 关 server socket(中断阻塞的 accept)→ 在途连接处理完
  当前请求并断开 keep-alive(响应自动加 `Connection: close`)→ 等 drain 完成或
  `timeoutMs` 超时。重复调用幂等。典型用法:在另一协程里 `spawn { app.listen(8080) }`,
  收到关闭信号时主线程 `app.close(timeoutMs: 5000)`,容器 / k8s 滚动发布从此不丢请求。
- **`helmet` HSTS 三档可调**:新增 `hstsMaxAge!`(默认 15552000 / 180 天,保持向后兼容)、
  `hstsIncludeSubDomains!`(默认 true)、`hstsPreload!`(默认 false)三个具名参数。
  preload 是不可撤销的浏览器内置承诺,默认关闭以免误开;生产 preload 标配可写
  `helmet(hstsMaxAge: 31536000, hstsPreload: true)`。
- **新增 `multipart(maxFileSize!, maxFiles!, maxFields!, fileFilter!)` 配额与过滤**:
  以前的 `multipart()` 只是「提前触发解析」的薄壳;现升级为可配置的安全闸门。三档上限
  任一超出抛 `PayloadTooLargeException`,默认错误兜底回 413;`fileFilter` 拒绝的文件
  静默丢弃,语义与 multer 对齐。默认参数皆为「不限」,旧调用 `app.use(multipart())`
  行为完全兼容。
- **router 默认错误兜底升级**:此前所有未处理异常统一回 500。现把 `PayloadTooLargeException`
  映射为 413、`BadRequestException` 映射为 400(与 server 层 read body 阶段的行为一致),
  其余未知异常仍按 500 兜底。用户注册了错误中间件时,先到错误中间件;它未结束响应才走兜底。
- **`res.jsonp` 明确不在范围内**:能力一览 / ROADMAP / API 参考 / 0.2.0 发布说明里此前
  错误声称已实现 `res.jsonp`(实际从未实现)。JSONP 是 CORS 之前的跨域方案,现代 Web
  已用浏览器原生 fetch + CORS 覆盖,wen 作为新框架无兼容包袱,正式声明不实现。文档已修正。
- **新增 `csrf()` 中间件**:对应 Express 生态的 csurf,签名双提交 Cookie。GET 时下发签名
  Cookie 并把 token 暴露到 `req.attribute("csrfToken")`;非安全方法要求回传匹配 token
  (请求头 `X-CSRF-Token` / `X-XSRF-Token`,或表单字段 / 查询串 `_csrf`),不一致或缺失回 403。
- **新增 `methodOverride()` / `methodOverrideField()` 中间件**:让 HTML 表单借助请求头
  (默认 `X-HTTP-Method-Override`)或字段 / 查询串(默认 `_method`)把 POST 重写为
  PUT / DELETE / PATCH。仅对 POST 生效,目标须是已知方法;原方法存入
  `req.attribute("originalMethod")`。
- **路由调度调整**(为让上述中间件生效):`Router` 把 method 检查从「请求开始时预筛」
  推迟到「dispatch 执行时实时判定」。位于路由前的中间件改写 `req.method` 后,后续 layer
  会按新方法重新匹配,与 Express 的动态分发语义一致。对既有路由匹配行为无可见影响。
- **请求体 / Cookie 解析内置化**:JSON / 表单 / multipart / Cookie 改为「首次访问 `req.json()` /
  `attribute()` / `file()` / `cookie()` 时按 Content-Type 自动懒解析」,**无需再 `app.use` 解析中间件**;
  原 `jsonParser` / `urlencodedParser` / `multipart` / `cookieParser` 工厂保留为薄壳(提前触发),不破坏现有代码。
- **helmet**:默认只发部署无关、不会误伤的头(`nosniff` / `X-Frame-Options` / `Referrer-Policy` / HSTS);
  `csp` 与新增的 `coop` / `corp` 改为 **opt-in**(默认不发,需显式传值)。此前 CSP 默认 `default-src 'self'`、
  COOP/CORP 无条件下发,易静默打挂外部资源 / 跨窗口通信。
- **logger**:精简为「每请求一行」+ 一个 `format` 钩子(`(req, res, 毫秒) -> String`);移除原先的
  7 个布尔开关与 ANSI 上色——定制统一交给 `format`。
- **rateLimit**:**移出内置**。限流是网关 / 基础设施层职责,单实例内存计数对多实例不可靠。
- **compression(gzip)**:**移出内置**。响应压缩属边缘 / 反代职责(nginx `gzip on;`,与 TLS 终止同一层),
  自写的固定哈夫曼 DEFLATE 压缩率本就不如 zlib。删除 `gzip.cj` 与 `compression()`——需要压缩在边缘开启。
- **res.links**:移除冷门的分页 `Link` 头便利方法(纯字符串拼接,`res.set("Link", ...)` 即可替代)。
- **docs**:更正「内置 `{{ key }}` 模板引擎」的表述——框架本就不内置模板引擎,需 `app.engine` 注册。

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
- **视图渲染**:`res.render` + `app.engine`(框架不内置模板引擎,由用户注册任意引擎)。
- **中间件**:`helmet`(安全头)、`compression`(自写 gzip)、`rateLimit`(限流)、
  `basicAuth`/`bearerAuth`(认证)、`requestId`、`multipart`(文件上传)、`session`(签名
  sid + 内存 store)、`etag`。
- **会话与安全**:HMAC-SHA256 签名 Cookie(`res.cookie(signed: true)` / `req.signedCookie`)、
  `session()`、自写 `base64Encode/Decode`、`hmacSha256Hex`。
- **响应细节**:`res.vary`、带状态码的 `res.redirect`、cookie 的
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
