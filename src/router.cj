package wen

import std.collection.*
import std.regex.*

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
    let value: String           // 对字面量段是其文本内容；对参数段是参数名
    let constraint: ?Regex      // 仅参数段可能用到：一个已加锚定的可选正则约束
    let optional: Bool          // 仅参数段可能用到：该段是否可缺省（":name?" 写法）

    init(kind: SegKind, value: String) {
        this.kind = kind
        this.value = value
        this.constraint = None
        this.optional = false
    }

    init(kind: SegKind, value: String, constraint: ?Regex) {
        this.kind = kind
        this.value = value
        this.constraint = constraint
        this.optional = false
    }

    init(kind: SegKind, value: String, constraint: ?Regex, optional: Bool) {
        this.kind = kind
        this.value = value
        this.constraint = constraint
        this.optional = optional
    }
}

public class PathPattern {
    let segments: ArrayList<Segment>
    let hasWildcard: Bool

    init(segments: ArrayList<Segment>, hasWildcard: Bool) {
        this.segments = segments
        this.hasWildcard = hasWildcard
    }

    public static func compile(path: String): PathPattern {
        let segs = ArrayList<Segment>()
        var wildcard = false
        for (raw in pathSegments(path)) {
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
                            let pat = spec[(p + 1)..(spec.size - 1)]
                            segs.add(Segment(Param, name, Some(Regex("^(?:" + pat + ")$")), optional))
                        } else {
                            segs.add(Segment(Param, spec, None, optional))
                        }
                    case None =>
                        segs.add(Segment(Param, spec, None, optional))
                }
            } else {
                segs.add(Segment(Literal, raw))
            }
        }
        return PathPattern(segs, wildcard)
    }

    // 精确匹配。匹配成功时返回捕获到的参数表(键为参数名)，失败时返回 None。
    public func matchExact(path: String): ?HashMap<String, String> {
        return doMatch(pathSegments(path), false)
    }

    // 前缀匹配，供挂载式中间件使用(只要求模式是请求路径的前缀)。
    public func matchPrefix(path: String): ?HashMap<String, String> {
        return doMatch(pathSegments(path), true)
    }

    private func doMatch(parts: Array<String>, prefix: Bool): ?HashMap<String, String> {
        let params = HashMap<String, String>()
        if (matchFrom(0, parts, 0, prefix, params)) {
            return params
        }
        return None
    }

    // 回溯式匹配:尝试让模式从第 si 段、请求路径从第 pi 段起对齐。成功返回 true，
    // 并把沿途捕获的参数写入 params;失败返回 false。
    // 之所以用回溯而非简单的线性扫描，是为了正确处理可缺省参数(":name?"):碰到
    // 可缺省段时，先试「消费一段」，若后续匹配不下去再回退试「跳过该段」。
    private func matchFrom(si: Int64, parts: Array<String>, pi: Int64, prefix: Bool,
                          params: HashMap<String, String>): Bool {
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
                        if (matchFrom(si + 1, parts, pi + 1, prefix, params)) {
                            return true
                        }
                        // 走不通则回退:撤销本段的捕获，改为「跳过该可缺省段」。
                        params.remove(seg.value)
                    }
                    return matchFrom(si + 1, parts, pi, prefix, params)
                }
                if (pi >= parts.size) {
                    return false
                }
                if (!constraintOk(seg, parts[pi])) {
                    return false
                }
                // 捕获到的参数值会做 URL 解码(例如 "john%20doe" -> "john doe")。
                params[seg.value] = urlDecode(parts[pi])
                return matchFrom(si + 1, parts, pi + 1, prefix, params)
            case Literal =>
                if (pi >= parts.size) {
                    return false
                }
                if (seg.value != parts[pi]) {
                    return false
                }
                return matchFrom(si + 1, parts, pi + 1, prefix, params)
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
    let method: ?String        // None 表示不限方法，任意请求方法都匹配
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
        this.handler = { _: HttpRequest, _: HttpResponse, _: Next => () }
        this.isPrefix = false
        this.isError = true
        this.errorHandler = Some(errorHandler)
        this.routeId = 0
    }

    // 判断本层是否匹配该请求:匹配则返回捕获到的参数表，否则返回 None。
    func tryMatch(req: HttpRequest): ?HashMap<String, String> {
        if (this.isError) {
            // 错误处理层不看方法、也不看路径，一律视为匹配(返回空参数表);
            // 它到底跑不跑、何时跑，完全由 dispatch 根据是否处于错误模式决定。
            return Some(HashMap<String, String>())
        }
        // 方法过滤:若本层限定了方法且既不是 ALL(通配方法)、又与请求方法不同，
        // 则直接判定不匹配。method 为 None 表示不限方法，跳过此过滤。
        match (this.method) {
            case Some(m) =>
                if (m != HttpMethod.ALL && m != req.method) {
                    return None
                }
            case None => ()
        }
        // 路径匹配方式取决于本层是不是挂载式中间件:挂载式用前缀匹配，
        // 普通路由用精确匹配。
        if (this.isPrefix) {
            return this.pattern.matchPrefix(req.path)
        }
        return this.pattern.matchExact(req.path)
    }
}

