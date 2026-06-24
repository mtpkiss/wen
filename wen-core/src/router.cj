package wen

import std.collection.*
import std.regex.*
import std.sync.*

/*
 * 路由核心。
 *
 * 一个路径模式(pattern)在编译后被拆解成一串「段(segment)」。路径以 "/" 分隔,
 * 每一段都属于下面三种类型之一:
 *   - Literal("users") : 字面量段，请求中对应的那一段必须与之逐字符完全相等。
 *   - Param("id")      : 参数段，可匹配任意一段非空内容，并把该段的值以参数名
 *                        "id" 为键捕获到 req.params 里。
 *   - Wildcard         : 通配段，写作 "*"，贪婪地吞掉请求路径中剩余的全部段，
 *                        因此它只在模式末尾有意义。
 *
 * 编译后的模式支持两种匹配模式:
 *   - exact(精确匹配) : 供路由处理器(get/post/... 注册的路由)使用，要求整条
 *                        请求路径与模式逐段一一对应、长度一致，不能多也不能少。
 *   - prefix(前缀匹配): 供挂载式中间件(use(path, mw))使用，只要求模式是请求
 *                        路径的「前缀」——模式的所有段都能在请求路径开头依次匹配
 *                        上即可，请求路径后面可以还有更多段。
 */
enum SegKind {
    | Literal
    | Param
    | Wildcard
}

class Segment {
    let kind: SegKind
    let value: String // 对字面量段是其文本内容；对参数段是参数名
    let constraint: ?Regex // 仅参数段可能用到：一个已加锚定的可选正则约束
    let optional: Bool // 仅参数段可能用到：该段是否可缺省（":name?" 写法）

    init(kind: SegKind, value: String) {
        this.kind = kind
        this.value = value
        this.constraint = None
        this.optional = false
    }

    init(kind: SegKind, value: String, constraint: ?Regex, optional: Bool) {
        this.kind = kind
        this.value = value
        this.constraint = constraint
        this.optional = optional
    }
}

/**
 * 已编译的路由路径模式。
 *
 * 把字符串路径(如 `/users/:id`、`/posts/:slug?`、或带尾部通配的 `/files/` + 星号)
 * 编译成段序列,支持参数捕获(`:name`)、可选段(`:name?`)、参数约束(`:id(\d+)`)、
 * 尾部通配。匹配成功时把捕获到的参数填入 `req.params`,失败则返回 false。
 *
 * 内部由 [[Router]] 使用,通常应用代码不直接构造。
 */
public class PathPattern {
    let segments: ArrayList<Segment>
    let hasWildcard: Bool
    // 编译时记录原始模式路径是否以 "/" 结尾;严格路由模式下,只有同样以 "/" 结尾
    // (或同样不以 "/" 结尾)的请求才被视为精确匹配。非严格模式下该字段不参与匹配。
    // 根模式("/")不算「尾部斜杠」(否则会把所有路径都强制要求带尾斜杠)。
    let trailingSlash: Bool

    init(segments: ArrayList<Segment>, hasWildcard: Bool, trailingSlash: Bool) {
        this.segments = segments
        this.hasWildcard = hasWildcard
        this.trailingSlash = trailingSlash
    }

    public static func compile(path: String): PathPattern {
        let segs = ArrayList<Segment>()
        var wildcard = false
        // 仅当路径非根("/" 仅一个字符,但 endsWith("/") 为真)且确实以 "/" 结尾时记为有尾斜杠。
        let trailing = path.size > 1 && path.endsWith("/")
        for (raw in pathSegments(path)) {
            // 通配段 "*" 之后再出现任意段都会被静默吞掉(匹配阶段 Wildcard 直接 return
            // true,trie 索引也只走到 Wildcard 后中断),与文档承诺的"通配只在末尾有
            // 意义"不符。注册阶段拒掉中间段 wildcard,让歧义在编译期就报出来。
            if (wildcard) {
                throw Exception("wen: 通配段 '*' 只允许出现在路径末尾;中段之后的段会被静默吞掉")
            }
            if (raw == "*") {
                segs.add(Segment(Wildcard, "*"))
                wildcard = true
            } else if (raw.startsWith(":")) {
                // 参数段写法为 ":name"、":name(pattern)"，并都可在末尾加 "?" 表示该段
                // 可缺省(":name?" / ":name(pattern)?")。括号内的正则用来约束这一单段
                // 必须长成什么样子(Express 风格);下面会给它套上 ^(?:...)$ 锚定，
                // 使其必须匹配整段、而非只匹配其中一部分。
                var spec = raw[1..raw.size]
                var optional = false
                if (spec.endsWith("?")) {
                    optional = true
                    spec = spec[0..(spec.size - 1)]
                }
                match (spec.indexOf("(")) {
                    case Some(p) =>
                        if (spec.endsWith(")")) {
                            let name = spec[0..p]
                            // 空参数名("/users/:" / "/users/:(\d+)")是 typo,会导致
                            // params[""] 静默写入,后续 req.param("") 才取得到 — 注册
                            // 时直接拒,debug 友好。
                            if (name.isEmpty()) {
                                throw Exception("wen: 参数段缺少参数名(写法 ':name')")
                            }
                            let pat = spec[(p + 1)..(spec.size - 1)]
                            segs.add(Segment(Param, name, Some(Regex("^(?:" + pat + ")$")), optional))
                        } else {
                            if (spec.isEmpty()) {
                                throw Exception("wen: 参数段缺少参数名(写法 ':name')")
                            }
                            segs.add(Segment(Param, spec, None, optional))
                        }
                    case None =>
                        if (spec.isEmpty()) {
                            throw Exception("wen: 参数段缺少参数名(写法 ':name')")
                        }
                        segs.add(Segment(Param, spec, None, optional))
                }
            } else {
                segs.add(Segment(Literal, raw))
            }
        }
        return PathPattern(segs, wildcard, trailing)
    }

