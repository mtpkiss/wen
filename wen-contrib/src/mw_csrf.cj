package wen_contrib


import wen.*
/*
 * CSRF(跨站请求伪造)防护中间件 —— 对应 Express 生态的 csurf,采用「签名双提交 Cookie」。
 *
 * 原理:服务端为浏览器签发一个随机 CSRF token,经 **HMAC 签名的 Cookie** 下发
 * (默认 _csrf,HttpOnly + SameSite=Lax)。对「非安全方法」(POST/PUT/PATCH/DELETE)的请求,
 * 要求其再通过**另一渠道**回传同一 token —— 请求头 X-CSRF-Token / X-XSRF-Token,或表单字段 /
 * 查询串 _csrf。两者一致才放行,否则回 403。
 *
 * 为什么安全:跨站攻击页面能诱导浏览器「自动带上」Cookie,却无法读取签名 Cookie 里的明文
 * token,也就无法把正确 token 放进请求头 / 表单字段;HMAC 签名又使攻击者无法伪造一个自洽的
 * Cookie。必须两道门同时满足才放行。
 *
 * 用法:
 *   app.cookieSecret = "..."          // 默认 signed=true,必须先设密钥(同签名 Cookie / session)
 *   app.use(csrf())
 *   // 安全方法(GET 等)请求经过后,token 暴露在 req.attribute("csrfToken")。把它渲染进
 *   // 表单隐藏字段 <input type="hidden" name="_csrf" value="..."> 或页面 meta 标签,
 *   // 供后续 POST 表单 / AJAX(置于 X-CSRF-Token 头)回传。
 *
 * 选项:
 *   - cookieName  下发 token 的 Cookie 名(默认 _csrf)
 *   - field       回传 token 的表单字段 / 查询串名(默认 _csrf;请求头固定认 X-CSRF-Token / X-XSRF-Token)
 *   - signed      Cookie 是否 HMAC 签名(默认 true,需 app.cookieSecret)。设为 false 则为朴素双提交,
 *                 便于前端 JS 直接读 Cookie 回填请求头,但失去防 Cookie 篡改能力。
 *   - httpOnly / secure / sameSite  下发 Cookie 的属性(默认 HttpOnly、SameSite=Lax)。
 *
 * 安全方法(GET/HEAD/OPTIONS)只「确保 token 存在并下发 Cookie」,不做校验。
 */

// 生成 128 位 CSRF token。**安全关键**:必须由不可预测的 CSPRNG 派生,否则攻击者可观察
// 自己拿到的 token 来恢复 PRNG 内部状态、进而预测他人 token。本框架经 secureRandomHex
// (HMAC-SHA256 单向扩展的 PRNG,详见 secure_random.cj)生成,保证输出不可反推内部状态。
func nextCsrfToken(): String {
    return secureRandomHex(16)
}

public func csrf(cookieName!: String = "_csrf", field!: String = "_csrf", signed!: Bool = true,
    httpOnly!: Bool = true, secure!: Bool = false, sameSite!: String = "Lax"): Middleware {
    return {
        req: HttpRequest, res: HttpResponse, next: Next =>
            // 1. 复用此前下发 Cookie 里的 token;没有有效 token 则新生成并下发。
            var token = ""
            let existing = if (signed) {
                req.signedCookie(cookieName)
            } else {
                req.cookie(cookieName)
            }
            match (existing) {
                case Some(t) => if (!t.isEmpty()) {
                    token = t
                }
                case None => ()
            }
            if (token.isEmpty()) {
                token = nextCsrfToken()
                res.cookie(cookieName, token, httpOnly: httpOnly, secure: secure, sameSite: sameSite, signed: signed)
            }
            // 2. 暴露给视图 / 下游:渲染进表单隐藏字段或 meta 标签,供后续请求回传。
            req.attributes["csrfToken"] = token

            // 3. 安全方法放行不校验;非安全方法必须回传匹配的 token。
            if (isCsrfSafeMethod(req.method)) {
                next()
            } else {
                match (readCsrfToken(req, field)) {
                    case Some(sent) => if (constantTimeEquals(sent, token)) {
                        next()
                    } else {
                        rejectCsrf(res)
                    }
                    case None => rejectCsrf(res)
                }
            }
    }
}

// GET / HEAD / OPTIONS 视为只读的安全方法,无需 CSRF 校验。
func isCsrfSafeMethod(method: String): Bool {
    match (method) {
        case "GET" | "HEAD" | "OPTIONS" => return true
        case _ => return false
    }
}

// 读取客户端回传的 token:依次尝试 X-CSRF-Token / X-XSRF-Token 头、表单字段、查询串;
// 取第一个非空者。请求头优先,便于 AJAX 场景无需改动请求体。
func readCsrfToken(req: HttpRequest, field: String): ?String {
    match (csrfHeader(req, "x-csrf-token")) {
        case Some(v) => return Some(v)
        case None => ()
    }
    match (csrfHeader(req, "x-xsrf-token")) {
        case Some(v) => return Some(v)
        case None => ()
    }
    match (req.attribute(field)) {
        case Some(v) => if (!v.isEmpty()) {
            return Some(v)
        }
        case None => ()
    }
    match (req.queryParam(field)) {
        case Some(v) => if (!v.isEmpty()) {
            return Some(v)
        }
        case None => ()
    }
    return None
}

// 取指定请求头并去空白;为空则视为缺失。
func csrfHeader(req: HttpRequest, name: String): ?String {
    match (req.header(name)) {
        case Some(v) =>
            let t = v.trimAscii()
            if (t.isEmpty()) {
                return None
            }
            return Some(t)
        case None => return None
    }
}

// 校验失败:回 403。
func rejectCsrf(res: HttpResponse): Unit {
    res.status(403).send("invalid csrf token")
}