public class Router {
    let layers: ArrayList<Layer> = ArrayList<Layer>()
    // 已注册路由数的递增计数器,用于给每次注册分配唯一的 routeId(多处理器路由
    // 的各处理器共享同一个 id)。
    var routeCounter: Int64 = 0
    // app.param 注册的参数预处理回调表,键为参数名。
    let paramCallbacks: HashMap<String, ParamHandler> = HashMap<String, ParamHandler>()

    public init() {}

    func freshRouteId(): Int64 {
        routeCounter += 1
        return routeCounter
    }

    func add(method: ?String, path: String, handler: Middleware, isPrefix: Bool): Unit {
        layers.add(Layer(method, path, handler, isPrefix, freshRouteId()))
    }

    // 一次注册多个处理器到同一方法/路径:它们按顺序排成相邻的多个 Layer，共享同一个
    // routeId。前一个处理器调用 next() 即推进到下一个;调用 req.nextRoute() 则跳过
    // 本组剩余处理器,直达下一条路由。
    func addAll(method: ?String, path: String, handlers: Array<Middleware>, isPrefix: Bool): Unit {
        let id = freshRouteId()
        for (h in handlers) {
            layers.add(Layer(method, path, h, isPrefix, id))
        }
    }

    // 注册一个参数预处理回调(对应 Express 的 app.param)。当匹配到的路由捕获了名为
    // `name` 的参数时,会在该路由处理器执行前触发此回调(每个请求每个参数名只触发一次)。
    public func param(name: String, handler: ParamHandler): Unit {
        paramCallbacks[name] = handler
    }

    // 全局中间件:对每个请求都执行。以根路径 "/" 作前缀注册，前缀匹配下它能
    // 命中任意路径，因此等价于「对所有请求生效」。
    public func use(handler: Middleware): Unit {
        add(None, "/", handler, true)
    }

    // 挂载式中间件:只对路径处于 `path` 之下(以 path 为前缀)的请求执行。
    public func use(path: String, handler: Middleware): Unit {
        add(None, path, handler, true)
    }

    public func get(path: String, handler: Middleware): Unit { add(Some(HttpMethod.GET), path, handler, false) }
    public func post(path: String, handler: Middleware): Unit { add(Some(HttpMethod.POST), path, handler, false) }
    public func put(path: String, handler: Middleware): Unit { add(Some(HttpMethod.PUT), path, handler, false) }
    public func delete(path: String, handler: Middleware): Unit { add(Some(HttpMethod.DELETE), path, handler, false) }
    public func patch(path: String, handler: Middleware): Unit { add(Some(HttpMethod.PATCH), path, handler, false) }
    public func head(path: String, handler: Middleware): Unit { add(Some(HttpMethod.HEAD), path, handler, false) }
    public func options(path: String, handler: Middleware): Unit { add(Some(HttpMethod.OPTIONS), path, handler, false) }
    public func all(path: String, handler: Middleware): Unit { add(Some(HttpMethod.ALL), path, handler, false) }

    // 终结式 Handler 形态(处理器签名里没有 `next`)。与 Application 上的同名重载
    // 对应，方便直接写「只产生响应、不再向后传递」的处理器。
    public func get(path: String, handler: Handler): Unit { add(Some(HttpMethod.GET), path, wrap(handler), false) }
    public func post(path: String, handler: Handler): Unit { add(Some(HttpMethod.POST), path, wrap(handler), false) }
    public func put(path: String, handler: Handler): Unit { add(Some(HttpMethod.PUT), path, wrap(handler), false) }
    public func delete(path: String, handler: Handler): Unit { add(Some(HttpMethod.DELETE), path, wrap(handler), false) }
    public func patch(path: String, handler: Handler): Unit { add(Some(HttpMethod.PATCH), path, wrap(handler), false) }
    public func head(path: String, handler: Handler): Unit { add(Some(HttpMethod.HEAD), path, wrap(handler), false) }
    public func options(path: String, handler: Handler): Unit { add(Some(HttpMethod.OPTIONS), path, wrap(handler), false) }
    public func all(path: String, handler: Handler): Unit { add(Some(HttpMethod.ALL), path, wrap(handler), false) }