    // 精确匹配。匹配成功时返回捕获到的参数表(键为参数名)，失败时返回 None。
    // caseSensitive=false 时按大小写无关比较字面段;strict=true 时要求请求路径与模式的
    // 尾部斜杠形态一致(仅影响精确匹配,前缀匹配始终按现有 segment 维度比较)。
    public func matchExact(path: String, caseSensitive!: Bool = true, strict!: Bool = false): ?HashMap<String, String> {
        if (strict) {
            let reqTrailing = path.size > 1 && path.endsWith("/")
            if (reqTrailing != this.trailingSlash) {
                return None
            }
        }
        return doMatch(pathSegments(path), false, caseSensitive)
    }

    // 前缀匹配，供挂载式中间件使用(只要求模式是请求路径的前缀)。
    public func matchPrefix(path: String, caseSensitive!: Bool = true): ?HashMap<String, String> {
        return doMatch(pathSegments(path), true, caseSensitive)
    }

    private func doMatch(parts: Array<String>, prefix: Bool, caseSensitive: Bool): ?HashMap<String, String> {
        let params = HashMap<String, String>()
        if (matchFrom(0, parts, 0, prefix, params, caseSensitive)) {
            return params
        }
        return None
    }

    // 回溯式匹配:尝试让模式从第 si 段、请求路径从第 pi 段起对齐。成功返回 true，
    // 并把沿途捕获的参数写入 params;失败返回 false。
    // 之所以用回溯而非简单的线性扫描，是为了正确处理可缺省参数(":name?"):碰到
    // 可缺省段时，先试「消费一段」，若后续匹配不下去再回退试「跳过该段」。
    private func matchFrom(si: Int64, parts: Array<String>, pi: Int64, prefix: Bool, params: HashMap<String, String>,
        caseSensitive: Bool): Bool {
        if (si >= segments.size) {
            // 模式已全部用完。前缀匹配:请求路径还剩多余段也算成功;精确匹配:
            // 请求路径必须正好也用完。
            if (prefix) {
                return true
            }
            return pi >= parts.size
        }
        let seg = segments[si]
        match (seg.kind) {
            case Wildcard =>
                // 通配段:吞掉请求路径剩余的全部段，直接判定成功。
                return true
            case Param =>
                if (seg.optional) {
                    // 先尝试消费当前这一段(需有可用段且满足正则约束)。
                    if (pi < parts.size && constraintOk(seg, parts[pi])) {
                        params[seg.value] = urlDecode(parts[pi])
                        if (matchFrom(si + 1, parts, pi + 1, prefix, params, caseSensitive)) {
                            return true
                        }
                        // 走不通则回退:撤销本段的捕获，改为「跳过该可缺省段」。
                        params.remove(seg.value)
                    }
                    return matchFrom(si + 1, parts, pi, prefix, params, caseSensitive)
                }
                if (pi >= parts.size) {
                    return false
                }
                if (!constraintOk(seg, parts[pi])) {
                    return false
                }
                // 捕获到的参数值会做 URL 解码(例如 "john%20doe" -> "john doe")。
                params[seg.value] = urlDecode(parts[pi])
                return matchFrom(si + 1, parts, pi + 1, prefix, params, caseSensitive)
            case Literal =>
                if (pi >= parts.size) {
                    return false
                }
                let same = if (caseSensitive) {
                    seg.value == parts[pi]
                } else {
                    seg.value.toAsciiLower() == parts[pi].toAsciiLower()
                }
                if (!same) {
                    return false
                }
                return matchFrom(si + 1, parts, pi + 1, prefix, params, caseSensitive)
        }
    }

    // 参数段的正则约束是否放行:无约束恒为 true;有约束时要求整段匹配该锚定正则。
    func constraintOk(seg: Segment, part: String): Bool {
        match (seg.constraint) {
            case Some(rx) => return rx.matches(part)
            case None => return true
        }
    }
}

// 一个已注册的「路由层(layer)」。它打包了一条注册项需要的全部信息:方法过滤
// 条件、编译好的路径模式、要执行的处理器，以及它是否是挂载式(前缀)中间件。
// 路由器内部就是按注册顺序维护一串这样的 Layer。
class Layer {
    let method: ?String // None 表示不限方法，任意请求方法都匹配
    let pattern: PathPattern
    let handler: Middleware
    let isPrefix: Bool
    let isError: Bool
    let errorHandler: ?ErrorHandler
    // 同一次注册产生的若干处理器(多处理器路由)共享同一个 routeId，供 next("route")
    // 据此跳过「当前这条路由」剩余的处理器。错误层用 0。
    let routeId: Int64

    init(method: ?String, path: String, handler: Middleware, isPrefix: Bool, routeId: Int64) {
        this.method = method
        this.pattern = PathPattern.compile(path)
        this.handler = handler
        this.isPrefix = isPrefix
        this.isError = false
        this.errorHandler = None
        this.routeId = routeId
    }

    // 错误处理层的构造器:这种层在路径/方法上对任何请求都「匹配」，但它只在链中
    // 有错误正在传递时才会真正被执行(详见 Router.dispatch 的错误模式处理)。
    init(errorHandler: ErrorHandler) {
        this.method = None
        this.pattern = PathPattern.compile("/")
        this.handler = {_: HttpRequest, _: HttpResponse, _: Next => ()}
        this.isPrefix = false
        this.isError = true
        this.errorHandler = Some(errorHandler)
        this.routeId = 0
    }

    // 仅按路径匹配,不查方法。trie 圈出精确路由候选后,Router 用本方法对 prefix 中间件
    // 与 trie 候选做二次路径验证;method 检查仍推迟到 dispatch 阶段,以便 methodOverride
    // 这类中间件在链中改写 req.method 后,后续 layer 按新方法实时判定。
    func tryMatchPath(req: HttpRequest, caseSensitive: Bool, strict: Bool): ?HashMap<String, String> {
        if (this.isError) {
            return Some(HashMap<String, String>())
        }
        if (this.isPrefix) {
            return this.pattern.matchPrefix(req.path, caseSensitive: caseSensitive)
        }
        return this.pattern.matchExact(req.path, caseSensitive: caseSensitive, strict: strict)
    }

    // 本层声明的方法是否与请求当前的方法相容。error 层不限制方法。
    func methodMatches(method: String): Bool {
        if (this.isError) {
            return true
        }
        match (this.method) {
            case Some(m) => return m == HttpMethod.ALL || m == method
            case None => return true
        }
    }
}

