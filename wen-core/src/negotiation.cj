package wen

import std.collection.*
import std.convert.*

/*
 * 内容协商(Accept 头解析与最佳匹配)。
 *
 * 这里把 Accept 头解析成若干「媒体类型 + 质量值 q」的条目,并提供一个核心函数
 * acceptMatch:给定一个具体的 "type/subtype",在这些条目里找出与之匹配、且最「合适」
 * 的那一条,返回它的 (q, 具体程度 rank, 在头中的位置 index)。
 *
 * 匹配的具体程度(rank)分三档:精确相等(2)> "type/*"(1)> "*/*"(0)。挑选最佳
 * 类型时的优先级为:q 越大越好;q 相同则 rank 越大越好;再相同则在 Accept 头中出现
 * 得越靠前越好(更贴近客户端的偏好顺序)。q 为 0 表示「明确不接受」。
 */

// 一条 Accept 条目:小写的媒体类型(如 "text/html"、"text/*"、"*/*")及其质量值。
class AcceptItem {
    let mediaType: String
    let q: Float64

    init(mediaType: String, q: Float64) {
        this.mediaType = mediaType
        this.q = q
    }
}

// 解析 Accept 头(逗号分隔;每项可带 ";q=..." 等参数)。空白项会被跳过。
func parseAcceptHeader(raw: String): ArrayList<AcceptItem> {
    let list = ArrayList<AcceptItem>()
    for (part in raw.split(",")) {
        let seg = part.trimAscii()
        if (seg.isEmpty()) {
            continue
        }
        // 媒体类型与其后的参数以 ";" 分隔;媒体类型是第一段。
        let pieces = seg.split(";")
        let mediaType = pieces[0].trimAscii().toAsciiLower()
        if (mediaType.isEmpty()) {
            continue
        }
        var q = 1.0
        var i = 1
        while (i < pieces.size) {
            let (k, v) = splitOnce(pieces[i].trimAscii(), "=")
            if (k.trimAscii().toAsciiLower() == "q") {
                q = parseQ(v.trimAscii())
            }
            i += 1
        }
        list.add(AcceptItem(mediaType, q))
    }
    return list
}

// 解析质量值 q,夹到 [0, 1];无法解析时按 1.0 处理。
func parseQ(s: String): Float64 {
    try {
        var q = Float64.parse(s)
        if (q < 0.0) {
            q = 0.0
        }
        if (q > 1.0) {
            q = 1.0
        }
        return q
    } catch (_: Exception) {
        return 1.0
    }
}

// 在解析好的 Accept 条目中,为具体类型 full("type/subtype")找出最合适的匹配,
// 返回 (q, rank, index)。rank < 0 表示没有任何条目匹配它。
func acceptMatch(full: String, items: ArrayList<AcceptItem>): (Float64, Int64, Int64) {
    let (mainType, _) = splitOnce(full, "/")
    var bestRank = -1
    var bestQ = 0.0
    var bestIdx = 0
    var idx = 0
    for (item in items) {
        var rank = -1
        if (item.mediaType == full) {
            rank = 2
        } else if (item.mediaType == "${mainType}/*") {
            rank = 1
        } else if (item.mediaType == "*/*") {
            rank = 0
        }
        if (rank >= 0) {
            // 取更具体的;具体程度相同时取 q 更大的(并据此记录其在头中的位置)。
            // 说明:rank 跨级比较时不看 q,所以 rank 高 q=0 可能覆盖 rank 低 q=1。
            // 这一不对称对**外部**调用方不可见 — request.cj 的 accepts/accepts([...]) 都
            // 额外用 `q > 0.0` 兜底,q=0 的候选不会被当作"匹配"。改成"rank 高 q=0 视为
            // rank=-1"会让代码绕弯,以"调用方兜底"的契约保留现状。
            if (rank > bestRank || (rank == bestRank && item.q > bestQ)) {
                bestRank = rank
                bestQ = item.q
                bestIdx = idx
            }
        }
        idx += 1
    }
    return (bestQ, bestRank, bestIdx)
}

// 通用的 Accept-* 协商:从 offered 候选里挑出客户端最偏好的一个。用于 Accept-Charset /
// Accept-Encoding / Accept-Language —— 它们的取值是简单 token(charset 名 / 编码名 /
// 语言标签),而非 type/subtype 媒体类型。
//   header        —— 对应的 Accept-* 头;None 表示该头缺失,视为「全部可接受」,返回首个候选。
//   languageMode  —— 为 true 时启用语言前缀匹配(头里的 "en" 可匹配候选 "en-US")。
//   encodingMode  —— 为 true 时启用 Accept-Encoding 特例:"identity" 默认可接受,
//                    除非被 "identity;q=0" 或 "*;q=0" 显式排除。
// 返回最佳候选;都不可接受(q 全为 0 / 被排除)时返回 None。候选并列时取列表中靠前者。
func negotiateAccept(header: ?String, offered: Array<String>, languageMode: Bool, encodingMode: Bool): ?String {
    if (offered.isEmpty()) {
        return None
    }
    let raw = match (header) {
        case Some(h) => h
        case None => return Some(offered[0])
    }
    let items = parseAcceptHeader(raw)
    var best: ?String = None
    var bestQ = 0.0
    var bestSpec = -1
    for (cand in offered) {
        let (q, spec) = acceptTokenScore(cand, items, languageMode, encodingMode)
        if (spec >= 0 && q > 0.0) {
            var better = false
            match (best) {
                case None => better = true
                case Some(_) =>
                    if (q > bestQ) {
                        better = true
                    } else if (q == bestQ && spec > bestSpec) {
                        better = true
                    }
            }
            if (better) {
                best = Some(cand)
                bestQ = q
                bestSpec = spec
            }
        }
    }
    return best
}

// 为单个候选 token 在已解析的 Accept 条目里打分,返回 (q, 具体程度 spec)。
// spec:2 精确相等 > 1 语言前缀 > 0 通配 "*";-1 表示无任何匹配。
func acceptTokenScore(offered: String, items: ArrayList<AcceptItem>, languageMode: Bool, encodingMode: Bool): (Float64, 
    Int64) {
    let o = offered.toAsciiLower()
    var bestQ = 0.0
    var bestSpec = -1
    for (item in items) {
        let m = item.mediaType
        var spec = -1
        if (m == o) {
            spec = 2
        } else if (m == "*") {
            spec = 0
        } else if (languageMode && o.startsWith(m + "-")) {
            spec = 1
        }
        if (spec >= 0) {
            if (spec > bestSpec || (spec == bestSpec && item.q > bestQ)) {
                bestSpec = spec
                bestQ = item.q
            }
        }
    }
    // Accept-Encoding 特例:未被提及的 identity 默认可接受(给一个最低优先级兜底)。
    if (bestSpec < 0 && encodingMode && o == "identity") {
        return (1.0, 0)
    }
    return (bestQ, bestSpec)
}
