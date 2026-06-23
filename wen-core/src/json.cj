package wen

import std.collection.*
import std.convert.*

/*
 * 极简、零依赖的 JSON 值类型 + 解析器 + 序列化器。
 *
 * 替换缝（REPLACEMENT SEAM）
 * --------------------------
 * 这个文件是整个框架中唯一"知道 JSON 是怎么回事"的地方——所有与 JSON 编解码相关
 * 的细节都被封装在这里。Wen 的其余部分只依赖以下三样东西：
 *   - `JsonValue` 类型（以及配套的 `JsonObj` 构建器）
 *   - `parseJson(text): JsonValue`（把文本解析成 JSON 值）
 *   - `JsonValue.toJsonString(): String`（把 JSON 值序列化回文本）
 * 此外还有两个薄包装 `res.json(JsonValue)` 与 `req.json()`，它们只是在 HTTP 层
 * 转调上面这三样东西，本身不含 JSON 逻辑。
 *
 * "替换缝"的设计意图：日后若想换用官方的 `stdx.encoding.json`，只需重写本文件，
 * 框架别处的任何调用点都无需改动。具体有两条路可走：
 *   1) 适配器（adapter）方案——保持上述这几个签名不变，在内部把它们委托给 stdx，
 *      即在 stdx 的 JsonValue 之上包一层适配，对外仍暴露本文件定义的接口；
 *   2) 类型别名（re-alias）方案——直接把本文件的 `JsonValue` 重新别名为 stdx 的
 *      对应类型，再调整这里少数几个构造器与访问器的实现去对接 stdx。
 * 无论选哪条路，关键在于"对外契约（这三个签名 + 两个薄包装）保持稳定"，因此框架
 * 中没有任何一处调用点会因为底层实现的替换而发生改变。
 */

// 当输入不是格式良好（well-formed）的 JSON 时抛出此异常。
public class JsonException <: Exception {
    public init(msg: String) {
        super("JSON: ${msg}")
    }
}

// 一个 JSON 值。JSON 规定的六种值类型在这里用枚举的各个分支表示：null、布尔、
// 数字、字符串、数组、对象。其中对象（JsonObject）刻意用"有序的键值对列表"而非
// 哈希表来保存成员：这样就能严格保持成员的插入顺序，从而使序列化结果具有确定性
// （deterministic），并且"解析 -> 序列化"能可预期地保序往返（round-trip）。
//
// **1.0 锁定说明**:本想把 enum 限同包可见(只暴露访问器 / 工厂),让未来加分支
// 不破坏 SemVer — 但 `public type ViewEngine = (String, JsonValue) -> String`
// 等公开类型契约要求用户必须持有 JsonValue,仓颉的 enum 公开则分支必公开,语言
// 层面无法既保 public 又隐藏分支。最稳的退路是**文档化"用户应优先用访问器,
// 不要 match 分支"**,使来日加 JsonBigInt 等分支时只破坏 match-fall-through 用户,
// 不破坏访问器用户。
public enum JsonValue {
    | JsonNull
    | JsonBool(Bool)
    | JsonNumber(String) // 数字以原始词法字面量（lexeme）形式逐字保留，不做数值化转换，避免精度/格式丢失
    | JsonString(String)
    | JsonArray(ArrayList<JsonValue>)
    | JsonObject(ArrayList<(String, JsonValue)>)

    // ---- 带类型的访问器（类型不匹配时返回 None） ----------------

    public func asString(): ?String {
        match (this) {
            case JsonString(s) => Some(s)
            case _ => None
        }
    }

    public func asBool(): ?Bool {
        match (this) {
            case JsonBool(b) => Some(b)
            case _ => None
        }
    }

    public func asInt(): ?Int64 {
        match (this) {
            case JsonNumber(n) => try {
                Some(Int64.parse(n))
            } catch (_: Exception) {
                None
            }
            case _ => None
        }
    }