    // 多处理器形态:一次给同一方法/路径挂多个中间件,按数组顺序依次执行(前者
    // 调用 next() 推进到后者)。常用于「前置校验 + 业务处理」这类组合。
    public func get(path: String, handlers: Array<Middleware>): Unit { addAll(Some(HttpMethod.GET), path, handlers, false) }
    public func post(path: String, handlers: Array<Middleware>): Unit { addAll(Some(HttpMethod.POST), path, handlers, false) }
    public func put(path: String, handlers: Array<Middleware>): Unit { addAll(Some(HttpMethod.PUT), path, handlers, false) }
    public func delete(path: String, handlers: Array<Middleware>): Unit { addAll(Some(HttpMethod.DELETE), path, handlers, false) }
    public func patch(path: String, handlers: Array<Middleware>): Unit { addAll(Some(HttpMethod.PATCH), path, handlers, false) }
    public func head(path: String, handlers: Array<Middleware>): Unit { addAll(Some(HttpMethod.HEAD), path, handlers, false) }
    public func options(path: String, handlers: Array<Middleware>): Unit { addAll(Some(HttpMethod.OPTIONS), path, handlers, false) }
    public func all(path: String, handlers: Array<Middleware>): Unit { addAll(Some(HttpMethod.ALL), path, handlers, false) }

    // 一次挂载多个全局/前缀中间件。
    public func use(handlers: Array<Middleware>): Unit { addAll(None, "/", handlers, true) }
    public func use(path: String, handlers: Array<Middleware>): Unit { addAll(None, path, handlers, true) }

    private func wrap(handler: Handler): Middleware {
        return { req: HttpRequest, res: HttpResponse, _: Next => handler(req, res) }
    }

    // 注册一个错误处理中间件。它只在有异常正在链中传递时才会被调用;由于链是按
    // 注册顺序执行的，所以要把它注册在「希望被它捕获其错误的那些路由」之后。
    public func useError(handler: ErrorHandler): Unit {
        layers.add(Layer(handler))
    }

    // 对一个请求运行整条中间件/路由链。若链跑完仍没有任何层产生响应，则按以下
    // 规则收尾:该路径压根没有任何路由 -> 返回 404;该路径在别的方法下存在、只是
    // 不支持当前方法 -> 返回 405(若是 OPTIONS 则返回 204)，并附上列出可用方法的
    // Allow 头。另外，若是 HEAD 请求但没有对应的 HEAD 路由，则回退去走 GET 路由，
    // 最终只回头部、不回正文。
    public func handle(req: HttpRequest, res: HttpResponse): Unit {
        if (req.method == HttpMethod.HEAD && !hasMethodForPath(HttpMethod.HEAD, req.path) &&
            hasMethodForPath(HttpMethod.GET, req.path)) {
            req.method = HttpMethod.GET
            dispatchTop(req, res)
            req.method = HttpMethod.HEAD
            if (res.finished && !res.hijacked) {
                let len = match (res.bodyBytes) {
                    case Some(b) => b.size
                    case None => res.body.toArray().size
                }
                res.headers["Content-Length"] = len.toString()
                res.body = ""
                res.bodyBytes = None
                res.suppressBody = true
            }
            return
        }
        dispatchTop(req, res)
    }

    private func dispatchTop(req: HttpRequest, res: HttpResponse): Unit {
        let onExhausted: Next = { =>
            if (!res.finished) {
                let methods = methodsForPath(req.path)
                if (methods.isEmpty()) {
                    res.status(404).send("Cannot ${req.method} ${req.path}")
                } else if (req.method == HttpMethod.OPTIONS) {
                    res.set("Allow", allowHeader(req.path)).status(204).end()
                } else {
                    res.set("Allow", allowHeader(req.path)).status(405).send("Method Not Allowed")
                }
            }
        }
        let onError: (Exception) -> Unit = { _: Exception =>
            if (!res.finished) {
                res.status(500).send("Internal Server Error")
            }
        }
        runChain(req, res, onExhausted, onError)
    }

