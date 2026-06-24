package wen_contrib

import wen.*
/*
 * 方法重写(method override)中间件 —— 对应 Express 的 method-override。
 *
 * 用途:HTML 表单只能发 GET / POST,无法直接发 PUT / DELETE / PATCH。本中间件让表单
 * (或网关 / 客户端)借助一个「重写来源」把请求方法改写成目标动词,从而复用同一套
 * RESTful 路由。
 *
 * 安全约束(与 Express 一致):
 *   - **仅当原始方法为 POST 时**才允许重写 —— GET 等安全方法不应被悄悄改成有副作用的
 *     动词(否则 <img src> 之类也能触发删除);
 *   - 目标必须是「已知 HTTP 方法」,否则忽略。
 * 重写发生时,原始方法会存入 req.attribute("originalMethod") 备查。
 *
 * 两个工厂:
 *   - methodOverride(headerName)  从请求头读取(默认 X-HTTP-Method-Override),适合 AJAX / 网关。
 *   - methodOverrideField(field)  从表单字段或查询串读取(默认 _method),适合 HTML 表单隐藏字段。
 *
 * 两者都应在「路由注册之前」用 app.use(...) 挂为全局中间件,这样路由匹配时看到的已是
 * 重写后的方法。
 */

// 从请求头读取重写方法(默认 X-HTTP-Method-Override)。头值含多个时取逗号前的第一个。
public func methodOverride(headerName!: String = "X-HTTP-Method-Override"): Middleware {
    return {
        req: HttpRequest, _: HttpResponse, next: Next =>
            if (req.method == HttpMethod.POST) {
                match (req.header(headerName)) {
                    case Some(v) =>
                        let (first, _) = splitOnce(v, ",")
                        applyMethodOverride(req, first)
                    case None => ()
                }
            }
            next()
    }
}

// 从表单字段(x-www-form-urlencoded / multipart)或查询串读取重写方法(默认 _method)。
// 表单字段优先,其次查询串;读取表单字段会按需触发请求体解析。
public func methodOverrideField(field!: String = "_method"): Middleware {
    return {
        req: HttpRequest, _: HttpResponse, next: Next =>
            if (req.method == HttpMethod.POST) {
                let raw = match (req.attribute(field)) {
                    case Some(v) => Some(v)
                    case None => req.queryParam(field)
                }
                match (raw) {
                    case Some(v) => applyMethodOverride(req, v)
                    case None => ()
                }
            }
            next()
    }
}

// 把候选字符串归一为大写方法名;若是合法的"重写目标"(非安全方法),则记下原
// 方法并改写 req.method。其余一律忽略(保持原方法不变)。
func applyMethodOverride(req: HttpRequest, candidate: String): Unit {
    let m = candidate.trimAscii().toAsciiUpper()
    if (isOverrideTarget(m)) {
        req.attributes["originalMethod"] = req.method
        req.method = m
    }
}

// 是否为合法的方法重写目标。**只允许非安全方法(PUT / DELETE / PATCH)**,这与
// Express 5 的 method-override 默认行为一致 — POST → 任意安全方法(GET / HEAD /
// OPTIONS)的改写会让 csrf 中间件(基于"GET 是安全方法"放行)整段绕过校验,本是
// 中间件之间的耦合面。把目标动词限制在非安全方法能从源头切断这条耦合,需要其他
// 动词的场景由调用方在外层显式判定 — 框架不替业务决定"改成 GET 是否安全"。
func isOverrideTarget(m: String): Bool {
    match (m) {
        case "PUT" | "DELETE" | "PATCH" => return true
        case _ => return false
    }
}
