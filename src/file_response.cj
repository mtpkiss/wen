package wen

import std.collection.*

/*
 * 文件响应的公共逻辑:把一段文件字节按「带缓存协商与分片下载」的语义写入响应。
 *
 * sendFile、download 以及静态文件中间件都汇聚到这里,从而统一获得三种能力:
 *   1. ETag + 条件请求:为内容算出一个 ETag 响应头;当客户端带着
 *      If-None-Match 且与之匹配时,直接回 304 Not Modified(空体),省去重复传输。
 *   2. Range 分片下载:声明 Accept-Ranges: bytes;当客户端带 Range 头且区间
 *      合法时,回 206 Partial Content + Content-Range,只发请求的那一段字节
 *      (音视频拖动进度、断点续传依赖此能力);区间非法/越界则回 416。
 *   3. 二进制安全:始终以原始字节(bodyBytes)发送,不经 UTF-8 编解码往返。
 *
 * 这些条件/分片行为需要读取请求头,因此依赖响应上挂着的 res.req(由 app.handle
 * 设置)。若 res.req 为 None(例如测试中直接构造 res 调用),则退化为一次性发送
 * 完整内容(仍会带上 ETag/Accept-Ranges 头)。
 */

// Range 头解析结果的三种情形。
enum RangeResult {
    | RangeOk(Int64, Int64)   // 合法区间 [start, end](闭区间,含两端)
    | RangeUnsatisfiable      // 语法合法但无法满足(越界等)-> 416
    | RangeIgnore             // 不识别 / 多区间 / 非法,忽略 Range,照常发整体
}

// 把文件字节按文件响应语义写入 res 并结束响应:设置 Content-Type / ETag /
// Accept-Ranges,再依据请求头决定 200 全量、304 命中缓存、206 分片或 416。
func applyFileResponse(res: HttpResponse, data: Array<UInt8>, contentType: String): Unit {
    res.headers["Content-Type"] = contentType
    res.headers["Accept-Ranges"] = "bytes"
    let etag = computeETag(data)
    res.headers["ETag"] = etag

    // 没有请求上下文时(如单元测试直接调用),无从读取条件/Range 头,直接发整体。
    let req = match (res.req) {
        case Some(r) => r
        case None =>
            res.bodyBytes = Some(data)
            res.finished = true
            return
    }

    // 条件请求:If-None-Match 命中当前 ETag 则回 304(空体,见 serializeResponse
    // 对 304 的处理:既不发 body 也不发 Content-Length)。ETag 头保留在响应里。
    match (req.header("if-none-match")) {
        case Some(inm) =>
            if (etagMatches(inm, etag)) {
                res.status(304)
                res.body = ""
                res.bodyBytes = None
                res.finished = true
                return
            }
        case None => ()
    }

    // Range 分片请求。
    match (req.header("range")) {
        case Some(rangeHeader) =>
            match (parseRange(rangeHeader, data.size)) {
                case RangeOk(start, end) =>
                    res.status(206)
                    res.headers["Content-Range"] = "bytes ${start}-${end}/${data.size}"
                    res.bodyBytes = Some(sliceBytes(data, start, end + 1))
                    res.finished = true
                    return
                case RangeUnsatisfiable =>
                    res.status(416)
                    res.headers["Content-Range"] = "bytes */${data.size}"
                    res.bodyBytes = Some(Array<UInt8>())
                    res.finished = true
                    return
                case RangeIgnore => ()
            }
        case None => ()
    }

    // 无条件命中、无可用 Range:发送完整内容(200)。
    res.bodyBytes = Some(data)
    res.finished = true
}

// 依据内容算出一个强 ETag(形如 "<size>-<h1>-<h2>")。这里用两个不同质数/模数的
// 多项式滚动哈希拼接以降低碰撞;中间量始终落在 Int64 安全范围内,不会溢出。
// 不是加密级强度,但作为缓存校验「内容是否变化」足够。
func computeETag(data: Array<UInt8>): String {
    var h1: Int64 = 0
    var h2: Int64 = 0
    for (b in data) {
        h1 = (h1 * 31 + Int64(b)) % 1000000007
        h2 = (h2 * 131 + Int64(b)) % 998244353
    }
    return "\"" + toHexLower(data.size) + "-" + toHexLower(h1) + "-" + toHexLower(h2) + "\""
}

// If-None-Match 头与给定 ETag 是否匹配:支持通配 "*" 与逗号分隔的多个候选;
// 比较时忽略弱校验前缀 "W/"。
func etagMatches(headerVal: String, etag: String): Bool {
    let v = headerVal.trimAscii()
    if (v == "*") {
        return true
    }
    let target = stripWeak(etag)
    for (part in v.split(",")) {
        if (stripWeak(part.trimAscii()) == target) {
            return true
        }
    }
    return false
}

// 去掉 ETag 可能带的弱校验前缀 "W/"。
func stripWeak(tag: String): String {
    if (tag.startsWith("W/")) {
        return tag[2..tag.size]
    }
    return tag
}

// 解析单段 Range 头(只支持单区间;多区间一律忽略、退回整体)。total 为内容总长。
// 支持三种写法:
//   bytes=start-end  指定起止(end 越界则截到末尾)
//   bytes=start-     从 start 到末尾
//   bytes=-suffix    末尾 suffix 个字节
func parseRange(header: String, total: Int64): RangeResult {
    let h = header.trimAscii()
    if (!h.startsWith("bytes=")) {
        return RangeIgnore
    }
    let spec = h[6..h.size]
    // 多区间(含逗号)或空说明:不处理,照发整体。
    if (spec.isEmpty() || spec.contains(",")) {
        return RangeIgnore
    }
    let (a, b) = splitOnce(spec, "-")
    let aStr = a.trimAscii()
    let bStr = b.trimAscii()

    if (aStr.isEmpty()) {
        // 形如 "-N":请求末尾 N 个字节。
        if (bStr.isEmpty()) {
            return RangeIgnore
        }
        let n = parseInt(bStr)
        if (n <= 0) {
            return RangeUnsatisfiable
        }
        var start = total - n
        if (start < 0) {
            start = 0
        }
        if (total == 0) {
            return RangeUnsatisfiable
        }
        return RangeOk(start, total - 1)
    }

    // 形如 "start-" 或 "start-end"。
    let start = parseInt(aStr)
    if (start >= total) {
        return RangeUnsatisfiable
    }
    var end = if (bStr.isEmpty()) {
        total - 1
    } else {
        parseInt(bStr)
    }
    if (end >= total) {
        end = total - 1
    }
    if (end < start) {
        return RangeUnsatisfiable
    }
    return RangeOk(start, end)
}

// 把一个非负整数转为小写十六进制字符串(0 返回 "0")。
func toHexLower(value: Int64): String {
    if (value <= 0) {
        return "0"
    }
    let digits = "0123456789abcdef"
    var n = value
    var s = ""
    while (n > 0) {
        let d = n % 16
        s = digits[d..(d + 1)] + s
        n = n / 16
    }
    return s
}

// 从文件路径中取出文件名部分(同时兼容 "/" 与 "\\" 两种分隔符)。
func basename(path: String): String {
    var s = path
    let bySlash = s.split("/")
    s = bySlash[bySlash.size - 1]
    let byBackslash = s.split("\\")
    s = byBackslash[byBackslash.size - 1]
    return s
}
