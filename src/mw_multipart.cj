package wen

import std.collection.*
import std.fs.*

/*
 * multipart/form-data 解析中间件(文件上传)。
 *
 * 浏览器/HTTP 客户端在上传文件时,会把请求体编码成若干「部分(part)」,用一个随机
 * 的 boundary 串分隔。每个 part 自带一小段头部(Content-Disposition 给出字段名 name,
 * 文件部分还带 filename;可选 Content-Type),空行之后是该字段的原始内容。整体形如:
 *
 *   --BOUNDARY\r\n
 *   Content-Disposition: form-data; name="title"\r\n
 *   \r\n
 *   普通文本字段的值\r\n
 *   --BOUNDARY\r\n
 *   Content-Disposition: form-data; name="avatar"; filename="a.png"\r\n
 *   Content-Type: image/png\r\n
 *   \r\n
 *   <文件的原始字节>\r\n
 *   --BOUNDARY--\r\n
 *
 * 由于文件内容是二进制,解析全程在 req.bodyBytes(原始字节)上进行,绝不经过字符串
 * 编解码,以保证图片/压缩包等上传内容逐字节完好。解析结果:
 *   - 文本字段 -> 写入 req.attributes(与 urlencodedParser 一致,用 req.attribute 取)
 *   - 文件     -> 封装成 UploadedFile 加入 req.files,用 req.file(name) 取
 */

// 一个已上传的文件。bytes 是其原始字节;可用 text() 取文本视图,或 saveTo 落盘。
public class UploadedFile {
    public let fieldName: String       // 表单字段名(Content-Disposition 的 name)
    public let filename: String        // 客户端给出的原始文件名
    public let contentType: String     // 该 part 的 Content-Type(缺省按八位字节流)
    public let bytes: Array<UInt8>     // 文件的原始字节内容

    init(fieldName: String, filename: String, contentType: String, bytes: Array<UInt8>) {
        this.fieldName = fieldName
        this.filename = filename
        this.contentType = contentType
        this.bytes = bytes
    }

    // 文件字节数。
    public func size(): Int64 {
        return bytes.size
    }

    // 按 UTF-8 把内容解释为字符串(仅适合文本文件)。
    public func text(): String {
        return String.fromUtf8(bytes)
    }

    // 把文件原始字节写入磁盘指定路径。
    public func saveTo(path: String): Unit {
        File.writeTo(path, bytes)
    }
}

// multipart/form-data 解析中间件(兼容保留)。解析现在是内置的——首次通过 req.file(name) /
// req.files 访问时自动解析(见 HttpRequest.ensureBody),本中间件已非必需,内部仅提前触发解析。
public func multipart(): Middleware {
    return { req: HttpRequest, _: HttpResponse, next: Next =>
        req.ensureBody()
        next()
    }
}

// 从 Content-Type 中取出 boundary 的值(boundary 值大小写敏感,故在原串上切取;
// 值两端可能带引号,会被去掉)。
func extractBoundary(ct: String): ?String {
    match (ct.toAsciiLower().indexOf("boundary=")) {
        case Some(i) =>
            let after = ct[(i + "boundary=".size)..ct.size]
            let (b, _) = splitOnce(after, ";")
            return Some(unquote(b.trimAscii()))
        case None => return None
    }
}