    public func asFloat(): ?Float64 {
        match (this) {
            case JsonNumber(n) => try {
                Some(Float64.parse(n))
            } catch (_: Exception) {
                None
            }
            case _ => None
        }
    }

    public func isNull(): Bool {
        match (this) {
            case JsonNull => true
            case _ => false
        }
    }

    // 按键取对象成员，返回第一个匹配的值；若当前不是对象或找不到该键则返回 None。
    public func get(key: String): ?JsonValue {
        match (this) {
            case JsonObject(pairs) =>
                for ((k, v) in pairs) {
                    if (k == key) {
                        return Some(v)
                    }
                }
                return None
            case _ => return None
        }
    }

    // 按下标取数组元素；若当前不是数组、或下标越界则返回 None。
    public func at(i: Int64): ?JsonValue {
        match (this) {
            case JsonArray(items) =>
                if (i >= 0 && i < items.size) {
                    return Some(items[i])
                }
                return None
            case _ => return None
        }
    }

    // 返回数组的元素个数或对象的成员个数；对其他类型一律返回 0。
    public func size(): Int64 {
        match (this) {
            case JsonArray(items) => items.size
            case JsonObject(pairs) => pairs.size
            case _ => 0
        }
    }

    // 按插入顺序返回对象的所有键；若当前不是对象则返回空列表。
    public func keys(): ArrayList<String> {
        let out = ArrayList<String>()
        match (this) {
            case JsonObject(pairs) => for ((k, _) in pairs) {
                out.add(k)
            }
            case _ => ()
        }
        return out
    }

    // ---- 序列化 ------------------------------------------------------

    // 递归地把当前 JSON 值序列化成紧凑（无多余空白）的 JSON 文本。
    // 关键点：对象按"有序键值对列表"逐项输出，因此输出顺序与当初的插入/解析顺序
    // 完全一致，保证保序与确定性；数字分支直接原样吐出保留的词法字面量；字符串与
    // 键都经过 escapeJsonInto 做必要的转义后再用双引号包裹。
    //
    // 实现要点：递归过程统一向同一个 ArrayList<UInt8> 字节缓冲追加，**不再做任何
    // String 拼接**——历史实现里大量 `out += "..."` 在嵌套对象/长数组上会触发
    // O(N²) 的中间字符串复制，字节缓冲方案改成线性 O(N) 一次性 fromUtf8。
    public func toJsonString(): String {
        let out = ArrayList<UInt8>()
        appendJsonInto(out)
        return String.fromUtf8(out.toArray())
    }

    // 把当前值的紧凑 JSON 编码直接追加到字节缓冲。供 toJsonString 与所有嵌套
    // 子节点共用同一段缓冲，避免子树各自构造 String 再拼接。
    func appendJsonInto(out: ArrayList<UInt8>): Unit {
        match (this) {
            case JsonNull => appendAscii(out, "null")
            case JsonBool(b) => if (b) {
                appendAscii(out, "true")
            } else {
                appendAscii(out, "false")
            }
            case JsonNumber(n) => appendAscii(out, n)
            case JsonString(s) =>
                out.add(UInt8(34)) // "
                escapeJsonInto(out, s)
                out.add(UInt8(34))
            case JsonArray(items) =>
                out.add(UInt8(91)) // [
                var first = true
                for (it in items) {
                    if (!first) {
                        out.add(UInt8(44)) // ,
                    }
                    it.appendJsonInto(out)
                    first = false
                }
                out.add(UInt8(93)) // ]
            case JsonObject(pairs) =>
                out.add(UInt8(123)) // {
                var first = true
                for ((k, v) in pairs) {
                    if (!first) {
                        out.add(UInt8(44))
                    }
                    out.add(UInt8(34))
                    escapeJsonInto(out, k)
                    out.add(UInt8(34))
                    out.add(UInt8(58)) // :
                    v.appendJsonInto(out)
                    first = false
                }
                out.add(UInt8(125)) // }
        }
    }
}

