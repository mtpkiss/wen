package wen

import std.collection.*
import std.fs.*
import std.time.*

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
    | RangeOk(Int64, Int64) // 合法区间 [start, end](闭区间,含两端)
    | RangeUnsatisfiable // 语法合法但无法满足(越界等)-> 416
    | RangeIgnore // 不识别 / 多区间 / 非法,忽略 Range,照常发整体
}

// 把文件字节按文件响应语义写入 res 并结束响应:设置 Content-Type / ETag /
// Accept-Ranges /(可选)Last-Modified,再依据请求头决定 200 全量、304 命中缓存、
// 206 分片或 416。lastModified 为已格式化好的 HTTP 日期(无则传 None)。
// 可选关键字参数 etag / sendLastModified 用于关闭对应响应头与条件请求支持(静态
// 中间件选项化时,把对应开关传到这里实现)。
func applyFileResponse(res: HttpResponse, data: Array<UInt8>, contentType: String, lastModified: ?String,
    etag!: Bool = true, sendLastModified!: Bool = true, precomputedETag!: ?String = None): Unit {
    res.set("Content-Type", contentType)
    res.set("Accept-Ranges", "bytes")
    var etagValue = ""
    if (etag) {
        // P1-11:若 caller 给了预算好的弱 ETag(static files 默认按 size + mtime 算),
        // 直接用,不再对全文做多项式 hash — 大文件 / 高并发场景下能省下整次 I/O + CPU。
        etagValue = match (precomputedETag) {
            case Some(t) => t
            case None => computeETag(data)
        }
        res.set("ETag", etagValue)
    }
    var effectiveLastModified: ?String = None
    if (sendLastModified) {
        match (lastModified) {
            case Some(lm) =>
                res.set("Last-Modified", lm)
                effectiveLastModified = Some(lm)
            case None => ()
        }
    }

    // 没有请求上下文时(如单元测试直接调用),无从读取条件/Range 头,直接发整体。
    let req = match (res.req) {
        case Some(r) => r
        case None =>
            res.bodyBytes = Some(data)
            res.finished = true
            return
    }

    // 条件请求:按规范 If-None-Match 优先于 If-Modified-Since。命中即回 304(空体,
    // 见 serializeResponse 对 304 的处理:既不发 body 也不发 Content-Length);
    // ETag / Last-Modified 头仍保留在响应里。当 etag/sendLastModified 关闭时,
    // 对应方向的条件判断也一并跳过(否则与已不发送的头部对照,语义不一致)。
    // 启用 etag 且带 If-None-Match 时,仅以 INM 判定(命中→304;不命中→照常发送,
    // 依规范不再回退 IMS);否则(未启用 etag,或无 INM)再看 If-Modified-Since。
    let inm: ?String = if (etag) {
        req.header("if-none-match")
    } else {
        None
    }
    match (inm) {
        case Some(v) =>
            if (etagMatches(v, etagValue)) {
                send304(res)
                return
            }
        case None => match (effectiveLastModified) {
            case Some(lm) => match (req.header("if-modified-since")) {
                case Some(ims) =>
                    // **P2-Q 已知约束**:严格字符串等值匹配 — 客户端在头里发"小写 gmt /
                    // 缺前导零 / 不同空白"等任意合规变体时无法命中 304。框架不内置完整
                    // HTTP-date 解析(代价不成比例);ETag 路径(If-None-Match)是首选的
                    // 强校验,如须放宽 IMS 校验请用反代缓存层。
                    if (ims.trimAscii() == lm) {
                        send304(res)
                        return
                    }
                case None => ()
            }
            case None => ()
        }
    }

    // If-Range:RFC 7233 §3.2 的条件性 Range 请求 —— 客户端意思是"我手里有旧
    // 资源,如果服务端仍是同一版本,把指定 byte-range 给我;否则把整个新资源给
    // 我"。若不实现而沿用 Range 路径,旧资源 + 新版本 byte-slice 会被客户端拼成
    // 错位字节(响应方向的缓存击穿),且越是激进缓存的客户端越容易踩。
    // 校验后不匹配时:忽略 Range,走 200 全文(由下面的兜底完成)。
    let allowRange = match (req.header("if-range")) {
        case Some(ir) => ifRangeMatches(ir, etagValue, effectiveLastModified)
        case None => true
    }

    // Range 分片请求。
    if (allowRange) {
        match (req.header("range")) {
            case Some(rangeHeader) => match (parseRange(rangeHeader, data.size)) {
                case RangeOk(start, end) =>
                    res.status(206)
                    res.set("Content-Range", "bytes ${start}-${end}/${data.size}")
                    res.bodyBytes = Some(sliceBytes(data, start, end + 1))
                    res.finished = true
                    return
                case RangeUnsatisfiable =>
                    res.status(416)
                    res.set("Content-Range", "bytes */${data.size}")
                    res.bodyBytes = Some(Array<UInt8>())
                    res.finished = true
                    return
                case RangeIgnore => ()
            }
            case None => ()
        }
    }

    // 无条件命中、无可用 Range:发送完整内容(200)。
    res.bodyBytes = Some(data)
    res.finished = true
}

