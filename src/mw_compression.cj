package wen

/*
 * 响应压缩中间件(gzip)。
 *
 * 注册后,它在请求处理完毕、响应即将发出前介入:若客户端 Accept-Encoding 接受 gzip、
 * 响应内容可压缩(文本类)、体积达到阈值、且尚未被压缩,就用自写的 gzipCompress 压缩
 * 响应体,并设置 Content-Encoding: gzip 与 Vary: Accept-Encoding。压缩后体积反而不减小
 * 时则放弃(保持原样)。
 *
 * 用法:尽量靠前注册(`app.use(compression())`)。因为中间件「调用 next() 之后」的
 * 代码是后进先出的——越靠前注册,其压缩动作越靠后执行,从而能拿到最终成形的响应体。
 *
 * 说明:对已劫持连接的流式响应(stream/sse)不处理;对 204/304、空体、二进制/已压缩
 * 类型(图片、压缩包等)也跳过——避免浪费 CPU 去压不可压缩的数据。
 */

// 构造 gzip 压缩中间件。threshold 为触发压缩的最小响应体字节数(默认 256)。
public func compression(threshold!: Int64 = 256): Middleware {
    return { req: HttpRequest, res: HttpResponse, next: Next =>
        next()

        // 流式响应已自行接管连接,无法在此整体压缩。
        if (res.hijacked || !res.finished) {
            return
        }
        // 已设置内容编码(可能已压缩)则不再处理。
        match (res.get("Content-Encoding")) {
            case Some(_) => return
            case None => ()
        }
        // 无体状态码跳过。
        if (res.statusCode == 204 || res.statusCode == 304) {
            return
        }
        // 客户端是否接受 gzip。
        let accept = match (req.header("accept-encoding")) {
            case Some(v) => v.toAsciiLower()
            case None => return
        }
        if (!accept.contains("gzip")) {
            return
        }
        // 仅压缩文本类内容。
        let ct = match (res.get("Content-Type")) {
            case Some(v) => v.toAsciiLower()
            case None => ""
        }
        if (!isCompressible(ct)) {
            return
        }
        // 取响应体字节(优先 bodyBytes,否则取文本体的 UTF-8 字节)。
        let raw = match (res.bodyBytes) {
            case Some(b) => b
            case None => res.body.toArray()
        }
        if (raw.size < threshold) {
            return
        }
        let gz = gzipCompress(raw)
        // 压缩没带来收益(小数据偶尔会变大)就放弃。
        if (gz.size >= raw.size) {
            return
        }
        res.bodyBytes = Some(gz)
        res.headers["Content-Encoding"] = "gzip"
        // 响应随 Accept-Encoding 而变,补 Vary 以利缓存正确性。
        match (res.headers.get("Vary")) {
            case Some(v) => if (!v.contains("Accept-Encoding")) { res.headers["Vary"] = "${v}, Accept-Encoding" }
            case None => res.headers["Vary"] = "Accept-Encoding"
        }
    }
}

// 判断某 Content-Type 是否值得压缩(文本/JSON/JS/XML/SVG 等);二进制类一律跳过。
func isCompressible(contentType: String): Bool {
    if (contentType.isEmpty()) {
        return false
    }
    return contentType.contains("text/") ||
        contentType.contains("application/json") ||
        contentType.contains("application/javascript") ||
        contentType.contains("application/xml") ||
        contentType.contains("+json") ||
        contentType.contains("+xml") ||
        contentType.contains("image/svg")
}