// 把字符串的 UTF-8 字节逐个追加到 out。本框架的 JSON 输出里这条路径只用于
// 已知不含需转义字符的字面量（数字词法、true/false/null），所以不再二次判定。
func appendAscii(out: ArrayList<UInt8>, s: String): Unit {
    for (b in s.toArray()) {
        out.add(b)
    }
}

// ---- 构建器 -------------------------------------------------------------

// 一组便捷的重载工厂函数，把仓颉的原生值快速包装成对应的 JsonValue 分支。
// 注意数字一律先 toString() 成词法字面量再存入 JsonNumber，与上面"逐字保留"的
// 设计保持一致。
public func jsonOf(v: String): JsonValue {
    return JsonString(v)
}

public func jsonOf(v: Int64): JsonValue {
    return JsonNumber(v.toString())
}

public func jsonOf(v: Float64): JsonValue {
    return JsonNumber(v.toString())
}

public func jsonOf(v: Bool): JsonValue {
    return JsonBool(v)
}

public func jsonNull(): JsonValue {
    return JsonNull
}

public func jsonArray(items: ArrayList<JsonValue>): JsonValue {
    return JsonArray(items)
}

// 符合人体工学的"有序对象"链式构建器，可链式调用并最终 build：
// JsonObj().put("id", 42).put("name", "a").build()
// 内部用与 JsonObject 相同的"有序键值对列表"存放成员，因此 put 的先后顺序就是
// 最终序列化时的输出顺序。多个 put 重载分别接受不同类型的值并就地完成包装。
public class JsonObj {
    let pairs = ArrayList<(String, JsonValue)>()

    public init() {}

    public func put(key: String, value: JsonValue): JsonObj {
        pairs.add((key, value));
        return this
    }
    public func put(key: String, value: String): JsonObj {
        pairs.add((key, JsonString(value)));
        return this
    }
    public func put(key: String, value: Int64): JsonObj {
        pairs.add((key, JsonNumber(value.toString())));
        return this
    }
    public func put(key: String, value: Float64): JsonObj {
        pairs.add((key, JsonNumber(value.toString())));
        return this
    }
    public func put(key: String, value: Bool): JsonObj {
        pairs.add((key, JsonBool(value)));
        return this
    }

    public func build(): JsonValue {
        return JsonObject(pairs)
    }
    public func toJsonString(): String {
        return build().toJsonString()
    }
}

// ---- 对外入口 ---------------------------------------------------

// 解析一份 JSON 文档，返回对应的 JsonValue。输入若不合法（malformed）则抛出
// JsonException。这是整个解析功能对外暴露的唯一入口，内部委托给 JsonParser。
public func parseJson(text: String): JsonValue {
    return JsonParser(text).parseDocument()
}

// ---- 转义 -------------------------------------------------------------