// RFC 7233 §3.2 — If-Range 命中判定。If-Range 的值要么是 entity-tag,要么是 HTTP-date。
//   - entity-tag 路径(以 `"` 开头):与当前响应的 ETag 做 strict 比较(字面相等)。
//     W/ 开头(无论 Header 还是当前 ETag)一律算不匹配 —— 弱 ETag 允许语义等价但
//     字节不同,无法保证 byte-range 一致性。
//   - HTTP-date 路径(不以 `"` 或 `W/` 开头):与当前 Last-Modified 字面相等比较。
//     与 If-Modified-Since 同样使用 strict 字符串比较(见 applyFileResponse 的
//     P2-Q 已知约束):框架不内置 HTTP-date 解析,如需放宽请走反代缓存层。
// 返回 true 表示"命中、可以走 Range";false 表示"不匹配,忽略 Range 改发 200 全文"。
func ifRangeMatches(headerValue: String, currentETag: String, currentLastModified: ?String): Bool {
    let v = headerValue.trimAscii()
    if (v.startsWith("W/")) {
        return false
    }
    if (v.startsWith("\"")) {
        if (currentETag.isEmpty() || currentETag.startsWith("W/")) {
            return false
        }
        return v == currentETag
    }
    return match (currentLastModified) {
        case Some(lm) => v == lm
        case None => false
    }
}

// 回 304 Not Modified(空体)。
// 注意:framework 内部调用,直接写字段绕过 res.status() 的 finished-warn — etag 中间件
// 在 next() 之后(此时 res 已 finished)会改成 304 是合法的"晚改",而非用户错误。
// RFC 7232 §4.1 要求 304 时服务端应发送"与 200 响应相同的" cache-control/vary 等,
// 以更新缓存元数据。早前实现只设置状态码并清空 body,不补 Vary: Accept(而 200
// 路径上 format() 会自动加),导致 304 响应缺少 Vary 头,缓存层无法正确更新。
// 修法:send304 自动加上 Vary: Accept(若未存在),与 format 行为一致。
func send304(res: HttpResponse): Unit {
    res.statusCode = 304
    res.statusMessage = reasonPhrase(304)
    res.body = ""
    res.bodyBytes = None
    match (res.get("Vary")) {
        case Some(v) =>
            // 大小写不敏感检查是否已含 Accept,没有则规范化追加。
            var hasAccept = false
            for (part in v.split(",")) {
                if (part.trimAscii().toAsciiLower() == "accept") {
                    hasAccept = true
                    break
                }
            }
            if (!hasAccept) {
                res.set("Vary", "${v.trimAscii()}, Accept")
            }
        case None => res.set("Vary", "Accept")
    }
    res.finished = true
}

// 取文件最后修改时间并格式化成 HTTP 日期(用于 Last-Modified);取不到时返回 None。
func httpDateForFile(path: String): ?String {
    try {
        return Some(formatHttpDate(FileInfo(Path(path)).lastModificationTime))
    } catch (_: Exception) {
        return None
    }
}

// P1-11:基于文件 stat (size + mtime) 的弱 ETag。Express / serve-static 默认形式,
// 完全避开"读全文 → 多项式 hash"路径,对 100 MB 文件高并发尤其有用。语义保留:同
// 文件被改后,size 或 mtime 至少有一变,客户端缓存正确失效。同等 hash 强度的强 ETag
// 只在二进制内容确实可能"size+mtime 不变但字节变了"的边缘场景(如 mmap 改写)才有
// 价值,代价不成比例 — 把强 ETag 留给 etag() 中间件(动态响应)走。
func weakETagFromStat(path: String): ?String {
    try {
        let info = FileInfo(Path(path))
        let size = info.size
        let mtimeNs = info.lastModificationTime.toUnixTimeStamp().toNanoseconds()
        return Some("W/\"${size}-${mtimeNs}\"")
    } catch (_: Exception) {
        return None
    }
}

