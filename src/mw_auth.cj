package wen

/*
 * 认证中间件:HTTP Basic 与 Bearer Token。
 *
 * 这两个工厂都接收一个「校验回调」,把「凭据是否有效」的判断交给调用方(对接你的用户表、
 * 令牌库等)。校验通过则放行(next());否则回 401 Unauthorized,并按方案带上
 * WWW-Authenticate 头(Basic 会触发浏览器弹出登录框)。
 *
 * - basicAuth(verify):解析 Authorization: Basic base64(user:pass),回调签名 (user, pass) -> Bool;
 *   通过后把用户名存入 req.attribute("authUser") 供下游读取。
 * - bearerAuth(verify):解析 Authorization: Bearer <token>,回调签名 (token) -> Bool。
 *
 * 可挂在具体路由上(多处理器写法)或某个路径前缀(app.use(path, basicAuth(...)))。
 */

// HTTP Basic 认证。
public func basicAuth(verify: (String, String) -> Bool, realm!: String = "Restricted"): Middleware {
    return { req: HttpRequest, res: HttpResponse, next: Next =>
        match (authScheme(req, "Basic ")) {
            case Some(b64) =>
                let decoded = String.fromUtf8(base64Decode(b64))
                let (user, pass) = splitOnce(decoded, ":")
                if (verify(user, pass)) {
                    req.attributes["authUser"] = user
                    next()
                } else {
                    sendUnauthorized(res, "Basic", realm)
                }
            case None => sendUnauthorized(res, "Basic", realm)
        }
    }
}

// Bearer Token 认证。
public func bearerAuth(verify: (String) -> Bool, realm!: String = "Restricted"): Middleware {
    return { req: HttpRequest, res: HttpResponse, next: Next =>
        match (authScheme(req, "Bearer ")) {
            case Some(token) =>
                if (verify(token)) {
                    next()
                } else {
                    sendUnauthorized(res, "Bearer", realm)
                }
            case None => sendUnauthorized(res, "Bearer", realm)
        }
    }
}

// 从 Authorization 头中取出指定方案(如 "Basic " / "Bearer ")后面的凭据串;
// 方案名大小写无关。不匹配则返回 None。
func authScheme(req: HttpRequest, prefix: String): ?String {
    match (req.header("authorization")) {
        case Some(h) =>
            let ht = h.trimAscii()
            if (ht.size >= prefix.size && ht[0..prefix.size].toAsciiLower() == prefix.toAsciiLower()) {
                return Some(ht[prefix.size..ht.size].trimAscii())
            }
            return None
        case None => return None
    }
}

// 回 401 并带上 WWW-Authenticate 头。
func sendUnauthorized(res: HttpResponse, scheme: String, realm: String): Unit {
    res.set("WWW-Authenticate", "${scheme} realm=\"${realm}\"").status(401).send("Unauthorized")
}
