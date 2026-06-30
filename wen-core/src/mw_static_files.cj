package wen

import std.fs.*

/*
 * 静态文件服务中间件。
 *
 * 针对 GET/HEAD 请求，从 `root` 目录下提供静态文件。当请求路径能映射到 root
 * 下一个真实存在的文件时，就把该文件发送出去（Content-Type 依据扩展名推断），
 * 并就此结束响应；除此之外的所有情况（非 GET/HEAD、含路径穿越、文件不存在）
 * 都会调用 next()，把控制权交还给正常的路由流程。
 *
 * 安全性：包含 ".." 的路径会被拒绝，从而保证请求无论如何都无法跳出 `root`
 * 目录、去读取服务目录之外的文件。
 */

/**
 * 构造一个从 `root` 目录提供文件服务的中间件。
 *
 * 针对 GET/HEAD 请求,从 `root` 目录下提供静态文件。当请求路径能映射到 root 下一个
 * 真实存在的文件时,就把该文件发送出去(Content-Type 依据扩展名推断),并就此结束响
 * 应;除此之外的所有情况(非 GET/HEAD、含路径穿越、文件不存在)都会调用 `next()`,
 * 把控制权交还给正常的路由流程。
 *
 * **安全性**:包含 `..` 的路径会被拒绝,从而保证请求无论如何都无法跳出 `root` 目
 * 录、去读取服务目录之外的文件。
 *
 * **symlink 警告(部署须知)**:上述沙箱是**词法层面**的路径规范化(把请求路径里的 `..` /
 * `.` 归一后做前缀比对),**不解析文件系统软链接**。若 `root` 目录内存在指向外部的 symlink
 * (如 `root/data → /etc`),其目标仍会被读到 —— 词法检查看不出软链接逃逸。请勿在服务目录内
 * 放置不可信的软链接;若 `root` 对用户可写或来源不可信,应在 OS / 文件系统层禁止跟随 symlink,
 * 或确保根内无逃逸软链接。
 *
 * 可选具名参数:
 *
 * - `index`:目录默认文件名(默认 `"index.html"`);请求路径为空或以 `/` 结尾时,自
 *   动在其后补上该文件名。
 * - `maxAge`:缓存秒数;`>=0` 时为响应加上 `Cache-Control: public, max-age=N`。
 * - `dotfiles`:隐藏文件(路径段以 `.` 开头,如 .env/.git)的策略:`"ignore"`(默
 *   认,当作不存在、放行)/ `"deny"`(回 403)/ `"allow"`(照常提供)。
 * - `etag`:是否发送 ETag 并参与 `If-None-Match` 条件请求(默认 true)。
 * - `lastModified`:是否发送 `Last-Modified` 并参与 `If-Modified-Since` 条件请求(默
 *   认 true)。
 * - `immutable`:`maxAge>0` 且 `immutable=true` 时,Cache-Control 追加 `, immutable`,
 *   告诉客户端该资源在缓存期内永远不会变(适合带指纹的构建产物)。
 * - `setHeaders`:在文件发送前调用的回调,可在其中对响应任意定制头部;入参为
 *   `(res, 该次请求映射到的真实文件路径)`。默认为 None(不调用)。
 * - `redirect`:目录请求且 URL 不以 `/` 结尾时是否 301 重定向到带斜杠版本(默认
 *   true)。这能让目录内 HTML 的相对路径正确解析(比如 `/dir` 上的
 *   `<img src="a.png">` 应解析为 `/dir/a.png` 而非 `/a.png`)。关闭后目录请求一律
 *   交给 `next()`。
 */