// 在 req.bodyBytes 上按 boundary 切分并解析各个 part。
func parseMultipart(req: HttpRequest, boundary: String): Unit {
    let body = req.bodyBytes
    let dash = ("--" + boundary).toArray()      // 分隔符:--BOUNDARY
    let crlf = "\r\n".toArray()
    let dashdash = "--".toArray()
    let sep = "\r\n\r\n".toArray()              // part 内的「头/体」分隔

    // 先找出所有分隔符出现的位置(包含结尾的 --BOUNDARY-- 也会命中 --BOUNDARY)。
    let occ = ArrayList<Int64>()
    var p = 0
    while (true) {
        let k = indexOfBytes(body, dash, p)
        if (k < 0) {
            break
        }
        occ.add(k)
        p = k + dash.size
    }

    var i = 0
    while (i < occ.size) {
        let afterDelim = occ[i] + dash.size
        // 分隔符后紧跟 "--" 即为结束分隔符,到此为止。
        if (bytesMatchAt(body, afterDelim, dashdash)) {
            break
        }
        if (i + 1 >= occ.size) {
            break
        }
        var regionStart = afterDelim
        var regionEnd = occ[i + 1]
        // 去掉分隔符行之后的 CRLF。
        if (bytesMatchAt(body, regionStart, crlf)) {
            regionStart += 2
        }
        // 去掉内容与下一个分隔符之间的那个 CRLF(它属于帧格式,不是内容)。
        if (regionEnd - 2 >= regionStart && bytesMatchAt(body, regionEnd - 2, crlf)) {
            regionEnd -= 2
        }
        parsePart(req, body, regionStart, regionEnd, sep)
        i += 1
    }
}

// 解析单个 part:body[start..end) 内含「头部 + \r\n\r\n + 内容」。
func parsePart(req: HttpRequest, body: Array<UInt8>, start: Int64, end: Int64, sep: Array<UInt8>): Unit {
    let headerEnd = indexOfBytes(body, sep, start)
    if (headerEnd < 0 || headerEnd >= end) {
        return                                  // 残缺 part,跳过
    }
    let headerText = String.fromUtf8(sliceBytes(body, start, headerEnd))
    let content = sliceBytes(body, headerEnd + 4, end)

    var name = ""
    var filename = ""
    var hasFilename = false
    var contentType = ""
    for (line in headerText.split("\r\n")) {
        let (k, v) = splitOnce(line, ":")
        let key = k.trimAscii().toAsciiLower()
        if (key == "content-disposition") {
            // 解析其参数,如 form-data; name="x"; filename="y"。
            for (paramRaw in v.split(";")) {
                let (pk, pv) = splitOnce(paramRaw.trimAscii(), "=")
                let pkey = pk.trimAscii().toAsciiLower()
                if (pkey == "name") {
                    name = unquote(pv.trimAscii())
                } else if (pkey == "filename") {
                    filename = unquote(pv.trimAscii())
                    hasFilename = true
                }
            }
        } else if (key == "content-type") {
            contentType = v.trimAscii()
        }
    }

    if (hasFilename) {
        // 文件部分(即便 filename 为空也按文件对待)。
        let ctype = if (contentType.isEmpty()) {
            "application/octet-stream"
        } else {
            contentType
        }
        req.files.add(UploadedFile(name, filename, ctype, content))
    } else if (!name.isEmpty()) {
        // 普通文本字段。
        req.attributes[name] = String.fromUtf8(content)
    }
}

// 在字节数组 hay 中从 from 起查找子序列 needle 的起始下标;找不到返回 -1。
func indexOfBytes(hay: Array<UInt8>, needle: Array<UInt8>, from: Int64): Int64 {
    if (needle.size == 0) {
        return -1
    }
    var i = if (from < 0) {
        0
    } else {
        from
    }
    while (i + needle.size <= hay.size) {
        var j = 0
        var ok = true
        while (j < needle.size) {
            if (hay[i + j] != needle[j]) {
                ok = false
                break
            }
            j += 1
        }
        if (ok) {
            return i
        }
        i += 1
    }
    return -1
}

// 判断 hay 在位置 pos 处是否正好等于 pat。
func bytesMatchAt(hay: Array<UInt8>, pos: Int64, pat: Array<UInt8>): Bool {
    if (pos < 0 || pos + pat.size > hay.size) {
        return false
    }
    var j = 0
    while (j < pat.size) {
        if (hay[pos + j] != pat[j]) {
            return false
        }
        j += 1
    }
    return true
}

// 去掉字符串两端成对的双引号(若有)。
func unquote(s: String): String {
    if (s.size >= 2 && s.startsWith("\"") && s.endsWith("\"")) {
        return s[1..(s.size - 1)]
    }
    return s
}
