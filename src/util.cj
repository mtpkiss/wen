package wen

import std.collection.*

/*
 * 框架内部各处共用的辅助工具函数。
 */

// 返回某个 HTTP 状态码对应的标准原因短语（reason phrase），用于状态行。
// 仅覆盖框架常用的一批状态码；对未列出的状态码统一回退为通用的 "Status"。
public func reasonPhrase(code: Int64): String {
    match (code) {
        case 200 => "OK"
        case 201 => "Created"
        case 202 => "Accepted"
        case 204 => "No Content"
        case 206 => "Partial Content"
        case 301 => "Moved Permanently"
        case 302 => "Found"
        case 304 => "Not Modified"
        case 400 => "Bad Request"
        case 401 => "Unauthorized"
        case 403 => "Forbidden"
        case 404 => "Not Found"
        case 405 => "Method Not Allowed"
        case 406 => "Not Acceptable"
        case 409 => "Conflict"
        case 412 => "Precondition Failed"
        case 415 => "Unsupported Media Type"
        case 416 => "Range Not Satisfiable"
        case 422 => "Unprocessable Entity"
        case 429 => "Too Many Requests"
        case 500 => "Internal Server Error"
        case 501 => "Not Implemented"
        case 503 => "Service Unavailable"
        case _ => "Status"
    }
}

// 在字符串中 `sep` 第一次出现的位置把它切成两段。
// 返回二元组 (head, tail)：head 是分隔符之前的部分，tail 是分隔符之后的部分
// （tail 不包含分隔符本身）。
// 如果字符串里根本不含 `sep`，则返回 (原串, "")，即 tail 为空串。
// 由于只在“第一个”分隔符处切分，因此 tail 中即便再出现 `sep` 也会被原样保留，
// 适合解析 "key=value"（value 里可能再含 "="）这类场景。
public func splitOnce(s: String, sep: String): (String, String) {
    let idx = s.indexOf(sep)
    match (idx) {
        case Some(i) =>
            let head = s[0..i]
            let tail = s[(i + sep.size)..s.size]
            return (head, tail)
        case None => return (s, "")
    }
}

// 去除字符串首尾的 ASCII 空白字符。仅对 trimAscii 的一层薄封装，
// 提供一个语义更直白的名字供框架其它地方调用。
public func trimWs(s: String): String {
    return s.trimAscii()
}

// 判断 `list` 中是否已经包含 `value`（按字符串相等逐个比较）。
// 命中即返回 true，遍历完仍未找到则返回 false。
public func listContains(list: ArrayList<String>, value: String): Bool {
    for (item in list) {
        if (item == value) {
            return true
        }
    }
    return false
}

// 返回字符串中最后一个 "." 的下标;不存在则返回 -1。用于在 "<value>.<sig>" 形式
// 的签名 Cookie 中,从右侧切出签名部分(value 自身可以包含 ".")。
public func lastIndexOfDot(s: String): Int64 {
    let bytes = s.toArray()
    var i = bytes.size - 1
    while (i >= 0) {
        if (bytes[i] == UInt8(46)) {
            return i
        }
        i -= 1
    }
    return -1
}

// 把一个路径按 "/" 拆分成若干非空的路径段，自动丢弃因前导/末尾/连续斜杠
// 产生的空段。例如 "/a/b/" 会得到 ["a", "b"]。
public func pathSegments(path: String): Array<String> {
    let raw = path.split("/")
    let parts = ArrayList<String>()
    for (seg in raw) {
        if (!seg.isEmpty()) {
            parts.add(seg)
        }
    }
    return parts.toArray()
}