/**
 * 路由表与中间件链的核心调度器,对应 Express 的 `express.Router()`。
 *
 * Router 既是 [[Application]] 的底层实现,也可以独立实例化并通过 `app.use(path, router)`
 * 挂载到任意前缀下,从而把功能拆分到独立的子模块。提供与 Application 同名 / 同形参
 * 的注册入口:`use` / `get` / `post` / `put` / `delete` / `patch` / `head` /
 * `options` / `all` / `param` / `useError`,以及 `route(path)` 取得绑定到该路径的
 * [[Route]] 用于多动词链式注册。
 *
 * 链式调用:所有注册方法都返回 `this`。所有处理器接受 [[Middleware]] 或 [[Handler]]
 * 两种形式(后者由框架自动包装成 Middleware)。
 *
 * **冻结约束**:[[Application]].listen 启动后整张路由表会被冻结,此后再注册路由会
 * 抛 [[IllegalStateException]]——请求处理线程会并发遍历路由表,运行时再写就是数
 * 据竞争。
 */
public class Router {
    let layers: ArrayList<Layer> = ArrayList<Layer>()
    // 路由表是否已"冻结":Application.listen 启动后设为 true,此后所有写操作
    // (use / get / post / param / useError 等)都抛 IllegalStateException。
    // 请求处理线程会并发遍历 layers / paramCallbacks / routeTrie,运行时再写就是
    // 数据竞争。
    let frozen: AtomicBool = AtomicBool(false)
    // 已注册路由数的递增计数器,用于给每次注册分配唯一的 routeId(多处理器路由
    // 的各处理器共享同一个 id)。
    var routeCounter: Int64 = 0
    // app.param 注册的参数预处理回调表,键为参数名 → 该名下的回调列表。
    // P2-G:同名注册多次按顺序依次执行(与 Express 一致),早先用 `HashMap<..., ParamHandler>`
    // 只能存最后一个,前面注册的被静默丢失。
    let paramCallbacks: HashMap<String, ArrayList<ParamHandler>> = HashMap<String, ArrayList<ParamHandler>>()

    // ---- 三档索引:由 add/addAll/useError 在注册时同步维护,runChain 用它们以 O(M)
    // 量级完成派发查询(M 为请求路径段数),替代原来在 layers 上 O(N) 的线性扫描。
    //   prefixLayerIndices : use(...) 注册的前缀中间件,保留注册顺序;运行时逐条做 prefix 匹配。
    //   errorLayerIndices  : useError(...) 注册的错误层,数量极少,顺序扫即可。
    //   routeTrie          : get/post/... 注册的精确路由 layerIndex 索引,trie 圈定候选;
    //                        真实参数捕获与 caseSensitive / strict 校验仍由 PathPattern.matchExact 完成。
    let prefixLayerIndices: ArrayList<Int64> = ArrayList<Int64>()
    let errorLayerIndices: ArrayList<Int64> = ArrayList<Int64>()
    let routeTrie: RouteNode = RouteNode()

    // 当本 Router 被挂载到某 Application/Router 的某前缀下时,该前缀路径(对应 Express 的
    // app.mountpath)。顶级 Router 默认为空串。Application.use(path, sub)/Router.use(path, sub)
    // 会自动设置;多次挂载时以最后一次为准。
    public var mountpath: String = ""

    // 路由匹配的两项行为开关,对应 Express 的 'case sensitive routing' 与 'strict routing'。
    // 默认值匹配 Express:caseSensitive=false(大小写无关,/Foo 与 /foo 视为同一路由)、
    // strict=false(尾部斜杠无关,/foo 与 /foo/ 视为同一路由)。
    // 由 Application.handle 从应用 settings 读取后写入;直接构造 Router 也可手动设置。
    public var caseSensitive: Bool = false
    public var strict: Bool = false

    // P1-7:挂载的子 Router 引用列表。markFrozen / handle 兜底路径会递归把
    // case sensitive / strict 设置下发到所有子 router — 否则全局开关只在顶级生效。
    let mountedSubRouters: ArrayList<Router> = ArrayList<Router>()
    // layer idx → 挂载在该 prefix-mount layer 下的子 Router。
    // hasMethodForPath / methodsForPath / hasAllRouteForPath 用它递归到子路由,
    // 让 HEAD-fallback 与 Allow 头能覆盖子路由内的方法注册。父级 router 只持有
    // 一个把请求转发给 sub.handleAsMiddleware 的 lambda layer,无法从 layer 反推
    // 出子 router 引用,所以单独建一份映射(以 layer idx 为键)。
    let mountedRouterByLayer: HashMap<Int64, Router> = HashMap<Int64, Router>()

    public init() {}

    // P1-7:递归把 case sensitive / strict 设置写入本 router 及所有挂载子 router。
    // 由 Application.markFrozen / handle 调用,确保子路由的匹配行为与顶级一致。
    func propagateRoutingSettings(cs: Bool, st: Bool): Unit {
        this.caseSensitive = cs
        this.strict = st
        for (sub in mountedSubRouters) {
            sub.propagateRoutingSettings(cs, st)
        }
    }

    func freshRouteId(): Int64 {
        routeCounter += 1
        return routeCounter
    }

    // 由 Application.listen 联动设置;Application.close 完成后通过 unfreeze() 联动复位,
    // 允许同实例的"启 → 停 → 再启"循环(Express 兼容)。子路由若被挂载,Application
    // 启动前已注册完毕,运行阶段不再需要写它们;冻结同样适用,并随顶级 unfreeze 一同复位。
    func freeze(): Unit {
        frozen.store(true)
    }

    // 由 Application.close 在 HttpServer.shutdown 返回后联动调用。彼时所有 worker 已退出,
    // 不存在并发请求线程读 router 字段;此时把 frozen 复位、递归下发到所有子 router,以让
    // 后续的 use/get/... 等注册路径恢复可写。
    func unfreeze(): Unit {
        frozen.store(false)
        for (sub in mountedSubRouters) {
            sub.unfreeze()
        }
    }

