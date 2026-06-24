package wen

/*
 * 请求体解析中间件工厂。
 *
 * 重要变化:application/json、x-www-form-urlencoded、multipart/form-data 的解析现在是
 * **内置**的——首次通过 req.json() / req.attribute() / req.file() 等访问器读取时,框架按
 * Content-Type 自动解析一次(见 HttpRequest.ensureBody)。因此 jsonParser() / urlencodedParser()
 * 已**非必需**:保留它们只是为了「提前解析」或在中间件链里显式表达意图,内部都只是调用
 * req.ensureBody()。textParser / rawParser 处理的是非默认类型(纯文本 / 原始字节),仍是真正
 * 需显式注册的中间件。
 */

/**
 * (兼容保留)`application/x-www-form-urlencoded` 表单解析中间件。
 *
 * 解析已内置,本中间件仅提前触发 `req.ensureBody()`;url-encoded 字段经
 * `req.attribute(name)` 读取。
 */
public func urlencodedParser(): Middleware {
    return {
        req: HttpRequest, _: HttpResponse, next: Next =>
            req.ensureBody()
            next()
    }
}

/**
 * (兼容保留)JSON 解析中间件。
 *
 * 解析已内置,本中间件仅提前触发 `req.ensureBody()`;解析结果经 `req.json()` 读取
 * (空体 / 非法 JSON 时默认为 None,不会让请求失败)。
 *
 * **strict 模式**:当 `strict=true`、Content-Type 主类型为 `application/json`、且
 * 请求体非空、但解析结果仍为 None(JSON 语法错误)时,立刻抛 [[BadRequestException]]
 * (框架默认回 400)。路由处理器若忘记检查 `req.json()` 的 None 状态,这能避免畸形
 * JSON 绕过依赖请求体内容的业务校验,造成意料外的行为。默认 false 保持向后兼容。
 */
public func jsonParser(strict!: Bool = false): Middleware {
    return {
        req: HttpRequest, _: HttpResponse, next: Next =>
            req.ensureBody()
            if (strict) {
                match (req.header("content-type")) {
                    case Some(ct) =>
                        if (isJsonContentType(primaryContentType(ct)) && !req.body.isEmpty()) {
                            match (req.jsonBody) {
                                case None => throw BadRequestException()
                                case Some(_) => ()
                            }
                        }
                    case None => ()
                }
            }
            next()
    }
}

/**
 * 以纯文本方式处理请求体的中间件,对应 Express 的 `express.text()`。
 *
 * 当请求 Content-Type 匹配 `contentType`(默认 `"text/plain"`;大小写无关的子串匹配)
 * 时,把文本体写入 `req.attributes["text"]`,便于与 [[jsonParser]] 的 "json" 入口对
 * 称地取用(`req.body` 本身始终保有该文本)。Content-Type 不匹配的请求原样放行、不
 * 写入。
 */
public func textParser(contentType!: String = "text/plain"): Middleware {
    return {
        req: HttpRequest, _: HttpResponse, next: Next =>
            match (req.header("content-type")) {
                case Some(ct) =>
                    if (ct.toAsciiLower().contains(contentType.toAsciiLower())) {
                        req.setAttribute("text", req.body)
                    }
                case None => ()
            }
            next()
    }
}

/**
 * 以原始字节方式处理请求体的中间件,对应 Express 的 `express.raw()`。
 *
 * 当请求 Content-Type 匹配 `contentType`(默认 `"application/octet-stream"`)时,把
 * 原始字节(二进制安全,不经 UTF-8 编解码往返)存入 `req.locals["raw"]`(取用:
 * `req.local("raw")` 再向下转型为 `Array<UInt8>`;也可始终用 `req.bodyBytes` 直接读
 * 取)。常用于 Webhook 按原文验签等场景。
 */
public func rawParser(contentType!: String = "application/octet-stream"): Middleware {
    return {
        req: HttpRequest, _: HttpResponse, next: Next =>
            match (req.header("content-type")) {
                case Some(ct) =>
                    if (ct.toAsciiLower().contains(contentType.toAsciiLower())) {
                        req.setLocal("raw", req.bodyBytes)
                    }
                case None => ()
            }
            next()
    }
}
