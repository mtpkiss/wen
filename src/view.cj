package wen

/*
 * 视图渲染:模板路径/扩展名解析辅助。
 *
 * res.render(name, data) 最终会落到 Application.renderView:它根据 "views" 设置
 * 定位模板文件、根据扩展名(或 "view engine" 设置)选择引擎,再把数据交给引擎渲染。
 * 框架自身不内置模板引擎——用户用 app.engine(ext, fn) 注册任意引擎即可,本文件
 * 只负责拼路径与提取扩展名。
 */

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