    func ensureNotFrozen(): Unit {
        if (frozen.load()) {
            throw IllegalStateException("wen: 应用已 listen,不能再注册路由 / 中间件;请在 listen() 之前完成注册")
        }
    }

    func add(method: ?String, path: String, handler: Middleware, isPrefix: Bool): Unit {
        ensureNotFrozen()
        let idx = layers.size
        let layer = Layer(method, path, handler, isPrefix, freshRouteId())
        layers.add(layer)
        indexLayer(layer, idx)
    }

    // 一次注册多个处理器到同一方法/路径:它们按顺序排成相邻的多个 Layer，共享同一个
    // routeId。前一个处理器调用 next() 即推进到下一个;调用 req.nextRoute() 则跳过
    // 本组剩余处理器,直达下一条路由。
    func addAll(method: ?String, path: String, handlers: Array<Middleware>, isPrefix: Bool): Unit {
        ensureNotFrozen()
        let id = freshRouteId()
        for (h in handlers) {
            let idx = layers.size
            let layer = Layer(method, path, h, isPrefix, id)
            layers.add(layer)
            indexLayer(layer, idx)
        }
    }

    // 把新注册的 layer 同步索引到三档桶之一。精确路由额外插入 trie。
    func indexLayer(layer: Layer, idx: Int64): Unit {
        if (layer.isError) {
            errorLayerIndices.add(idx)
        } else if (layer.isPrefix) {
            prefixLayerIndices.add(idx)
        } else {
            insertRouteIntoTrie(routeTrie, layer.pattern.segments, idx)
        }
    }

    // 注册一个参数预处理回调(对应 Express 的 app.param)。当匹配到的路由捕获了名为
    // `name` 的参数时,会在该路由处理器执行前触发此回调(每个请求每个参数名只触发一次)。
    public func param(name: String, handler: ParamHandler): Unit {
        ensureNotFrozen()
        // P2-G:同名 param 累加到 ArrayList,不覆盖前者。
        match (paramCallbacks.get(name)) {
            case Some(list) => list.add(handler)
            case None =>
                let list = ArrayList<ParamHandler>()
                list.add(handler)
                paramCallbacks[name] = list
        }
    }

    // 全局中间件:对每个请求都执行。以根路径 "/" 作前缀注册，前缀匹配下它能
    // 命中任意路径，因此等价于「对所有请求生效」。
    public func use(handler: Middleware): Unit {
        add(None, "/", handler, true)
    }

    // 挂载式中间件:只对路径处于 `path` 之下(以 path 为前缀)的请求执行。
    public func use(path: String, handler: Middleware): Unit {
        rejectOptionalInMountPath(path)
        add(None, path, handler, true)
    }

    public func get(path: String, handler: Middleware): Unit {
        add(Some(HttpMethod.GET), path, handler, false)
    }
    public func post(path: String, handler: Middleware): Unit {
        add(Some(HttpMethod.POST), path, handler, false)
    }
    public func put(path: String, handler: Middleware): Unit {
        add(Some(HttpMethod.PUT), path, handler, false)
    }
    public func delete(path: String, handler: Middleware): Unit {
        add(Some(HttpMethod.DELETE), path, handler, false)
    }
    public func patch(path: String, handler: Middleware): Unit {
        add(Some(HttpMethod.PATCH), path, handler, false)
    }
    public func head(path: String, handler: Middleware): Unit {
        add(Some(HttpMethod.HEAD), path, handler, false)
    }
    public func options(path: String, handler: Middleware): Unit {
        add(Some(HttpMethod.OPTIONS), path, handler, false)
    }
    public func all(path: String, handler: Middleware): Unit {
        add(Some(HttpMethod.ALL), path, handler, false)
    }

    // 终结式 Handler 形态(处理器签名里没有 `next`)。与 Application 上的同名重载
    // 对应，方便直接写「只产生响应、不再向后传递」的处理器。
    public func get(path: String, handler: Handler): Unit {
        add(Some(HttpMethod.GET), path, wrap(handler), false)
    }
    public func post(path: String, handler: Handler): Unit {
        add(Some(HttpMethod.POST), path, wrap(handler), false)
    }
    public func put(path: String, handler: Handler): Unit {
        add(Some(HttpMethod.PUT), path, wrap(handler), false)
    }
    public func delete(path: String, handler: Handler): Unit {
        add(Some(HttpMethod.DELETE), path, wrap(handler), false)
    }
    public func patch(path: String, handler: Handler): Unit {
        add(Some(HttpMethod.PATCH), path, wrap(handler), false)
    }
    public func head(path: String, handler: Handler): Unit {
        add(Some(HttpMethod.HEAD), path, wrap(handler), false)
    }
    public func options(path: String, handler: Handler): Unit {
        add(Some(HttpMethod.OPTIONS), path, wrap(handler), false)
    }
    public func all(path: String, handler: Handler): Unit {
        add(Some(HttpMethod.ALL), path, wrap(handler), false)
    }

    // 多处理器形态:一次给同一方法/路径挂多个中间件,按数组顺序依次执行(前者
    // 调用 next() 推进到后者)。常用于「前置校验 + 业务处理」这类组合。
    public func get(path: String, handlers: Array<Middleware>): Unit {
        addAll(Some(HttpMethod.GET), path, handlers, false)
    }
    public func post(path: String, handlers: Array<Middleware>): Unit {
        addAll(Some(HttpMethod.POST), path, handlers, false)
    }
    public func put(path: String, handlers: Array<Middleware>): Unit {
        addAll(Some(HttpMethod.PUT), path, handlers, false)
    }
    public func delete(path: String, handlers: Array<Middleware>): Unit {
        addAll(Some(HttpMethod.DELETE), path, handlers, false)
    }
    public func patch(path: String, handlers: Array<Middleware>): Unit {
        addAll(Some(HttpMethod.PATCH), path, handlers, false)
    }
    public func head(path: String, handlers: Array<Middleware>): Unit {
        addAll(Some(HttpMethod.HEAD), path, handlers, false)
    }
    public func options(path: String, handlers: Array<Middleware>): Unit {
        addAll(Some(HttpMethod.OPTIONS), path, handlers, false)
    }
    public func all(path: String, handlers: Array<Middleware>): Unit {
        addAll(Some(HttpMethod.ALL), path, handlers, false)
    }

