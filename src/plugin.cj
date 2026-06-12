package wen

/*
 * 插件系统。
 *
 * 插件用于把一项「想要扩展应用能力」的功能封装起来。它的核心入口是 install
 * 方法：框架在注册插件时会把 Application 实例交给它，于是插件可以在安装阶段
 * 任意地扩展应用——注册中间件、添加路由、读取或修改应用设置等等。插件通过
 * `app.register(plugin)` 完成注册（register 内部即调用 install）。
 *
 * 框架支持两种扩展风格，按需选用：
 *   1. 实现 `Plugin` 接口：适合「有状态 / 可配置」的插件。把配置、依赖等保存
 *      在插件对象自身的字段里，install 时再据此装配，复用性和可配置性更好。
 *   2. 直接把一个普通 `Middleware` 传给 `app.use(...)`：适合无需额外状态的
 *      简单场景。`wen.middleware` 里那些内置中间件工厂正是采用这种轻量风格。
 */
public interface Plugin {
    func install(app: Application): Unit
}
