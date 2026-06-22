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

// base64 字母表(标准,RFC 4648)。
let B64_TABLE: Array<UInt8> = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/".toArray()

// 标准 base64 编码(带 "=" 填充)。
public func base64Encode(data: Array<UInt8>): String {
    let out = ArrayList<UInt8>()
    let n = data.size
    var i = 0
    while (i < n) {
        let b0 = Int64(data[i])
        let b1 = if (i + 1 < n) {
            Int64(data[i + 1])
        } else {
            0
        }
        let b2 = if (i + 2 < n) {
            Int64(data[i + 2])
        } else {
            0
        }
        let triple = (b0 << 16) | (b1 << 8) | b2
        out.add(B64_TABLE[(triple >> 18) & 0x3F])
        out.add(B64_TABLE[(triple >> 12) & 0x3F])
        if (i + 1 < n) {
            out.add(B64_TABLE[(triple >> 6) & 0x3F])
        } else {
            out.add(UInt8(61))
        } // '='
        if (i + 2 < n) {
            out.add(B64_TABLE[triple & 0x3F])
        } else {
            out.add(UInt8(61))
        }
        i += 3
    }
    return String.fromUtf8(out.toArray())
}

// 标准 base64 解码:忽略 "="、空白与非法字符。buf 始终掩到 24 位以免溢出。
public func base64Decode(s: String): Array<UInt8> {
    let out = ArrayList<UInt8>()
    var buf = 0
    var bits = 0
    for (c in s.toArray()) {
        let v = b64Val(c)
        if (v < 0) {
            continue
        }
        buf = ((buf << 6) | v) & 0xFFFFFF
        bits += 6
        if (bits >= 8) {
            bits -= 8
            out.add(UInt8((buf >> bits) & 0xFF))
        }
    }
    return out.toArray()
}

// 单个 base64 字符的数值(0..63);非 base64 字符返回 -1。
func b64Val(c: UInt8): Int64 {
    if (c >= UInt8(65) && c <= UInt8(90)) {
        return Int64(c) - 65
    } // A-Z
    if (c >= UInt8(97) && c <= UInt8(122)) {
        return Int64(c) - 97 + 26
    } // a-z
    if (c >= UInt8(48) && c <= UInt8(57)) {
        return Int64(c) - 48 + 52
    } // 0-9
    if (c == UInt8(43)) {
        return 62
    } // +
    if (c == UInt8(47)) {
        return 63
    } // /
    return -1
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

// 把一个相对路径在 root 沙箱内解析为最终路径,**保证结果绝不跳出 root**。
//
// 规则:
//   - 反斜杠归一为正斜杠(Windows 兼容)。
//   - 按 "/" 拆段,逐段处理:空段 / "." 跳过;".." 弹出栈;栈空时再弹 ".." 视为「越界」。
//   - 任何 URL-编码的穿越也会失败,因为这里只看字面字符;.. 必须以原文出现才会被识别;
//     反过来,即便客户端把 %2e%2e 解码后给到这里也会触发越界。
//   - 越界即抛异常。文件存在性由调用方自行检查(本函数不访问文件系统,纯字符串运算)。
//
// 返回值是 root + "/" + safeRel 形式的结合路径,可直接传给 std.fs(由 File.readFrom 等
// 读取)。symlink 攻击不在本函数职责范围内——若 root 内存在可写场景,部署侧应禁止用户
// 创建 symlink。
public func resolveWithinRoot(root: String, relPath: String): String {
    let normRel = normalizeRelPath(relPath)
    let r = stripTrailingSep(root)
    if (normRel.isEmpty()) {
        return r
    }
    return r + "/" + normRel
}

func normalizeRelPath(p: String): String {
    let raw = p.replace("\\", "/")
    let stack = ArrayList<String>()
    for (seg in raw.split("/")) {
        if (seg.isEmpty() || seg == ".") {
            continue
        }
        if (seg == "..") {
            if (stack.size == 0) {
                throw Exception("path escapes root sandbox: ${p}")
            }
            let idx = stack.size - 1
            stack.remove(idx..(idx + 1))
            continue
        }
        stack.add(seg)
    }
    var out = ""
    var i = 0
    for (s in stack) {
        if (i > 0) {
            out += "/"
        }
        out += s
        i += 1
    }
    return out
}

func stripTrailingSep(s: String): String {
    var t = s
    while (t.size > 0 && (t.endsWith("/") || t.endsWith("\\"))) {
        t = t[0..(t.size - 1)]
    }
    return t
}