// 把一个(UTC)时间格式化为 RFC 1123 形式的 HTTP 日期,例如
// "Fri, 12 Jun 2026 00:40:55 GMT"。星期与月份取其英文全名的前三个字母作为缩写。
// **P2-D 可移植性兜底**:如果 std DayOfWeek / Month.toString() 未来变区域化(中文 /
// 全小写等),先按 toString() 取前 3 个字节;命中已知英文集就采用;否则回退到固定 ASCII
// 数组(按 enum 序号映射)。这样无论 std 如何演进,Date 头始终是 RFC 7231 要求的格式。
func formatHttpDate(t: DateTime): String {
    let dowAbbr = abbrevDayOfWeek(t)
    let monAbbr = abbrevMonth(t)
    return "${dowAbbr}, ${pad2(t.dayOfMonth)} ${monAbbr} ${t.year} " +
        "${pad2(t.hour)}:${pad2(t.minute)}:${pad2(t.second)} GMT"
}

let HTTP_DAYS: Array<String> = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
let HTTP_MONTHS: Array<String> = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]

func abbrevDayOfWeek(t: DateTime): String {
    let s = t.dayOfWeek.toString()
    if (s.size >= 3) {
        if (isAsciiAlpha(s[0..3])) {
            return s[0..3]
        }
    }
    // 回退到固定 ASCII 数组 — std 区域化时不会破坏 RFC 格式。
    match (t.dayOfWeek) {
        case Sunday => return HTTP_DAYS[0]
        case Monday => return HTTP_DAYS[1]
        case Tuesday => return HTTP_DAYS[2]
        case Wednesday => return HTTP_DAYS[3]
        case Thursday => return HTTP_DAYS[4]
        case Friday => return HTTP_DAYS[5]
        case Saturday => return HTTP_DAYS[6]
    }
}

func abbrevMonth(t: DateTime): String {
    let s = t.month.toString()
    if (s.size >= 3) {
        if (isAsciiAlpha(s[0..3])) {
            return s[0..3]
        }
    }
    match (t.month) {
        case January => return HTTP_MONTHS[0]
        case February => return HTTP_MONTHS[1]
        case March => return HTTP_MONTHS[2]
        case April => return HTTP_MONTHS[3]
        case May => return HTTP_MONTHS[4]
        case June => return HTTP_MONTHS[5]
        case July => return HTTP_MONTHS[6]
        case August => return HTTP_MONTHS[7]
        case September => return HTTP_MONTHS[8]
        case October => return HTTP_MONTHS[9]
        case November => return HTTP_MONTHS[10]
        case December => return HTTP_MONTHS[11]
    }
}

func isAsciiAlpha(s: String): Bool {
    for (b in s.toArray()) {
        let alpha = (b >= UInt8(65) && b <= UInt8(90)) || (b >= UInt8(97) && b <= UInt8(122))
        if (!alpha) {
            return false
        }
    }
    return true
}

// 把 0..99 的整数补足成两位十进制字符串。
func pad2(n: Int64): String {
    if (n < 10) {
        return "0${n}"
    }
    return n.toString()
}

// 当前 UTC 时间的 HTTP 日期字符串(用于 Date 响应头)。
func httpDateNow(): String {
    return formatHttpDate(DateTime.nowUTC())
}

// 「此刻起 seconds 秒后」的 HTTP 日期字符串(用于 Cookie 的 Expires 等)。
func httpDateAfter(seconds: Int64): String {
    return formatHttpDate(DateTime.nowUTC() + Duration.second * seconds)
}

// 若响应尚未设置 Date 头,则补上当前时间(HTTP/1.1 建议服务器发送 Date)。
func ensureDateHeader(res: HttpResponse): Unit {
    match (res.get("Date")) {
        case Some(_) => ()
        case None => res.set("Date", httpDateNow())
    }
}

