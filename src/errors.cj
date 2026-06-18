package wen

/*
 * 「带状态码的 HTTP 异常」基类。
 *
 * 框架的默认错误兜底(router.dispatchTop / server.handleConnection)在把异常映射为
 * 响应状态码时优先识别本类型:抛出 HttpException(或其子类)即可让框架据其 status
 * 回对应状态码、以 message 作为响应体,无需为常见情形专门注册错误处理中间件。对应
 * Express 生态中 err.status / http-errors 的约定。
 *
 * 用法:
 *   throw HttpException(422, "Unprocessable Entity")
 * 或语义化封装(继承):
 *   public class NotFound <: HttpException { public init() { super(404, "Not Found") } }
 *   throw NotFound()
 *
 * 框架内置的 PayloadTooLargeException(413)/ BadRequestException(400)也继承本类,因此
 * 默认兜底用一条「HttpException -> status」规则即可统一处理三者与用户自定义异常;仍可
 * 注册错误处理中间件(ErrorHandler)完全接管,其优先于本兜底。
 */
public open class HttpException <: Exception {
    public let status: Int64
    public init(status: Int64, message: String) {
        super(message)
        this.status = status
    }
}