    // 把一个子路由（Router）作为「迷你应用」挂载到 `path` 前缀下，对应 Express
    // 的 `router.use('/v1', subRouter)`。行为与 Application.use(path, sub) 一致：
    // 落在该前缀下的请求会被交给子路由，子路由先剥掉前缀再做自己的匹配。
    // 同时把挂载前缀记录到 sub.mountpath(对应 Express 的 router.mountpath)。
    public func use(path: String, sub: Router): Unit {
        // 先 ensureNotFrozen,再写 sub.mountpath。早先实现是先写 mountpath 再 add,而
        // add 才做冻结校验,导致 listen 后追加 use 会抛异常,但 sub 的 mountpath 已经被
        // 修改 — 部分状态变更下次重启会带着脏数据。现在校验前置,失败即原子失败。
        ensureNotFrozen()
        rejectOptionalInMountPath(path)
        sub.mountpath = path
        mountedSubRouters.add(sub)
        add(None, path, {
            req: HttpRequest, res: HttpResponse, next: Next => sub.handleAsMiddleware(req, res, next)
        }, true)
        // 把 prefix-mount layer 与子 router 关联,留待 hasMethodForPath 等查表时递归。
        mountedRouterByLayer[layers.size - 1] = sub
    }

    // 一次挂载多个全局/前缀中间件。
    public func use(handlers: Array<Middleware>): Unit {
        addAll(None, "/", handlers, true)
    }
    public func use(path: String, handlers: Array<Middleware>): Unit {
        rejectOptionalInMountPath(path)
        addAll(None, path, handlers, true)
    }

    // P1-5:mount 路径不支持可选参数段(":name?")。原因:可选段在 stripMountPath 中
    // 总是按 pattern.segments.size 剥前缀,实际是否消费一段未被传递,导致
    // `app.use("/api/:ver?", sub)` 请求 `/api/users` 时贪婪吞到 ver="users",sub 看到
    // 的是 `/`,与"用户意图 sub 看到 /users"不符。早注册时直接拒。
    func rejectOptionalInMountPath(path: String): Unit {
        let pattern = PathPattern.compile(path)
        for (seg in pattern.segments) {
            if (seg.optional) {
                throw Exception("wen: mount path 不支持可选参数段(':${seg.value}?'),与剥前缀语义有歧义")
            }
        }
    }

    private func wrap(handler: Handler): Middleware {
        return {req: HttpRequest, res: HttpResponse, _: Next => handler(req, res)}
    }

    // 注册一个错误处理中间件。它只在有异常正在链中传递时才会被调用;由于链是按
    // 注册顺序执行的，所以要把它注册在「希望被它捕获其错误的那些路由」之后。
    public func useError(handler: ErrorHandler): Unit {
        ensureNotFrozen()
        let idx = layers.size
        let layer = Layer(handler)
        layers.add(layer)
        indexLayer(layer, idx)
    }

    // 对一个请求运行整条中间件/路由链。若链跑完仍没有任何层产生响应，则按以下
    // 规则收尾:该路径压根没有任何路由 -> 返回 404;该路径在别的方法下存在、只是
    // 不支持当前方法 -> 返回 405(若是 OPTIONS 则返回 204)，并附上列出可用方法的
    // Allow 头。另外，若是 HEAD 请求但没有对应的 HEAD 路由，则回退去走 GET 路由，
    // 最终只回头部、不回正文。
    public func handle(req: HttpRequest, res: HttpResponse): Unit {
        // HEAD 兜底:无 HEAD 路由但有 GET 路由 → 临时改方法跑 GET,然后还原 method、抹掉 body。
        // 注:hasMethodForPath 是纯查表函数,但 cjlint 的 G.EXP.03 不允许在 && 短路右操作数
        // 里调函数(怕副作用),故把两次查表抽到局部变量再判断。
        let isHead = req.method == HttpMethod.HEAD
        let noHeadRoute = if (isHead) {
            !hasMethodForPath(HttpMethod.HEAD, req.path)
        } else {
            false
        }
        let hasGetRoute = if (noHeadRoute) {
            hasMethodForPath(HttpMethod.GET, req.path)
        } else {
            false
        }
        if (hasGetRoute) {
            req.method = HttpMethod.GET
            dispatchTop(req, res)
            req.method = HttpMethod.HEAD
            if (res.finished && !res.hijacked) {
                let len = match (res.bodyBytes) {
                    case Some(b) => b.size
                    case None => res.body.toArray().size
                }
                res.set("Content-Length", len.toString())
                res.body = ""
                res.bodyBytes = None
                res.suppressBody = true
            }
            return
        }
        dispatchTop(req, res)
    }

    private func dispatchTop(req: HttpRequest, res: HttpResponse): Unit {
        let onExhausted: Next = {
            => if (!res.finished) {
                // P0-3:HEAD 在兜底 404 / 405 路径上也必须 suppress body — HTTP 契约
                // 要求 HEAD 永不带正文。原 handle() 的 HEAD-strip 仅覆盖
                // `noHeadRoute && hasGetRoute` 分支;onExhausted 这条兜底路径之前漏了。
                if (req.method == HttpMethod.HEAD) {
                    res.suppressBody = true
                }
                let methods = methodsForPath(req.path)
                // P2-I:methodsForPath 现在跳过 ALL — 若此处 methods 空但路径上确实有
                // app.all(path, h) 注册,直觉是 405(路径存在,只是没匹配上具体方法),
                // 而非 404。hasAllRouteForPath 单独探测 ALL 标记。
                let hasAll = hasAllRouteForPath(req.path)
                if (methods.isEmpty() && !hasAll) {
                    res.status(404).send("Cannot ${req.method} ${req.path}")
                } else if (req.method == HttpMethod.OPTIONS) {
                    res.set("Allow", allowHeader(req.path)).status(204).end()
                } else {
                    res.set("Allow", allowHeader(req.path)).status(405).send("Method Not Allowed")
                }
            }
        }
        // 默认错误兜底:把异常映射为响应状态码。HttpException(及其子类,含框架内置的
        // PayloadTooLargeException=413 / BadRequestException=400)按其 status 回对应状态码、
        // 以 message 作响应体;其余未知异常按 500 兜底。与 server 层(read body 阶段)的
        // catch 行为一致。用户注册了错误处理中间件时,异常会先到那里,本兜底仅在所有错误
        // 中间件都未结束响应时触发。
        let onError: (Exception) -> Unit = {
            e: Exception => if (!res.finished) {
                try {
                    throw e
                } catch (he: HttpException) {
                    // 套上异常携带的响应头(P0-D):429 Retry-After / 401 WWW-Authenticate
                    // / 405 Allow / 503 Retry-After 等场景的标准做法。
                    for ((k, v) in he.headers) {
                        res.set(k, v)
                    }
                    res.status(he.status).send(he.message)
                } catch (_: Exception) {
                    res.status(500).send("Internal Server Error")
                }
            }
        }
        runChain(req, res, onExhausted, onError)
    }

