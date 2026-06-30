package wen

import std.collection.*

/*
 * 精确路由的 trie 索引。
 *
 * 设计取向:**trie 是「快速圈出候选 layer」的过滤器,不替代 Layer 抽象本身**。
 *   - 注册一条精确路由(get/post/...) 时:除入 layers 外,把它的 layerIndex 沿 pattern
 *     的段序列插入到 trie 中,叶子节点的 endpoints 收集。
 *   - 派发请求时:走 trie 拿到候选 layerIndex 集合,真正的参数捕获 / caseSensitive /
 *     strict 校验仍由 PathPattern.matchExact 二次完成。
 *
 * 因为是「过滤器」,trie 容忍**假阳**(候选实际不匹配会被 matchExact 丢弃),但绝不能有
 * **假阴**(漏命中)。两条由此推出来的实现细节:
 *   - literal 段始终按 lowercase 比较存入 trie;caseSensitive=true 由 matchExact 二次保证。
 *   - 参数段的正则约束**不**在 trie 里校验,仅作为「占位」存在,具体 :param/正则 / :param?
 *     / 通配 * 的语义全部交给 matchExact。
 *
 * 中间件(isPrefix=true)与错误层(isError=true)不进 trie——前者顺序敏感、由 Router 顺序
 * 扫描;后者无路径语义、按全局错误流水线处理。
 */
class RouteNode {
    // 字面量子节点:key 为段的 lowercase 形式。
    let literal: HashMap<String, RouteNode> = HashMap<String, RouteNode>()
    // 参数子节点:同一位置允许多条不同 :param 路由并存(如 /:id 与 /:slug),各占一个 slot。
    let paramSlots: ArrayList<ParamSlot> = ArrayList<ParamSlot>()
    // 通配段(*)直接收 layer 索引——* 已吞掉剩余路径,后续不再有段。
    let wildcardEndpoints: ArrayList<Int64> = ArrayList<Int64>()
    // 在本节点恰好结束的 layer 索引(按插入顺序)。
    let endpoints: ArrayList<Int64> = ArrayList<Int64>()
}

class ParamSlot {
    let node: RouteNode
    init() {
        this.node = RouteNode()
    }
}

// 把一条精确路由的 layerIndex 沿 pattern 段序列插入 trie。可选段(:param?)会同时
// 插入「跳过该段」与「带该段」两条路径,以保证 walk 时无需特殊回溯。
func insertRouteIntoTrie(root: RouteNode, segments: ArrayList<Segment>, layerIndex: Int64): Unit {
    insertFrom(root, segments, 0, layerIndex)
}

func insertFrom(node: RouteNode, segments: ArrayList<Segment>, si: Int64, layerIndex: Int64): Unit {
    if (si >= segments.size) {
        node.endpoints.add(layerIndex)
        return
    }
    let seg = segments[si]
    match (seg.kind) {
        case Wildcard => node.wildcardEndpoints.add(layerIndex)
        case Param =>
            // 可选段:同时插「跳过本段」路径(继续在当前 node 上递归剩余段)。
            if (seg.optional) {
                insertFrom(node, segments, si + 1, layerIndex)
            }
            // 「带该段」路径:新增/复用一个 slot。简化:总是新建 slot,匹配开销略增
            // 但语义最干净——不同 :param 名 / 正则的 layer 各走各的子树。
            let slot = ParamSlot()
            node.paramSlots.add(slot)
            insertFrom(slot.node, segments, si + 1, layerIndex)
        case Literal =>
            let key = seg.value.toAsciiLower()
            let child = match (node.literal.get(key)) {
                case Some(c) => c
                case None =>
                    let c = RouteNode()
                    node.literal[key] = c
                    c
            }
            insertFrom(child, segments, si + 1, layerIndex)
    }
}

// 在 trie 上收集所有可能匹配该请求路径的 layer 索引。结果由 PathPattern.matchExact 二次验证。
// 同一 layer 可能通过多条路径命中(literal vs :param、可选段插入了两次),用 seen 去重。
func collectTrieCandidates(root: RouteNode, parts: Array<String>): ArrayList<Int64> {
    let out = ArrayList<Int64>()
    let seen = HashSet<Int64>()
    walkTrie(root, parts, 0, out, seen)
    return out
}

func walkTrie(node: RouteNode, parts: Array<String>, pi: Int64, out: ArrayList<Int64>, seen: HashSet<Int64>): Unit {
    // 通配段:无论当前在哪个位置,都吞掉剩余路径,直接收候选。
    for (e in node.wildcardEndpoints) {
        if (!seen.contains(e)) {
            seen.add(e)
            out.add(e)
        }
    }
    if (pi >= parts.size) {
        // 路径走完:本节点的 endpoints 全部入候选。可选段的"跳过"分支已由 insertFrom
        // 在祖先 endpoints 中铺好,这里只需取本节点。
        for (e in node.endpoints) {
            if (!seen.contains(e)) {
                seen.add(e)
                out.add(e)
            }
        }
        return
    }
    // 字面量优先于参数段 — literal 子节点先处理,param slots 后处理。
    // 这样 out 里字面量路由的 layerIdx 会排在前面,二次 matchExact 过滤时能更快
    // 匹配(虽然 matchExact 会准确过滤,但候选集越大,遍历成本越高)。
    let key = parts[pi].toAsciiLower()
    match (node.literal.get(key)) {
        case Some(child) => walkTrie(child, parts, pi + 1, out, seen)
        case None => ()
    }
    // 各 :param 候选 slot 都试一次。
    for (slot in node.paramSlots) {
        walkTrie(slot.node, parts, pi + 1, out, seen)
    }
}
