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

// 构造一个从 `root` 目录提供文件服务的中间件。
public func staticFiles(root: String): Middleware {
    // 仓颉的 std.fs 不会处理路径开头的 "./"，因此这里把它去掉，这样调用方
    // 无论传 "public" 还是 "./public" 都能正常工作。
    let base = if (root.startsWith("./")) {
        root[2..root.size]
    } else {
        root
    }
    return { req: HttpRequest, res: HttpResponse, next: Next =>
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
        if (rel.isEmpty()) {
            rel = "index.html"
        }

        // 安全：绝不允许通过 ".." 进行目录穿越、逃出所服务的 root 目录。
        // 一旦相对路径里出现 ".."，直接放行（next）而不去读文件。
        if (rel.contains("..")) {
            next()
            return
        }

        let path = "${base}/${rel}"

        // 用 `exists` 检查路径是否存在；不存在的文件（以及无法读取的情况）
        // 都跳过并交给后续路由处理，不在这里返回。
        if (!exists(path)) {
            next()
            return
        }

        // 直接发送文件的原始字节，这样图片、字体等二进制资源能被原封不动地
        // 送出，而不会因为经过一次 UTF-8 编解码往返而被破坏。
        res.contentType(mimeFor(rel)).sendBytes(File.readFrom(path))
    }
}

// 根据文件名的扩展名推断 Content-Type；对识别不出的扩展名，回退到通用的
// 二进制类型 application/octet-stream（让浏览器当作下载处理）。
// 推断前先把文件名转成小写，因此扩展名大小写不影响匹配。
func mimeFor(name: String): String {
    let n = name.toAsciiLower()
    if (n.endsWith(".html")) {
        return "text/html; charset=utf-8"
    } else if (n.endsWith(".css")) {
        return "text/css"
    } else if (n.endsWith(".js")) {
        return "application/javascript"
    } else if (n.endsWith(".json")) {
        return "application/json"
    } else if (n.endsWith(".png")) {
        return "image/png"
    } else if (n.endsWith(".jpg") || n.endsWith(".jpeg")) {
        return "image/jpeg"
    } else if (n.endsWith(".gif")) {
        return "image/gif"
    } else if (n.endsWith(".svg")) {
        return "image/svg+xml"
    } else if (n.endsWith(".txt")) {
        return "text/plain; charset=utf-8"
    } else {
        return "application/octet-stream"
    }
}