    // 收集所有「路径能精确匹配该 path」的路由层上显式声明的、互不重复的方法名。
    // trie 圈候选 + matchExact 二次验证,O(M + K) 代替原来扫全部 layer。
    //
    // 还要合并所有挂载子路由的方法集 — 否则 `app.use("/api", sub)` + `sub.post(
    // "/items", h)` 场景下,顶级 router 看不到 sub 的 POST,onExhausted 走 404 而非
    // 405,Allow 头也漏 POST(违反 RFC 7231)。在每个 prefix-mount layer 上剥前缀
    // 后递归查 sub.methodsForPath,把结果并入 out。
    func methodsForPath(path: String): ArrayList<String> {
        let out = ArrayList<String>()
        let parts = pathSegments(path)
        let cands = collectTrieCandidates(routeTrie, parts)
        for (i in cands) {
            let layer = layers[i]
            // trie 只索引非中间件、非错误层,但保险起见仍判一次。
            if (layer.isError || layer.isPrefix) {
                continue
            }
            match (layer.method) {
                case Some(m) =>
                    if (m == HttpMethod.ALL) {
                        continue
                    }
                    match (layer.pattern.matchExact(path, caseSensitive: this.caseSensitive, strict: this.strict)) {
                        case Some(_) =>
                            if (!listContains(out, m)) {
                                out.add(m)
                            }
                        case None => ()
                    }
                case None => ()
            }
        }
        for ((idx, sub) in mountedRouterByLayer) {
            let layer = layers[idx]
            match (layer.pattern.matchPrefix(path, caseSensitive: this.caseSensitive)) {
                case Some(_) =>
                    let stripped = stripMountPath(path, layer.pattern.segments.size)
                    for (m in sub.methodsForPath(stripped)) {
                        if (!listContains(out, m)) {
                            out.add(m)
                        }
                    }
                case None => ()
            }
        }
        return out
    }

    // P2-I:路径上是否注册了 ALL 路由(用于 onExhausted 区分 404 vs 405)。
    // 同样要看挂载子路由内的 ALL 注册,否则 405/404 判定与方法表不一致。
    func hasAllRouteForPath(path: String): Bool {
        let parts = pathSegments(path)
        let cands = collectTrieCandidates(routeTrie, parts)
        for (i in cands) {
            let layer = layers[i]
            if (layer.isError || layer.isPrefix) {
                continue
            }
            match (layer.method) {
                case Some(m) =>
                    if (m == HttpMethod.ALL) {
                        match (layer.pattern.matchExact(path, caseSensitive: this.caseSensitive, strict: this.strict)) {
                            case Some(_) => return true
                            case None => ()
                        }
                    }
                case None => ()
            }
        }
        for ((idx, sub) in mountedRouterByLayer) {
            let layer = layers[idx]
            match (layer.pattern.matchPrefix(path, caseSensitive: this.caseSensitive)) {
                case Some(_) =>
                    let stripped = stripMountPath(path, layer.pattern.segments.size)
                    if (sub.hasAllRouteForPath(stripped)) {
                        return true
                    }
                case None => ()
            }
        }
        return false
    }

    // 路径上是否注册了指定 HTTP 方法。同上,要递归到挂载的子 router — 否则父级
    // HEAD-fallback("路径有 GET 路由即把 HEAD 切到 GET")完全看不到子路由内的
    // GET,SEO 爬虫 / CDN 预取 / 反代探活的 HEAD 请求在子路由场景下永远落到 404 /
    // 405,与 Express 行为(HEAD 自动覆盖任意层级 GET)不一致。
    func hasMethodForPath(method: String, path: String): Bool {
        let parts = pathSegments(path)
        let cands = collectTrieCandidates(routeTrie, parts)
        for (i in cands) {
            let layer = layers[i]
            if (layer.isError || layer.isPrefix) {
                continue
            }
            match (layer.method) {
                case Some(m) =>
                    if (m == method || m == HttpMethod.ALL) {
                        match (layer.pattern.matchExact(path, caseSensitive: this.caseSensitive, strict: this.strict)) {
                            case Some(_) => return true
                            case None => ()
                        }
                    }
                case None => ()
            }
        }
        for ((idx, sub) in mountedRouterByLayer) {
            let layer = layers[idx]
            match (layer.pattern.matchPrefix(path, caseSensitive: this.caseSensitive)) {
                case Some(_) =>
                    let stripped = stripMountPath(path, layer.pattern.segments.size)
                    if (sub.hasMethodForPath(method, stripped)) {
                        return true
                    }
                case None => ()
            }
        }
        return false
    }

    // 构造 Allow 头的值:在已注册的方法基础上，补上隐式支持的 OPTIONS;若注册了
    // GET 但没显式注册 HEAD，也补上 HEAD(因为 HEAD 会回退到 GET)。最后用 ", " 拼接。
    func allowHeader(path: String): String {
        let methods = methodsForPath(path)
        if (!listContains(methods, HttpMethod.OPTIONS)) {
            methods.add(HttpMethod.OPTIONS)
        }
        if (listContains(methods, HttpMethod.GET) && !listContains(methods, HttpMethod.HEAD)) {
            methods.add(HttpMethod.HEAD)
        }
        var s = ""
        var first = true
        for (m in methods) {
            if (first) {
                s += m
                first = false
            } else {
                s += ", " + m
            }
        }
        return s
    }