// 若 res.charset 已设置且 Content-Type 中尚未包含 "charset=",则追加它。在响应实际
// 写出(serializeResponse / StreamWriter.begin)前调用一次,统一处理所有路径设置的
// Content-Type(send / json / sendFile / contentType / mimeType / 静态文件 等)。
func applyCharsetIfSet(res: HttpResponse): Unit {
    if (res.charset.isEmpty()) {
        return
    }
    match (res.get("Content-Type")) {
        case Some(ct) =>
            if (!ct.toAsciiLower().contains("charset=")) {
                res.set("Content-Type", "${ct}; charset=${res.charset}")
            }
        case None => ()
    }
}

// 依据内容算出一个强 ETag(形如 "<size>-<h1>-<h2>")。这里用两个不同质数/模数的
// 多项式滚动哈希拼接以降低碰撞;中间量始终落在 Int64 安全范围内,不会溢出。
// 不是加密级强度,但作为缓存校验「内容是否变化」足够。
//
// P1-13:旧实现 `"\"" + toHexLower(...) + "-" + ... + "\""` 多次中间字符串拷贝,
// 与 toHexLower 自身的头插 O(n²) 叠加成本可观。改为单一 ArrayList<UInt8>,3 段
// hex 直接写入同一 buffer,最后 String.fromUtf8 一次成串。
func computeETag(data: Array<UInt8>): String {
    var h1: Int64 = 0
    var h2: Int64 = 0
    for (b in data) {
        h1 = (h1 * 31 + Int64(b)) % 1000000007
        h2 = (h2 * 131 + Int64(b)) % 998244353
    }
    let out = ArrayList<UInt8>()
    out.add(UInt8(34)) // '"'
    appendHexLower(out, data.size)
    out.add(UInt8(45)) // '-'
    appendHexLower(out, h1)
    out.add(UInt8(45)) // '-'
    appendHexLower(out, h2)
    out.add(UInt8(34)) // '"'
    return String.fromUtf8(out.toArray())
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

    // 内层 parseInt 在数字超 Int64 表达范围时会抛 ArithmeticException(乘加溢
    // 出)。客户端可发 `bytes=99999999999999999999-...` 一行就把任意 sendFile /
    // staticFiles 打成 500 — RFC 7233 要求无法解析的 Range 应被忽略,这里捕获后
    // 当作 RangeIgnore 处理。
    if (aStr.isEmpty()) {
        // 形如 "-N":请求末尾 N 个字节。
        if (bStr.isEmpty()) {
            return RangeIgnore
        }
        let n = try {
            parseInt(bStr)
        } catch (_: Exception) {
            return RangeIgnore
        }
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
    let start = try {
        parseInt(aStr)
    } catch (_: Exception) {
        return RangeIgnore
    }
    if (start >= total) {
        return RangeUnsatisfiable
    }
    var end = if (bStr.isEmpty()) {
        total - 1
    } else {
        try {
            parseInt(bStr)
        } catch (_: Exception) {
            return RangeIgnore
        }
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
//
// P1-13:旧实现 `s = digits[d..] + s` 每次都重建整段字符串(头插 O(n²))。改为
// 走 appendHexLower:固定 16 字节栈临时 buf(Int64 hex 最多 16 位)倒序填,再
// 顺序追加 — 整体 O(n) 且无中间字符串拷贝。
func toHexLower(value: Int64): String {
    let buf = ArrayList<UInt8>()
    appendHexLower(buf, value)
    return String.fromUtf8(buf.toArray())
}

// 把一个非负整数的小写十六进制表示追加到 out(0/负数追加 "0")。供 computeETag /
// toHexLower 共用,避免每段 hex 各自分配中间字符串。
func appendHexLower(out: ArrayList<UInt8>, value: Int64): Unit {
    if (value <= 0) {
        out.add(UInt8(48)) // '0'
        return
    }
    let digits = "0123456789abcdef".toArray()
    // Int64.Max < 2^63 → 至多 16 位 hex。栈临时 buf 倒序填,再把有效段顺序追加。
    let buf = Array<UInt8>(16, repeat: UInt8(0))
    var n = value
    var pos = 16
    while (n > 0) {
        pos -= 1
        buf[pos] = digits[n % 16]
        n = n / 16
    }
    var i = pos
    while (i < 16) {
        out.add(buf[i])
        i += 1
    }
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
