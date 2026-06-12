package wen

import std.collection.*
import std.fs.*

/*
 * 视图渲染:内置的极简模板引擎与视图路径/扩展名解析辅助。
 *
 * res.render(name, data) 最终会落到 Application.renderView:它根据 "views" 设置
 * 定位模板文件、根据扩展名(或 "view engine" 设置)选择引擎,再把数据交给引擎渲染。
 * 用户可用 app.engine(ext, fn) 接入任意第三方引擎;未注册时一律回退到这里的
 * simpleViewEngine。
 *
 * simpleViewEngine 只做一件事:把模板里的 {{ key }} 占位符替换成数据中对应字段的
 * 标量值。key 支持用 "." 逐层取嵌套对象字段(如 {{ user.name }});取到的值默认做
 * HTML 转义以防注入,找不到的键替换为空串。它刻意保持极简——需要条件/循环/局部
 * 模板等能力时,请用 app.engine 接入功能更全的引擎。
 */

// 内置极简模板引擎:读取模板文件并对其做 {{ key }} 插值。
public func simpleViewEngine(path: String, data: JsonValue): String {
    let tmpl = String.fromUtf8(File.readFrom(path))
    return renderTemplate(tmpl, data)
}

// 对模板字符串做 {{ key }} 替换。遇到未闭合的 {{ 时原样保留,不报错。
func renderTemplate(tmpl: String, data: JsonValue): String {
    var out = ""
    var rest = tmpl
    while (true) {
        match (rest.indexOf("{{")) {
            case Some(i) =>
                out += rest[0..i]
                let after = rest[(i + 2)..rest.size]
                match (after.indexOf("}}")) {
                    case Some(j) =>
                        let key = after[0..j].trimAscii()
                        out += htmlEscape(lookupScalar(data, key))
                        rest = after[(j + 2)..after.size]
                    case None =>
                        // 没有配对的 "}}":把已吞掉的 "{{" 原样补回,剩余内容照常输出。
                        out += "{{"
                        rest = after
                }
            case None =>
                out += rest
                break
        }
    }
    return out
}

// 按 "." 分段在数据中逐层向下取字段,把最终的标量值转成字符串。任一段缺失、或最终
// 值不是标量(是对象/数组/null)时返回空串。
func lookupScalar(data: JsonValue, key: String): String {
    var cur = data
    for (part in key.split(".")) {
        match (cur.get(part)) {
            case Some(v) => cur = v
            case None => return ""
        }
    }
    return scalarToString(cur)
}

// 把 JSON 标量值转成用于插值的字符串(字符串取其内容,数字取词法,布尔取
// true/false);非标量返回空串。
func scalarToString(v: JsonValue): String {
    match (v.asString()) {
        case Some(s) => return s
        case None => ()
    }
    match (v.asBool()) {
        case Some(b) => return if (b) { "true" } else { "false" }
        case None => ()
    }
    match (v.asInt()) {
        case Some(n) => return n.toString()
        case None => ()
    }
    match (v.asFloat()) {
        case Some(f) => return f.toString()
        case None => ()
    }
    return ""
}

// 对字符串做 HTML 转义(& < > " '),防止把数据当成标签注入。按字节处理:这五个
// 特殊字符都是 ASCII,UTF-8 多字节序列的字节均 > 127,不会与之冲突,可原样透传。
func htmlEscape(s: String): String {
    let out = ArrayList<UInt8>()
    for (b in s.toArray()) {
        if (b == UInt8(38)) {            // &
            appendBytes(out, "&amp;")
        } else if (b == UInt8(60)) {     // <
            appendBytes(out, "&lt;")
        } else if (b == UInt8(62)) {     // >
            appendBytes(out, "&gt;")
        } else if (b == UInt8(34)) {     // "
            appendBytes(out, "&quot;")
        } else if (b == UInt8(39)) {     // '
            appendBytes(out, "&#39;")
        } else {
            out.add(b)
        }
    }
    return String.fromUtf8(out.toArray())
}

func appendBytes(out: ArrayList<UInt8>, s: String): Unit {
    for (b in s.toArray()) {
        out.add(b)
    }
}

// 把视图目录与文件名拼成路径(顺带剥掉目录开头的 "./",因为 std.fs 不处理它)。
func joinViewPath(dir: String, file: String): String {
    let d = if (dir.startsWith("./")) {
        dir[2..dir.size]
    } else {
        dir
    }
    if (d.isEmpty() || d == ".") {
        return file
    }
    if (d.endsWith("/")) {
        return d + file
    }
    return d + "/" + file
}

// 取文件名的扩展名(最后一个 "." 之后的部分,且只看 basename);没有扩展名或以 "."
// 结尾时返回 None。
func fileExt(name: String): ?String {
    let base = basename(name)
    let bytes = base.toArray()
    var i = bytes.size - 1
    while (i >= 0) {
        if (bytes[i] == UInt8(46)) {     // '.'
            // 位于开头的点(隐藏文件,如 ".bashrc")不算扩展名分隔符;结尾的点
            // 也不算(无实际扩展名)。其余位置才视为扩展名起点。
            if (i == 0 || i == bytes.size - 1) {
                return None
            }
            return Some(base[(i + 1)..base.size])
        }
        i -= 1
    }
    return None
}

// 规范化扩展名:去掉可能的前导 "."(让 app.engine("html") 与 app.engine(".html") 等价)。
func normalizeExt(ext: String): String {
    if (ext.startsWith(".")) {
        return ext[1..ext.size]
    }
    return ext
}
