package wen


/*
 * 请求体解析中间件工厂。
 *
 * 这些工厂根据请求的 Content-Type 判断请求体的格式，并把原始的 `body`
 * 字符串解码成下游中间件/处理器能够直接使用的形式。
 *
 * 关于 JSON 的处理：jsonParser 会把原始文本解析为 JsonValue，同时也把原始
 * 字符串本身保留在属性里，供需要直接拿到原文的调用方使用。url-encoded 表单
 * 则会被拆散，逐个字段写入请求属性。
 *
 * 设计要点：无论是否成功解析、是否命中目标 Content-Type，两个中间件都一定
 * 会调用 next() 继续推进中间件链——它们只负责“解码并附加数据”，绝不在
 * 这里中断请求，是否因数据缺失/非法而拒绝请求交由业务处理器自行决定。
 */

// 解析 application/x-www-form-urlencoded 类型的表单请求体，把表单里的每个
// 字段都作为请求属性（attribute）暴露给下游使用。
// 若请求的 Content-Type 不是该类型，则原样放行、不做任何处理。
public func urlencodedParser(): Middleware {
    return { req: HttpRequest, _: HttpResponse, next: Next =>
        // header() 返回 Option：只有当 Content-Type 头存在、且确实匹配目标
        // 类型时才进行解析；否则什么都不做。
        match (req.header("content-type")) {
            case Some(ct) =>
                if (ct.contains("application/x-www-form-urlencoded")) {
                    parseQuery(req.body, req.attributes)
                }
            case None => ()
        }
        next()
    }
}

// 把 application/json 类型的请求体解析成 JsonValue，可通过 `req.json()` 取用。
// 同时把原始文本字符串保存在名为 "json" 的属性中，方便需要拿到原文（而非
// 解析后结构）的调用方。
// 容错策略：当请求体格式非法（解析抛出 JsonException）时，仅吞掉异常、保持
// req.json() 为 None，而**不**让整个请求失败。这样中间件本身永远不会因为
// 用户传了坏数据而崩溃；如需严格校验，请在自己的处理器里判断 req.json()
// 是否为 None 并据此返回 400 等错误。
// 另外，空请求体会被直接跳过（不写属性、不解析）。
public func jsonParser(): Middleware {
    return { req: HttpRequest, _: HttpResponse, next: Next =>
        match (req.header("content-type")) {
            case Some(ct) =>
                if (ct.contains("application/json") && !req.body.isEmpty()) {
                    req.setAttribute("json", req.body)
                    try {
                        req.jsonBody = Some(parseJson(req.body))
                    } catch (_: JsonException) {
                        ()
                    }
                }
            case None => ()
        }
        next()
    }
}