    // 把整个路由器当作一段挂载式中间件来运行(即所谓的「子应用 / mini-app」)。
    // 若内部没有任何层把响应处理完结，就调用 `next` 把控制权交还给父级链，让父链
    // 继续往下走;而内部未被捕获的错误则被重新抛出，交给父级的错误处理流水线去管。
    func handleAsMiddleware(req: HttpRequest, res: HttpResponse, next: Next): Unit {
        let onError: (Exception) -> Unit = {e: Exception => throw e}
        runChain(req, res, next, onError)
    }

    private func runChain(req: HttpRequest, res: HttpResponse, onExhausted: Next, onError: (Exception) -> Unit): Unit {
        // 用 trie 圈定精确路由候选,顺序扫前缀中间件,加入全部错误层(其执行由 dispatch
        // 阶段按 err 状态过滤)。三组 layer 索引合并、按注册顺序排序后进入 dispatch。
        // 方法检查仍推迟到 dispatch 阶段进行,以便 methodOverride 类中间件在链中改写
        // req.method 后,后续 layer 按新方法实时判定。
        let matchedIndices = collectMatchedLayerIndices(req)
        sortInt64Ascending(matchedIndices)
        let matched = ArrayList<Layer>()
        for (i in matchedIndices) {
            matched.add(layers[i])
        }
        dispatch(matched, 0, req, res, onExhausted, onError, None)
    }

    // 同时被 runChain / hasMethodForPath / methodsForPath 复用:返回该请求路径上「路径匹配」的
    // 所有 layer 索引(去重、未排序)。method 校验由调用方在拿到结果后自行处理。
    func collectMatchedLayerIndices(req: HttpRequest): ArrayList<Int64> {
        let out = ArrayList<Int64>()
        let seen = HashSet<Int64>()
        // 1. 前缀中间件:逐条做 prefix 匹配(数量通常远少于精确路由,顺序扫描可接受)。
        for (i in prefixLayerIndices) {
            let layer = layers[i]
            match (layer.pattern.matchPrefix(req.path, caseSensitive: this.caseSensitive)) {
                case Some(_) =>
                    if (!seen.contains(i)) {
                        seen.add(i)
                        out.add(i)
                    }
                case None => ()
            }
        }
        // 2. 精确路由:trie 圈候选,二次用 matchExact 验证(caseSensitive/strict/正则约束都在这里生效)。
        let parts = pathSegments(req.path)
        let cands = collectTrieCandidates(routeTrie, parts)
        for (i in cands) {
            let layer = layers[i]
            match (layer.pattern.matchExact(req.path, caseSensitive: this.caseSensitive, strict: this.strict)) {
                case Some(_) =>
                    if (!seen.contains(i)) {
                        seen.add(i)
                        out.add(i)
                    }
                case None => ()
            }
        }
        // 3. 错误层:与路径无关,全部加入;dispatch 在 err 状态下才会执行它们。
        for (i in errorLayerIndices) {
            if (!seen.contains(i)) {
                seen.add(i)
                out.add(i)
            }
        }
        return out
    }

    // 升序排序一个 Int64 列表(用于把三档索引合并后还原为 layer 注册顺序)。简单插入排序:
    // matched 列表通常 < 20 条,与 O(N log N) 的快排相比常数更小、代码更稳。
    func sortInt64Ascending(list: ArrayList<Int64>): Unit {
        var i = 1
        while (i < list.size) {
            let cur = list[i]
            var j = i - 1
            while (j >= 0 && list[j] > cur) {
                list[j + 1] = list[j]
                j -= 1
            }
            list[j + 1] = cur
            i += 1
        }
    }

    func dispatch(matched: ArrayList<Layer>, index: Int64, req: HttpRequest, res: HttpResponse, onExhausted: Next,
        onError: (Exception) -> Unit, err: ?Exception): Unit {
        if (res.finished) {
            return
        }
        if (index >= matched.size) {
            match (err) {
                case Some(e) => onError(e)
                case None => onExhausted()
            }
            return
        }
        let layer = matched[index]
        match (err) {
            case Some(e) =>
                // 错误模式:链中正携带着一个异常。此时跳过所有普通层，只让错误处理层运行。
                if (!layer.isError) {
                    dispatch(matched, index + 1, req, res, onExhausted, onError, err)
                    return
                }
                let next: Next = {=> dispatch(matched, index + 1, req, res, onExhausted, onError, Some(e))}
                try {
                    match (layer.errorHandler) {
                        case Some(h) => h(e, req, res, next)
                        case None => next()
                    }
                } catch (e2: Exception) {
                    dispatch(matched, index + 1, req, res, onExhausted, onError, Some(e2))
                }
            case None =>
                // 正常模式:链中没有错误。此时跳过所有错误处理层，只让普通层运行。
                if (layer.isError) {
                    dispatch(matched, index + 1, req, res, onExhausted, onError, None)
                    return
                }
                // 实时方法检查:layer 路径已在 runChain 预筛通过,这里再验证方法
                // 是否与当前 req.method 相容,以兼容 methodOverride 这类中间件
                // 链中改写 method 的场景。
                if (!layer.methodMatches(req.method)) {
                    dispatch(matched, index + 1, req, res, onExhausted, onError, None)
                    return
                }
                runNormal(matched, index, layer, req, res, onExhausted, onError)
        }
    }

