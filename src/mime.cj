package wen

import std.collection.*

/*
 * 扩展名 -> MIME 类型的「可扩展」映射。
 *
 * 设计意图(对应「核心应使能模式、而非强加模式」):框架内置一张常见扩展名到
 * MIME 的兜底表,但不把它焊死——用户可经 app.mime(ext, type) 或包级
 * registerMimeType(ext, type) 注册新的、或覆盖既有的映射,从而支持 .webp /
 * .wasm / .avif 等内置表未覆盖的类型,而无需修改框架源码。这与 app.engine(ext, fn)
 * 注册视图引擎是同一种「注册表 + 回落默认」范式。
 *
 * 生命周期与并发:与路由 / 中间件 / 视图引擎的注册一致,约定在 listen() 之前
 * (启动配置阶段)完成注册;此后请求处理期间只读。因此这里用普通 HashMap、不加锁,
 * 与框架其余启动期注册保持同样的约定。MIME 类型本质是进程级的全局事实(.webp
 * 永远是 image/webp,与具体是哪个 Application 无关),故采用包级全局表而非实例级。
 */

// 用户注册的扩展名 -> MIME 映射(键已规范化:去前导点 + 小写)。查询时优先于内置兜底,
// 因此用户既能新增未知扩展名,也能覆盖内置默认。
let userMimeTypes = HashMap<String, String>()

// 规范化 MIME 表的键:去掉可能的前导点并小写,使 ".WEBP" / "webp" / ".webp" 等价。
// 复用 view.cj 的 normalizeExt(去前导点)再补一道小写。
func mimeKey(ext: String): String {
    return normalizeExt(ext).toAsciiLower()
}

// 注册(或覆盖)一个扩展名到 MIME 类型的映射。ext 可带或不带前导点、大小写不敏感。
// 约定在 listen() 之前调用。app.mime(ext, type) 是它的实例级链式语法糖。
public func registerMimeType(ext: String, mimeType: String): Unit {
    userMimeTypes[mimeKey(ext)] = mimeType
}

// 根据文件名(或路径)的扩展名推断 Content-Type:先查用户注册表,未命中再回落到
// 内置兜底表;扩展名无法识别(或文件无扩展名)时返回通用的 application/octet-stream
// (让浏览器当作下载处理)。推断对扩展名大小写不敏感。sendFile / download / 静态文件
// 中间件都经它取类型。
func mimeFor(name: String): String {
    let ext = match (fileExt(name)) {
        case Some(e) => mimeKey(e)
        case None => return "application/octet-stream"
    }
    match (userMimeTypes.get(ext)) {
        case Some(t) => return t
        case None => return builtinMimeForExt(ext)
    }
}

// 内置的扩展名 -> MIME 兜底表(不含用户注册项)。键为已规范化的扩展名(无前导点、
// 小写)。识别不出的扩展名回退到 application/octet-stream。
func builtinMimeForExt(ext: String): String {
    if (ext == "html") {
        return "text/html; charset=utf-8"
    } else if (ext == "css") {
        return "text/css"
    } else if (ext == "js") {
        return "application/javascript"
    } else if (ext == "json") {
        return "application/json"
    } else if (ext == "png") {
        return "image/png"
    } else if (ext == "jpg" || ext == "jpeg") {
        return "image/jpeg"
    } else if (ext == "gif") {
        return "image/gif"
    } else if (ext == "svg") {
        return "image/svg+xml"
    } else if (ext == "txt") {
        return "text/plain; charset=utf-8"
    } else {
        return "application/octet-stream"
    }
}

// 查询用户注册表(供 contentTypeFor 在回落 octet-stream 前复用,使 res.type("webp")
// 在注册后与 mimeFor 一致地命中)。命中返回 Some,否则 None。
func lookupUserMime(key: String): ?String {
    return userMimeTypes.get(mimeKey(key))
}
