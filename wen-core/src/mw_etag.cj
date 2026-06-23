package wen

/*
 * 动态响应的 ETag / 条件 GET 中间件。
 *
 * 文件响应(sendFile/download/staticFiles)本就由 applyFileResponse 处理了 ETag 与
 * 304;但 res.send / res.json / res.sendBytes 这类「动态生成」的响应默认没有。注册本
 * 中间件后,会在响应处理完毕时:对 200 的 GET/HEAD 响应,按响应体算出一个强 ETag 并
 * 设置 ETag 头;若请求带的 If-None-Match 与之匹配,则改回 304 Not Modified(空体),
 * 省去重复传输——这正是 Express 默认开启的 etag 行为。
 *
 * 说明:若响应已带 Content-Encoding(例如由 nginx 等边缘压缩、或其它中间件设置),本
 * 中间件会直接跳过(只是拿不到 ETag,不会出错)。
 *
 * 跳过的情形:流式响应、非 200、非 GET/HEAD、空体、已自带 ETag(如文件响应)、已被
 * 压缩(带 Content-Encoding)。
 */
public func etag(): Middleware {
    return {
        req: HttpRequest, res: HttpResponse, next: Next =>
            next()

            if (res.hijacked || !res.finished) {
                return
            }
            if (res.statusCode != 200) {
                return
            }
            if (req.method != HttpMethod.GET && req.method != HttpMethod.HEAD) {
                return
            }
            // 已有 ETag(如文件响应已设)或已被压缩,则不处理。
            match (res.get("ETag")) {
                case Some(_) => return
                case None => ()
            }
            match (res.get("Content-Encoding")) {
                case Some(_) => return
                case None => ()
            }

            let raw = match (res.bodyBytes) {
                case Some(b) => b
                case None => res.body.toArray()
            }
            if (raw.size == 0) {
                return
            }

            let tag = computeETag(raw)
            res.set("ETag", tag)

            // 条件请求:If-None-Match 命中当前 ETag -> 回 304(空体;ETag 头保留)。
            match (req.header("if-none-match")) {
                case Some(inm) =>
                    if (etagMatches(inm, tag)) {
                        send304(res)
                    }
                case None => ()
            }
    }
}
