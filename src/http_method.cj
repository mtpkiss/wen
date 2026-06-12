package wen

/*
 * HTTP 方法名常量集合。
 *
 * 这里把 GET、POST 等方法名以「大写字符串」的形式集中定义，作为整个框架内部
 * 统一使用的规范写法。之所以选用大写字符串而不是枚举：HTTP 请求行里的方法名
 * 本身就是大写 ASCII（如 "GET /path HTTP/1.1"），路由表也以这些字符串作为键，
 * 因此解析出请求方法后可以直接拿原始字符串去比较 / 查表，无需任何转换或映射，
 * 让匹配逻辑保持最简单。
 *
 * 特殊项 ALL 用通配符 "*" 表示「匹配任意方法」，供 app.all(...) 这类需要拦截
 * 所有请求方法的注册使用，它并不是一个真实的 HTTP 方法名。
 */
public class HttpMethod {
    public static const GET: String = "GET"
    public static const POST: String = "POST"
    public static const PUT: String = "PUT"
    public static const DELETE: String = "DELETE"
    public static const PATCH: String = "PATCH"
    public static const HEAD: String = "HEAD"
    public static const OPTIONS: String = "OPTIONS"
    public static const ALL: String = "*"
}