// 对字符串中 JSON 强制要求转义的字符进行转义，结果直接追加到字节缓冲 out；
// 合法的 UTF-8 字节原样透传。需要被转义的字符只有三类：双引号 0x22、反斜杠 0x5C、
// 控制字符 < 0x20（其中 \b\f\n\r\t 有双字符短形式，其余统一 \u00XX）。
//
// 关键优化：**绝大多数 JSON 字符串字面量（字段名、枚举、URL、纯文本）根本不含
// 需要转义的字符**。所以分两段：
//   1. 先扫一遍找出第一个需要转义的字节位置 firstEsc。这一遍每字节只做一次复合
//      判定 `b < 32 || b == 34 || b == 92`，分支极易预测（绝大多数命中"不转义"）。
//   2. 若整段都不需要转义，直接批量复制原字节；否则把 [0, firstEsc) 批量拷贝后，
//      从 firstEsc 起再走逐字节转义分支。
// 续字节（UTF-8 多字节字符的非首字节都 ≥ 0x80）自然落入"不转义"快路径，
// 因此非 ASCII 文本不会触发慢路径。
func escapeJsonInto(out: ArrayList<UInt8>, s: String): Unit {
    // **P2-R 说明**:转义入口只覆盖 RFC 8259 §7 强制要求的字符集(`< 0x20` / `"` /
    // `\`)。0x7F(DEL)在规范中是合法的、可以裸出现的 JSON 字符,某些消费方(终端 /
    // 日志着色器)会把它当控制符,但**转义会破坏与其它符合 RFC 的解析器的字节兼容性**,
    // 因此保持不转义。
    let bytes = s.toArray()
    let n = bytes.size
    var firstEsc = -1
    var i = 0
    while (i < n) {
        let b = bytes[i]
        if (b < UInt8(32) || b == UInt8(34) || b == UInt8(92)) {
            firstEsc = i
            break
        }
        i += 1
    }
    if (firstEsc < 0) {
        var j = 0
        while (j < n) {
            out.add(bytes[j])
            j += 1
        }
        return
    }
    var j = 0
    while (j < firstEsc) {
        out.add(bytes[j])
        j += 1
    }
    var k = firstEsc
    while (k < n) {
        let b = bytes[k]
        if (b == UInt8(34)) { // 双引号 "
            out.add(UInt8(92));
            out.add(UInt8(34))
        } else if (b == UInt8(92)) { // 反斜杠 \
            out.add(UInt8(92));
            out.add(UInt8(92))
        } else if (b == UInt8(8)) { // 退格 backspace -> \b
            out.add(UInt8(92));
            out.add(UInt8(98))
        } else if (b == UInt8(12)) { // 换页 form feed -> \f
            out.add(UInt8(92));
            out.add(UInt8(102))
        } else if (b == UInt8(10)) { // 换行 -> \n
            out.add(UInt8(92));
            out.add(UInt8(110))
        } else if (b == UInt8(13)) { // 回车 -> \r
            out.add(UInt8(92));
            out.add(UInt8(114))
        } else if (b == UInt8(9)) { // 制表符 -> \t
            out.add(UInt8(92));
            out.add(UInt8(116))
        } else if (b < UInt8(32)) { // 其他控制字符 -> \u00XX 六字符转义
            out.add(UInt8(92));
            out.add(UInt8(117));
            out.add(UInt8(48));
            out.add(UInt8(48))
            out.add(hexDigit(Int64(b) / 16))
            out.add(hexDigit(Int64(b) % 16))
        } else {
            out.add(b)
        }
        k += 1
    }
}

// 把 0..15 的数值转成对应的十六进制 ASCII 字符（小写）。
func hexDigit(v: Int64): UInt8 {
    if (v < 10) {
        return UInt8(48 + v) // '0'..'9'
    }
    return UInt8(97 + v - 10) // 'a'..'f'
}

// ---- 解析器 ---------------------------------------------------------------

// 一个手写的递归下降（recursive descent）解析器。整体思路：把输入字符串转成
// UTF-8 字节数组 buf，用一个游标 pos 在其上从左到右扫描；每种 JSON 语法结构
// 对应一个 parseXxx 方法，遇到嵌套（数组里套对象、对象里套数组等）时彼此递归
// 调用，从而自然地处理任意深度的嵌套结构。所有方法共享同一个 pos 游标。
class JsonParser {
    let buf: Array<UInt8>
    var pos: Int64 = 0
    // 当前嵌套深度;每进入一层 object/array 加 1,退出时减 1。超过 MAX_DEPTH 抛异常,
    // 避免攻击者用 [[[[[...]]]]] 之类的极深嵌套触发栈溢出(仓颉是否有栈保护未知,
    // 即便有也会以 SIGSEGV 形式 crash 而非可捕获 Exception)。
    var depth: Int64 = 0
    static let MAX_DEPTH: Int64 = 256

    init(text: String) {
        this.buf = text.toArray()
    }

    // 解析整份文档：先跳过前导空白，解析出顶层值，再跳过尾随空白；若之后仍有
    // 剩余内容（即一份文档里出现了多个值或多余字符），视为非法并抛异常。
    func parseDocument(): JsonValue {
        skipWs()
        let v = parseValue()
        skipWs()
        if (pos < buf.size) {
            throw JsonException("trailing content at offset ${pos}")
        }
        return v
    }