public func staticFiles(root: String, index!: String = "index.html", maxAge!: Int64 = -1, dotfiles!: String = "ignore",
    etag!: Bool = true, lastModified!: Bool = true, immutable!: Bool = false,
    setHeaders!: ?(HttpResponse, String) -> Unit = None, redirect!: Bool = true, nosniff!: Bool = true): Middleware {
    // 仓颉的 std.fs 不会处理路径开头的 "./"，因此这里把它去掉，这样调用方
    // 无论传 "public" 还是 "./public" 都能正常工作。
    let base = if (root.startsWith("./")) {
        root[2..root.size]
    } else {
        root
    }
    return {
        req: HttpRequest, res: HttpResponse, next: Next =>
            // 只处理静态资源的 GET/HEAD 请求；其余方法一律放行交给后续中间件。
            if (req.method != HttpMethod.GET && req.method != HttpMethod.HEAD) {
                next()
                return
            }

            var rel = if (req.path.startsWith("/")) {
                req.path[1..req.path.size]
            } else {
                req.path
            }

            // 安全:用 resolveWithinRoot 做沙箱化路径规范化,任何能跨出 base 的相对路径
            // (典型如含 "..",或被字符串解码后跨出根目录)都会抛异常 -> 视作未命中放行。
            // 这比早先「rel.contains("..")」更严密:resolveWithinRoot 是路径规范化后的
            // 前缀比对,而不只是看 ".." 字面值。
            let probeFull = try {
                resolveWithinRoot(base, rel)
            } catch (_: Exception) {
                next()
                return
            }

            // 目录处理:URL 不以 "/" 结尾、但映射到的真实路径是目录时,默认 301 重定向到
            // 带斜杠的版本(redirect=true);redirect=false 则交给 next 放行(视作未命中)。
            // 至于 URL 已带 "/" 的目录请求,则在下面追加 index 后按文件处理。
            let endsWithSlash = rel.isEmpty() || rel.endsWith("/")
            if (!endsWithSlash) {
                if (exists(probeFull) && isDirectoryPath(probeFull)) {
                    if (redirect) {
                        sendDirectoryRedirect(req, res)
                    } else {
                        next()
                    }
                    return
                }
            }

            // 目录请求(空路径或 URL 以 "/" 结尾)补上默认索引文件。
            if (endsWithSlash) {
                rel += index
            }

            // 隐藏文件(任一路径段以 "." 开头)按 dotfiles 策略处理。
            if (dotfiles != "allow" && hasDotSegment(rel)) {
                if (dotfiles == "deny") {
                    res.status(403).send("Forbidden")
                } else {
                    next()
                }
                return
            }

            // 沙箱化拼接最终路径:补上 index 后路径仍需在 base 之内,否则放行。
            let path = try {
                resolveWithinRoot(base, rel)
            } catch (_: Exception) {
                next()
                return
            }

            // 用 `exists` 检查路径是否存在;不存在的文件(以及无法读取的情况)
            // 都跳过并交给后续路由处理,不在这里返回。
            if (!exists(path)) {
                next()
                return
            }

            // 可选的缓存头。
            if (maxAge >= 0) {
                var cc = "public, max-age=${maxAge}"
                if (immutable && maxAge > 0) {
                    cc += ", immutable"
                }
                res.set("Cache-Control", cc)
            }

            // 默认 X-Content-Type-Options: nosniff:挡浏览器的 MIME 嗅探。最大风险在
            // "用户上传目录"场景:攻击者上传带 <script> 的 SVG 等文件,浏览器可能
            // 按嗅探结果当 HTML 渲染 → 存储型 XSS。框架在静态文件路径上默认发该头,
            // 让 staticFiles("/uploads") 这种最直觉的写法也是安全的;特殊场景显式传
            // `nosniff: false` 撤掉。本头先于 setHeaders 钩子,用户回调可覆盖 / 移除。
            if (nosniff) {
                res.set("X-Content-Type-Options", "nosniff")
            }

            // 自定义响应头钩子:在文件发送前调用,可任意改写响应头。
            match (setHeaders) {
                case Some(cb) => cb(res, path)
                case None => ()
            }

            // 经 applyFileResponse 发送文件：原始字节（二进制安全），并统一附带 ETag
            // 与 Accept-Ranges，支持 If-None-Match 命中回 304、Range 请求回 206 分片。
            // etag / lastModified 开关被透传过去,用于关闭对应响应头与条件请求支持。
            let lm: ?String = if (lastModified) {
                httpDateForFile(path)
            } else {
                None
            }
            // P1-11:静态文件默认用 size+mtime 弱 ETag,跳过对全文做多项式 hash。
            // 10 MB+ 文件高并发时差距明显;serve-static 默认也是弱 ETag。失败回退到
            // 内容强 ETag(由 applyFileResponse 内部计算)以保留向后兼容语义。
            let weak: ?String = if (etag) {
                weakETagFromStat(path)
            } else {
                None
            }
            applyFileResponse(res, File.readFrom(path), mimeFor(rel), lm, etag: etag, sendLastModified: lastModified,
                precomputedETag: weak)
    }
}

// 相对路径中是否存在以 "." 开头的路径段(隐藏文件/目录,如 ".env"、".git/..")。
func hasDotSegment(rel: String): Bool {
    for (seg in pathSegments(rel)) {
        if (seg.startsWith(".")) {
            return true
        }
    }
    return false
}

// 判断给定的文件系统路径是否为目录。基于 FileInfo 的 isDirectory 属性,任何异常
// (路径不可访问 / 权限不足等)都返回 false,与上层「不存在即放行」的策略一致。
func isDirectoryPath(path: String): Bool {
    try {
        return FileInfo(Path(path)).isDirectory()
    } catch (_: Exception) {
        return false
    }
}

// 把目录请求(无尾斜杠)301 重定向到带斜杠的版本。优先用 originalUrl(以正确处理
// 经由挂载点的真实 URL),否则退回到 req.path;并保留查询串。
func sendDirectoryRedirect(req: HttpRequest, res: HttpResponse): Unit {
    let originalOrPath = if (!req.originalUrl.isEmpty()) {
        req.originalUrl
    } else {
        req.path
    }
    let (pathPart, query) = splitOnce(originalOrPath, "?")
    var target = pathPart + "/"
    if (!query.isEmpty()) {
        target += "?" + query
    }
    res.redirect(301, target)
}

// mimeFor / 扩展名 -> MIME 的映射已移至 mime.cj,并改为「用户注册表优先、回落内置」
// 的可扩展形式(经 app.mime(ext, type) / registerMimeType(ext, type) 扩展或覆盖)。