    // 收集所有「路径能精确匹配该 path」的路由层上显式声明的、互不重复的方法名。
    // 会跳过中间件层、错误处理层，以及方法为通配的 `all` 路由(它们不算某个具体方法)。
    func methodsForPath(path: String): ArrayList<String> {
        let out = ArrayList<String>()
        for (layer in layers) {
            if (layer.isError || layer.isPrefix) {
                continue
            }
            match (layer.method) {
                case Some(m) =>
                    if (m == HttpMethod.ALL) {
                        continue
                    }
                    match (layer.pattern.matchExact(path)) {
                        case Some(_) =>
                            if (!listContains(out, m)) {
                                out.add(m)
                            }
                        case None => ()
                    }
                case None => ()
            }
        }
        return out
    }

    func hasMethodForPath(method: String, path: String): Bool {
        for (layer in layers) {
            if (layer.isError || layer.isPrefix) {
                continue
            }
            match (layer.method) {
                case Some(m) =>
                    if (m == method || m == HttpMethod.ALL) {
                        match (layer.pattern.matchExact(path)) {
                            case Some(_) => return true
                            case None => ()
                        }
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
        let onError: (Exception) -> Unit = { e: Exception => throw e }
        runChain(req, res, next, onError)
    }

    private func runChain(req: HttpRequest, res: HttpResponse, onExhausted: Next, onError: (Exception) -> Unit): Unit {
        let matched = ArrayList<Layer>()
        for (layer in layers) {
            match (layer.tryMatch(req)) {
                case Some(_) => matched.add(layer)
                case None => ()
            }
        }
        dispatch(matched, 0, req, res, onExhausted, onError, None)
    }

    func dispatch(matched: ArrayList<Layer>, index: Int64, req: HttpRequest, res: HttpResponse,
                  onExhausted: Next, onError: (Exception) -> Unit, err: ?Exception): Unit {
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
                let next: Next = { => dispatch(matched, index + 1, req, res, onExhausted, onError, Some(e)) }
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
                runNormal(matched, index, layer, req, res, onExhausted, onError)
        }
    }

    private func runNormal(matched: ArrayList<Layer>, index: Int64, layer: Layer, req: HttpRequest, res: HttpResponse,
                           onExhausted: Next, onError: (Exception) -> Unit): Unit {
        // 重新运行本层的匹配以取回它捕获的参数并写入 req.params。之所以要在此重新
        // 匹配，是因为不同的层可能捕获不同的参数名/值，需在执行该层处理器前对齐。
        var captured = HashMap<String, String>()
        match (layer.tryMatch(req)) {
            case Some(params) =>
                captured = params
                for ((k, v) in params) {
                    req.params[k] = v
                }
            case None => ()
        }
        // 参数预处理回调(app.param):对本层新捕获、注册了回调、且本请求尚未处理过的
        // 参数依次触发。回调抛异常则转入错误流水线;直接结束响应则就此短路。
        if (paramCallbacks.size > 0) {
            for ((k, v) in captured) {
                if (req.paramProcessed(k)) {
                    continue
                }
                match (paramCallbacks.get(k)) {
                    case Some(cb) =>
                        req.markParamProcessed(k)
                        try {
                            cb(req, res, v)
                        } catch (ex: Exception) {
                            dispatch(matched, index + 1, req, res, onExhausted, onError, Some(ex))
                            return
                        }
                        if (res.finished) {
                            return
                        }
                    case None => ()
                }
            }
        }
        // 处理 next("route"):跳过与本层 routeId 相同的后续层(即本条路由的其余
        // 处理器),从下一条不同的路由继续。
        let skipRoute: Next = { =>
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
        if (layer.isPrefix && layer.pattern.segments.size > 0) {
            let savedPath = req.path
            req.path = stripMountPath(req.path, layer.pattern.segments.size)
            let next: Next = { =>
                req.path = savedPath
                dispatch(matched, index + 1, req, res, onExhausted, onError, None)
            }
            try {
                layer.handler(req, res, next)
            } catch (ex: Exception) {
                req.path = savedPath
                dispatch(matched, index + 1, req, res, onExhausted, onError, Some(ex))
                return
            }
            req.path = savedPath
            if (req.consumeSkipRoute()) {
                skipRoute()
            }
        } else {
            let next: Next = { => dispatch(matched, index + 1, req, res, onExhausted, onError, None) }
            try {
                layer.handler(req, res, next)
            } catch (ex: Exception) {
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
        return rebuilt
    }
}