    // 返回当前游标处的字节（提升为 Int64 便于和字符码点比较）；已到输入末尾则返回 -1。
    func peek(): Int64 {
        if (pos < buf.size) {
            return Int64(buf[pos])
        }
        return -1
    }

    // 跳过 JSON 允许的空白字符：空格、制表符、换行、回车，把游标推进到下一个非空白处。
    func skipWs(): Unit {
        while (pos < buf.size) {
            let c = buf[pos]
            if (c == UInt8(32) || c == UInt8(9) || c == UInt8(10) || c == UInt8(13)) {
                pos += 1
            } else {
                break
            }
        }
    }

    // 解析单个 JSON 值：这是递归下降的"分发中枢"。根据当前首字节判断接下来是哪种
    // 值类型，再委派给对应的子解析方法。子方法在解析嵌套结构时又会回头调用本方法，
    // 形成递归。首字节无法匹配任何合法起始符时视为非法字符。
    func parseValue(): JsonValue {
        let c = peek()
        if (c < 0) {
            throw JsonException("unexpected end of input")
        }
        if (c == 123) {
            return parseObject()
        } // { 对象起始
        if (c == 91) {
            return parseArray()
        } // [ 数组起始
        if (c == 34) {
            return JsonString(parseStringRaw())
        } // " 字符串起始
        if (c == 116) {
            return parseLiteral("true", JsonBool(true))
        } // t -> true
        if (c == 102) {
            return parseLiteral("false", JsonBool(false))
        } // f -> false
        if (c == 110) {
            return parseLiteral("null", JsonNull)
        } // n -> null
        if (c == 45 || (c >= 48 && c <= 57)) {
            return parseNumber()
        } // '-' 或数字，按数字解析
        throw JsonException("unexpected character at offset ${pos}")
    }

    // 解析字面量关键字（true / false / null）：逐字节比对期望串 lit，全部吻合则
    // 推进游标并返回预置的 value，否则抛出"非法字面量"异常。
    func parseLiteral(lit: String, value: JsonValue): JsonValue {
        let lb = lit.toArray()
        var i = 0
        while (i < lb.size) {
            if (pos + i >= buf.size || buf[pos + i] != lb[i]) {
                throw JsonException("invalid literal at offset ${pos}")
            }
            i += 1
        }
        pos += lb.size
        return value
    }

    // 解析数字：从 start 起按 JSON 数字文法依次扫描——可选负号、整数部分、可选的
    // 小数部分（'.' 后跟若干数字）、可选的指数部分（'e'/'E' 后跟可选符号与数字）。
    // 解析过程只移动游标、不做数值换算，最后把扫到的整段字节切片成词法字面量原样存入
    // JsonNumber（与"逐字保留数字"的设计一致）。若结果为空或仅有一个负号则视为非法数字。
    func parseNumber(): JsonValue {
        let start = pos
        if (peek() == 45) { // 负号 -
            pos += 1
        }
        while (pos < buf.size && isDigit(buf[pos])) {
            pos += 1
        }
        if (pos < buf.size && buf[pos] == UInt8(46)) { // 小数点 .
            pos += 1
            while (pos < buf.size && isDigit(buf[pos])) {
                pos += 1
            }
        }
        if (pos < buf.size && (buf[pos] == UInt8(101) || buf[pos] == UInt8(69))) { // 指数标志 e / E
            pos += 1
            if (pos < buf.size && (buf[pos] == UInt8(43) || buf[pos] == UInt8(45))) {
                pos += 1
            } // 指数可带 + / - 符号
            while (pos < buf.size && isDigit(buf[pos])) {
                pos += 1
            }
        }
        let lex = String.fromUtf8(sliceBytes(buf, start, pos))
        if (lex.isEmpty() || lex == "-") {
            throw JsonException("invalid number at offset ${start}")
        }
        // P2-O:RFC 8259 严格校验 — 拒绝前导零("00123"/"-0123")与裸小数点(".5"/"1.")。
        // 早先实现只按词法切段、整段塞进 JsonNumber,会让序列化往返把非法 JSON 当合法吐出。
        if (!isStrictJsonNumber(lex)) {
            throw JsonException("invalid number lexeme '${lex}' at offset ${start}")
        }
        return JsonNumber(lex)
    }

