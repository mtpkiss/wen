package wen

/*
 * Plugin system.
 *
 * A plugin encapsulates a feature that wants to extend the application: it can
 * register middleware, add routes, or read/modify settings during install.
 * Plugins are registered with `app.register(plugin)`.
 *
 * Two styles are supported:
 *   1. Implement the `Plugin` interface (stateful / configurable plugins).
 *   2. Pass a plain `Middleware` to `app.use(...)` (the built-in middleware
 *      factories in `wen.middleware` use this style).
 */
public interface Plugin {
    func install(app: Application): Unit
}
