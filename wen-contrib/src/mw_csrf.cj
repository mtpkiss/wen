package wen_contrib

import wen.*
import std.time.*
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

public func csrf(cookieName!: String = "_csrf", field!: String = "_csrf", signed!: Bool = true, httpOnly!: Bool = true,
    secure!: Bool = false, sameSite!: String = "Lax", rotateAfterSeconds!: Int64 = -1): Middleware {
    return {
        req: HttpRequest, res: HttpResponse, next: Next =>
            // 1. 复用此前下发 Cookie 里的 token;没有有效 token 则新生成并下发。
            //
            // rotateAfterSeconds 选项(opt-in,默认 -1 关闭):开启时 cookie value 形
            // 如 "${token}@${iat_unix_sec}",iat 嵌入并随整体签名;每次请求检查
            // now - iat,超过 rotateAfterSeconds 即视为过期,重生 token + 重发 cookie。
            // 这缩小了 token 泄露的有效利用窗口 — 否则同一 token 整个会话期复用,
            // 从代理日志 / 浏览器历史 / 网络抓包任一处泄露后,攻击者就有整段窗口可
            // 利用。默认关是为了与 Express csurf 行为对齐 + 不引入"每次请求都换"
            // 的体验断裂(若想极致,业务自行设置短窗口)。
            var token = ""
            var needNewCookie = false
            let existing = if (signed) {
                req.signedCookie(cookieName)
            } else {
                req.cookie(cookieName)
            }
            match (existing) {
                case Some(t) =>
                    if (!t.isEmpty()) {
                        if (rotateAfterSeconds > 0) {
                            // 启用 rotate 模式:期望 cookie value 形如 "tok@iat"。
                            match (splitTokenAndIat(t)) {
                                case Some((tok, iat)) =>
                                    let nowSec = DateTime.now().toUnixTimeStamp().toSeconds()
                                    // P2-14:nowSec - iat 不会溢出。nowSec 是真实 Unix 秒(小正数,
                                    // ~1.7e9);iat 由 splitTokenAndIat 严格解析,保证 ∈ [0, Int64.Max]
                                    // (拒负数、拒溢出)。故差值落在 (Int64.Min, nowSec]:下界
                                    // nowSec - Int64.Max > Int64.Min(因 nowSec ≥ 0),不会下溢。且 iat
                                    // 取自**已验签** cookie(服务端在下方写入并随整体签名),客户端无法
                                    // 伪造未来 iat,负差值(iat > now)不构成攻击面。
                                    if (nowSec - iat <= rotateAfterSeconds) {
                                        token = tok
                                    } else {
                                        // 过期 → 抛弃旧 token,下面会新生 + 下发。
                                        needNewCookie = true
                                    }
                                case None =>
                                    // 旧裸 token 格式(未启用 rotate 前下发的)→
                                    // 升级到新格式重发。
                                    needNewCookie = true
                            }
                        } else {
                            // 未启用 rotate:旧行为,直接复用 token。
                            token = t
                        }
                    }
                case None => ()
            }
            if (token.isEmpty()) {
                token = nextCsrfToken()
                needNewCookie = true
            }
            if (needNewCookie) {
                let cookieValue = if (rotateAfterSeconds > 0) {
                    let nowSec = DateTime.now().toUnixTimeStamp().toSeconds()
                    "${token}@${nowSec}"
                } else {
                    token
                }
                res.cookie(cookieName, cookieValue, httpOnly: httpOnly, secure: secure, sameSite: sameSite,
                    signed: signed)
            }
            // 2. 暴露给视图 / 下游:渲染进表单隐藏字段或 meta 标签,供后续请求回传。
            //    客户端回传的始终是裸 token(表单字段 / 请求头),不含 @iat 部分。
            req.attributes["csrfToken"] = token

            // 3. 安全方法放行不校验;非安全方法必须回传匹配的 token。
            if (isCsrfSafeMethod(req.method)) {
                next()
            } else {
                match (readCsrfToken(req, field)) {
                    case Some(sent) =>
                        if (constantTimeEquals(sent, token)) {
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

// 读取客户端回传的 token:依次尝试 X-CSRF-Token / X-XSRF-Token 头、查询串、表单字段;
// 取第一个非空者。请求头与查询串优先,**最后**才尝试表单字段(req.attribute) —
// P1-9:`req.attribute(field)` 会触发 ensureBody → multipart 解析。攻击者 POST 1 MiB
// multipart 垃圾到必然被 csrf 403 的端点,在校验前已花光解析 CPU/内存。只有当客户端
// 真带了 form/urlencoded 类型且没在头里/query 里给 token 时,才付出解析代价。
func readCsrfToken(req: HttpRequest, field: String): ?String {
    match (csrfHeader(req, "x-csrf-token")) {
        case Some(v) => return Some(v)
        case None => ()
    }
    match (csrfHeader(req, "x-xsrf-token")) {
        case Some(v) => return Some(v)
        case None => ()
    }
    match (req.queryParam(field)) {
        case Some(v) =>
            if (!v.isEmpty()) {
                return Some(v)
            }
        case None => ()
    }
    // P1-9:**只**在 Content-Type 是 application/x-www-form-urlencoded 时才读 form 字段。
    // multipart/form-data 故意被排除 — 它常承载大文件,csrf 校验前触发解析会被攻击者
    // 用 1 MiB+ 垃圾体放大成显著 CPU/内存开销。multipart 端点应通过 X-CSRF-Token 头
    // 回传 token(AJAX 标准做法)。其它 Content-Type 同理 — token 应走 header / query。
    if (isUrlencodedContentType(req)) {
        match (req.attribute(field)) {
            case Some(v) =>
                if (!v.isEmpty()) {
                    return Some(v)
                }
            case None => ()
        }
    }
    return None
}

// 仅当 Content-Type 主类型为 application/x-www-form-urlencoded 时返回 true。
// CSRF 在表单 POST 场景下仍走 form 字段读取(传统 HTML 表单);其它一律走 header / query。
func isUrlencodedContentType(req: HttpRequest): Bool {
    match (req.header("content-type")) {
        case Some(ct) =>
            let lower = ct.toAsciiLower().trimAscii()
            return lower.startsWith("application/x-www-form-urlencoded")
        case None => return false
    }
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

// 把 rotate 模式下的 cookie value 拆成 (token, iat)。形态不对、iat 非法十进制
// 数字、或缺 @ 一律返回 None,调用方据此降级到"重发新格式 cookie"路径 — 这样
// 既容错(用户从未启用 rotate 切到启用 rotate 时,旧裸 token cookie 不会爆),
// 又防止攻击者塞畸形 cookie 让 iat 解析意外接受。
func splitTokenAndIat(value: String): ?(String, Int64) {
    let atIdx = match (value.indexOf("@")) {
        case Some(i) => i
        case None => return None
    }
    let tok = value[0..atIdx]
    let iatStr = value[(atIdx + 1)..value.size]
    if (tok.isEmpty() || iatStr.isEmpty()) {
        return None
    }
    // 严格十进制解析:任何非数字字符或溢出都视为非法(不像 parseInt 那样宽容)。
    var iat: Int64 = 0
    for (b in iatStr.toArray()) {
        if (b < UInt8(48) || b > UInt8(57)) {
            return None
        }
        let d = Int64(b) - 48
        if (iat > (Int64.Max - d) / 10) {
            return None
        }
        iat = iat * 10 + d
    }
    return Some((tok, iat))
}