    // P2-O:RFC 8259 §6 整数 / 小数 / 指数语法的严格校验:
    //   number = [ "-" ] int [ frac ] [ exp ]
    //   int    = "0" | "1"-"9" *DIGIT          (无前导零)
    //   frac   = "." 1*DIGIT                   (小数点后至少一位)
    //   exp    = ("e"|"E") [ "+"|"-" ] 1*DIGIT
    func isStrictJsonNumber(s: String): Bool {
        let bytes = s.toArray()
        if (bytes.size == 0) {
            return false
        }
        var i = 0
        if (bytes[i] == UInt8(45)) {
            i += 1
        }
        // int 段
        if (i >= bytes.size || !isDigitByte(bytes[i])) {
            return false
        }
        let intStart = i
        while (i < bytes.size && isDigitByte(bytes[i])) {
            i += 1
        }
        let intLen = i - intStart
        if (intLen > 1 && bytes[intStart] == UInt8(48)) {
            return false // 前导零
        }
        // frac 段
        if (i < bytes.size && bytes[i] == UInt8(46)) {
            i += 1
            if (i >= bytes.size || !isDigitByte(bytes[i])) {
                return false // 裸小数点
            }
            while (i < bytes.size && isDigitByte(bytes[i])) {
                i += 1
            }
        }
        // exp 段
        if (i < bytes.size && (bytes[i] == UInt8(101) || bytes[i] == UInt8(69))) {
            i += 1
            if (i < bytes.size && (bytes[i] == UInt8(43) || bytes[i] == UInt8(45))) {
                i += 1
            }
            if (i >= bytes.size || !isDigitByte(bytes[i])) {
                return false
            }
            while (i < bytes.size && isDigitByte(bytes[i])) {
                i += 1
            }
        }
        return i == bytes.size
    }

    func isDigitByte(b: UInt8): Bool {
        return b >= UInt8(48) && b <= UInt8(57)
    }

    // 解析字符串字面量（调用时当前字节必须是起始的双引号）。逐字节累积内容，遇到
    // 反斜杠则按 JSON 转义规则处理：双字符短转义（\" \\ \/ \b \f \n \r \t）直接
    // 还原成对应字节；\u 形式交给 appendUnicodeEscape 处理（含代理对）。遇到闭合
    // 双引号结束；中途到达输入末尾则报"字符串未闭合"。最终把累积的 UTF-8 字节转回字符串。
    func parseStringRaw(): String {
        pos += 1 // 跳过起始双引号 "
        let out = ArrayList<UInt8>()
        while (true) {
            if (pos >= buf.size) {
                throw JsonException("unterminated string")
            }
            let c = buf[pos]
            if (c == UInt8(34)) { // 闭合双引号 "
                pos += 1
                break
            }
            if (c == UInt8(92)) { // 反斜杠，转义序列开始
                pos += 1
                if (pos >= buf.size) {
                    throw JsonException("bad escape")
                }
                let e = buf[pos]
                if (e == UInt8(34)) {
                    out.add(UInt8(34));
                    pos += 1
                } // \" -> "
                    else if (e == UInt8(92)) {
                    out.add(UInt8(92));
                    pos += 1
                } // \\ -> \
                    else if (e == UInt8(47)) {
                    out.add(UInt8(47));
                    pos += 1
                } // \/ -> /
                    else if (e == UInt8(98)) {
                    out.add(UInt8(8));
                    pos += 1
                } // \b -> 退格
                    else if (e == UInt8(102)) {
                    out.add(UInt8(12));
                    pos += 1
                } // \f -> 换页
                    else if (e == UInt8(110)) {
                    out.add(UInt8(10));
                    pos += 1
                } // \n -> 换行
                    else if (e == UInt8(114)) {
                    out.add(UInt8(13));
                    pos += 1
                } // \r -> 回车
                    else if (e == UInt8(116)) {
                    out.add(UInt8(9));
                    pos += 1
                } // \t -> 制表符
                    else if (e == UInt8(117)) {
                    pos += 1
                    appendUnicodeEscape(out)
                } // \u 后接 4 位十六进制码点
                    else {
                    throw JsonException("invalid escape at offset ${pos}")
                }
            } else {
                out.add(c)
                pos += 1
            }
        }
        return String.fromUtf8(out.toArray())
    }