    private func runNormal(matched: ArrayList<Layer>, index: Int64, layer: Layer, req: HttpRequest, res: HttpResponse,
        onExhausted: Next, onError: (Exception) -> Unit): Unit {
        // 重新运行本层的匹配以取回它捕获的参数并写入 req.params。之所以要在此重新
        // 匹配，是因为不同的层可能捕获不同的参数名/值，需在执行该层处理器前对齐。
        // 这里只重做路径匹配:方法检查已在 dispatch 阶段实时完成。
        // P2-H 设计取舍:wen 默认 mergeParams=true(父级 prefix 捕获的 params 沿用到
        // 子层)。这意味着 `/x/:userId` 中间件 + `/x/:account` 路由场景下,handler 内
        // req.params 同时含两个名 — 与 Express mergeParams: true 一致。要"只看当前 layer
        // 的 params",应在 handler 内显式只读 req.param("account")。
        var captured = HashMap<String, String>()
        match (layer.tryMatchPath(req, this.caseSensitive, this.strict)) {
            case Some(params) =>
                captured = params
                for ((k, v) in params) {
                    req.params[k] = v
                }
            case None => ()
        }
        // 参数预处理回调(app.param):对本层新捕获、注册了回调、且本请求尚未处理过的
        // 参数依次触发。回调抛异常则转入错误流水线;直接结束响应则就此短路。
        // P2-G:同名 param 注册多个时,按注册顺序逐个跑。
        if (paramCallbacks.size > 0) {
            for ((k, v) in captured) {
                if (req.paramProcessed(k)) {
                    continue
                }
                match (paramCallbacks.get(k)) {
                    case Some(handlers) =>
                        req.markParamProcessed(k)
                        for (cb in handlers) {
                            try {
                                cb(req, res, v)
                            } catch (ex: Exception) {
                                dispatch(matched, index + 1, req, res, onExhausted, onError, Some(ex))
                                return
                            }
                            if (res.finished) {
                                return
                            }
                        }
                    case None => ()
                }
            }
        }
        // 处理 next("route"):跳过与本层 routeId 相同的后续层(即本条路由的其余
        // 处理器),从下一条不同的路由继续。
        let skipRoute: Next = {
            =>
                var j = index + 1
                while (j < matched.size && matched[j].routeId == layer.routeId) {
                    j += 1
                }
                dispatch(matched, j, req, res, onExhausted, onError, None)
        }
        // 挂载式中间件(use(path, mw))在执行时，看到的 req.path 是「已剥掉挂载前缀」
        // 的相对路径，这与 Express 的行为一致。这里先保存原始路径并临时替换为剥掉前缀
        // 后的路径供该处理器使用;待轮到链的后续部分运行时，会先把原始路径还原回去，
        // 从而保证下游路由仍按完整路径来匹配。
        // 同时维护 req.baseUrl：在子路由处理期间将其设为挂载前缀，以便子路由内的
        // 处理器能获知自己是在哪个路径前缀下运行的(对应 Express 的 req.baseUrl)。
        // next 幂等保护:同一个 layer 的 next 被多次调用时,只第一次推进链,后续静默忽略。
        // 早先 next 是裸闭包,中间件错误地调两次会让后续 layer 跑两遍,触发 param
        // callback 重复触发、状态错乱。
        let nextCalled = AtomicBool(false)
        if (layer.isPrefix && layer.pattern.segments.size > 0) {
            let savedPath = req.path
            let savedBaseUrl = req.baseUrl
            let mountPrefix = buildMountPrefix(req.path, layer.pattern.segments.size)
            req.path = stripMountPath(req.path, layer.pattern.segments.size)
            req.baseUrl = savedBaseUrl + mountPrefix
            let next: Next = {
                => if (nextCalled.compareAndSwap(false, true)) {
                    req.path = savedPath
                    req.baseUrl = savedBaseUrl
                    dispatch(matched, index + 1, req, res, onExhausted, onError, None)
                }
            }
            try {
                layer.handler(req, res, next)
            } catch (ex: Exception) {
                req.path = savedPath
                req.baseUrl = savedBaseUrl
                // P1-6:无论 nextCalled 是 false 还是 true,异常都必须进流水线 — 早先
                // CAS 失败(handler 先 next() 再 throw)时直接 return → 异常静默丢弃。
                // 改:把异常 dispatch 给后续层(err 状态会跳过普通 layer,直达 error layer)。
                // CAS 仍尝试推进,避免子链不被重复进入。
                nextCalled.compareAndSwap(false, true)
                dispatch(matched, index + 1, req, res, onExhausted, onError, Some(ex))
                return
            }
            req.path = savedPath
            req.baseUrl = savedBaseUrl
            if (req.consumeSkipRoute()) {
                skipRoute()
            }
        } else {
            let next: Next = {
                => if (nextCalled.compareAndSwap(false, true)) {
                    dispatch(matched, index + 1, req, res, onExhausted, onError, None)
                }
            }
            try {
                layer.handler(req, res, next)
            } catch (ex: Exception) {
                // P1-6:同上 — 无论 CAS 成功与否,都让异常进流水线给 error layer。
                nextCalled.compareAndSwap(false, true)
                dispatch(matched, index + 1, req, res, onExhausted, onError, Some(ex))
                return
            }
            if (req.consumeSkipRoute()) {
                skipRoute()
            }
        }
    }

    // 丢弃路径开头的前 `mountSegments` 个段，再把剩余的段重新拼成路径，
    // 例如 stripMountPath("/static/css/app.css", 1) -> "/css/app.css"。
    // 若剩余段不足(全被剥光)，则返回根路径 "/"。
    // P1-7:保留原路径的尾斜杠 — 否则 sub 永远看不到 `/foo/`,只能看到 `/foo`,
    // 子路由 strict routing 形同失效。
    func stripMountPath(path: String, mountSegments: Int64): String {
        let parts = pathSegments(path)
        if (parts.size <= mountSegments) {
            return "/"
        }
        var rebuilt = ""
        var i = mountSegments
        while (i < parts.size) {
            rebuilt += "/" + parts[i]
            i += 1
        }
        if (path.endsWith("/") && !rebuilt.endsWith("/")) {
            rebuilt += "/"
        }
        return rebuilt
    }

    // 从路径中取出前 `mountSegments` 个段并重新拼成路径前缀字符串，用于构建 baseUrl。
    // 例如 buildMountPrefix("/api/users/1", 1) -> "/api"
    //        buildMountPrefix("/api/users/1", 2) -> "/api/users"
    // 若段数不足则返回路径本身。
    func buildMountPrefix(path: String, mountSegments: Int64): String {
        let parts = pathSegments(path)
        let take = if (mountSegments < parts.size) {
            mountSegments
        } else {
            parts.size
        }
        var prefix = ""
        var i = Int64(0)
        while (i < take) {
            prefix += "/" + parts[i]
            i += 1
        }
        return prefix
    }
}