    // 处理 \u 转义：读取 4 位十六进制得到一个码元（code unit），解析代理对后，把最终
    // 码点编码成 UTF-8 字节追加到 out。
    // 代理对（surrogate pair）规则：U+D800..U+DBFF 是"高位代理"，单独出现并不是完整
    // 字符，后面必须紧跟一个形如 \uDC00..\uDFFF 的"低位代理"，两者按公式
    //   cp = 0x10000 + (high - 0xD800) * 0x400 + (low - 0xDC00)
    // 合并成一个 BMP 之外的码点。若高位代理后没有合法的低位代理（或低位越界），则按
    // 容错策略用替换字符 U+FFFD 顶替，保证解析不崩溃。
    func appendUnicodeEscape(out: ArrayList<UInt8>): Unit {
        var code = readHex4()
        if (code >= 0xD800 && code <= 0xDBFF) { // 高位代理
            if (pos + 1 < buf.size && buf[pos] == UInt8(92) && buf[pos + 1] == UInt8(117)) { // 紧跟 \u
                pos += 2
                let low = readHex4()
                if (low >= 0xDC00 && low <= 0xDFFF) { // 合法低位代理
                    code = 0x10000 + ((code - 0xD800) * 0x400) + (low - 0xDC00)
                } else {
                    code = 0xFFFD // 低位代理非法，用替换字符
                }
            } else {
                code = 0xFFFD // 缺少配对的低位代理，用替换字符
            }
        }
        encodeUtf8(code, out)
    }

    // 读取并解析紧随其后的 4 位十六进制数字，返回其整数值（即一个 UTF-16 码元）。
    // 每字节先经 isHexByte 校验:非 hex 字符必须抛 JsonException,否则 hexVal 会把
    // 它静默映射为 0,导致 "\uZZZZ" 被悄悄解析成 NUL 字符 — 是 JSON 字符串过滤
    // 链的注入入口(P1-H)。不足 4 位(提前到达输入末尾)时同样抛"非法 unicode 转义"。
    func readHex4(): Int64 {
        var v = 0
        var i = 0
        while (i < 4) {
            if (pos >= buf.size) {
                throw JsonException("bad unicode escape")
            }
            let b = buf[pos]
            if (!isHexByte(b)) {
                throw JsonException("bad unicode escape")
            }
            v = v * 16 + hexVal(b)
            pos += 1
            i += 1
        }
        return v
    }

    // 解析对象：跳过起始的 '{'，处理可能的空对象（'{}'）；否则进入循环，每轮依次读取
    // "字符串键 -> 冒号 -> 任意值"（值通过递归调用 parseValue 解析，从而支持嵌套），
    // 把键值对按出现顺序追加到 pairs（这正是保序的来源）。每对之后遇逗号则继续下一对，
    // 遇 '}' 则结束，其余字符报错。键必须是字符串。
    func parseObject(): JsonValue {
        enterNested()
        pos += 1 // 跳过 {
        let pairs = ArrayList<(String, JsonValue)>()
        skipWs()
        if (peek() == 125) { // 空对象 }
            pos += 1
            depth -= 1
            return JsonObject(pairs)
        }
        while (true) {
            skipWs()
            if (peek() != 34) { // 键必须以双引号开头
                throw JsonException("expected string key at offset ${pos}")
            }
            let key = parseStringRaw()
            skipWs()
            if (peek() != 58) { // 键与值之间的冒号 :
                throw JsonException("expected ':' at offset ${pos}")
            }
            pos += 1
            skipWs()
            pairs.add((key, parseValue())) // 递归解析值，按顺序追加，保持插入顺序
            skipWs()
            let c = peek()
            if (c == 44) {
                pos += 1
                continue
            } // 逗号 , -> 继续下一对
            if (c == 125) {
                pos += 1
                break
            } // 右花括号 } -> 对象结束
            throw JsonException("expected ',' or '}' at offset ${pos}")
        }
        depth -= 1
        return JsonObject(pairs)
    }

    // 进入一层嵌套(object / array)前调用;超过深度上限抛异常,避免极深嵌套引发栈溢出。
    func enterNested(): Unit {
        depth += 1
        if (depth > MAX_DEPTH) {
            throw JsonException("JSON nested too deeply (> ${MAX_DEPTH}) at offset ${pos}")
        }
    }

    // 解析数组：跳过起始的 '['，处理可能的空数组（'[]'）；否则进入循环，每轮递归调用
    // parseValue 解析一个元素并按顺序追加到 items（嵌套结构由递归自然处理）。每个元素
    // 之后遇逗号则继续，遇 ']' 则结束，其余字符报错。
    func parseArray(): JsonValue {
        enterNested()
        pos += 1 // 跳过 [
        let items = ArrayList<JsonValue>()
        skipWs()
        if (peek() == 93) { // 空数组 ]
            pos += 1
            depth -= 1
            return JsonArray(items)
        }
        while (true) {
            skipWs()
            items.add(parseValue()) // 递归解析元素
            skipWs()
            let c = peek()
            if (c == 44) {
                pos += 1
                continue
            } // 逗号 , -> 继续下一个元素
            if (c == 93) {
                pos += 1
                break
            } // 右方括号 ] -> 数组结束
            throw JsonException("expected ',' or ']' at offset ${pos}")
        }
        depth -= 1
        return JsonArray(items)
    }
}

// 判断一个字节是否为 ASCII 数字 '0'..'9'。
func isDigit(b: UInt8): Bool {
    return b >= UInt8(48) && b <= UInt8(57)
}

// 把 buf 的半开区间 [start, end) 复制成一个新的 Array<UInt8>；空区间返回空数组。
func sliceBytes(buf: Array<UInt8>, start: Int64, end: Int64): Array<UInt8> {
    if (end <= start) {
        return Array<UInt8>()
    }
    let out = Array<UInt8>(end - start, repeat: 0)
    var i = start
    while (i < end) {
        out[i - start] = buf[i]
        i += 1
    }
    return out
}

// 把一个 Unicode 码点编码成 UTF-8 字节序列并追加到 out。按码点范围分四档：
// < 0x80 用 1 字节；< 0x800 用 2 字节；< 0x10000 用 3 字节；其余（补充平面）用 4 字节。
// 首字节带相应的前缀位（0xC0 / 0xE0 / 0xF0），后续每个续字节都是 0x80 | 低 6 位。
func encodeUtf8(cp: Int64, out: ArrayList<UInt8>): Unit {
    if (cp < 0x80) {
        out.add(UInt8(cp))
    } else if (cp < 0x800) {
        out.add(UInt8(0xC0 | (cp >> 6)))
        out.add(UInt8(0x80 | (cp & 0x3F)))
    } else if (cp < 0x10000) {
        out.add(UInt8(0xE0 | (cp >> 12)))
        out.add(UInt8(0x80 | ((cp >> 6) & 0x3F)))
        out.add(UInt8(0x80 | (cp & 0x3F)))
    } else {
        out.add(UInt8(0xF0 | (cp >> 18)))
        out.add(UInt8(0x80 | ((cp >> 12) & 0x3F)))
        out.add(UInt8(0x80 | ((cp >> 6) & 0x3F)))
        out.add(UInt8(0x80 | (cp & 0x3F)))
    }
}
