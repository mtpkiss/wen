---
title: 更新日志
nav_order: 7
---

# 更新日志

完整版本历史与详细变更说明维护在仓库根目录的
[CHANGELOG.md](https://github.com/mtpkiss/wen/blob/main/CHANGELOG.md),按
[语义化版本](https://semver.org/lang/zh-CN/) 组织。

## 当前版本

**0.4.0** —— 1.0 锁定就绪批次。安全 / 协议级修复 + API 表面收敛,详见
[CHANGELOG 0.4.0 段](https://github.com/mtpkiss/wen/blob/main/CHANGELOG.md#040---2026-06-23--10-锁定就绪)。

## 与路线图的关系

未实现 / 待评估的能力(HTTPS、WebSocket、HTTP/2、`trust proxy` 多层语义等)见
[ROADMAP.md](https://github.com/mtpkiss/wen/blob/main/ROADMAP.md)。

## 升级 0.4.0 的破坏性变更摘要

- `HttpResponse.headers` 改 **case-insensitive**;原 `res.headers[k] = v` 直接索引写
  迁移到 `res.set(k, v)`(framework 内部 18 处已迁移)
- `HttpServer` 的 `maxBodySize` / `readTimeoutMs` / `maxConnections` / `maxHeaderBytes`
  4 个字段降级为同包可见;用户配置统一走 `app.xxx`,极少数直接 `HttpServer(app)` +
  改字段的用户代码需迁移
- 13 个内部工具函数(`reasonPhrase` / `splitOnce` / `trimWs` 等)去 public;若直接调用过
  请改用 [API 参考](./api.md) 中已锁定的工具集
- 7 个可选中间件(`helmet` / `csrf` / `cors` / `basicAuth` / `bearerAuth` / `logger` /
  `requestId` / `methodOverride`)从 core 迁到 `wen_contrib` 子包;现有依赖需 cjpm.toml
  增加 [wen_contrib 依赖](./getting-started.md#安装)、`import wen_contrib.*`

完整破坏性变更清单与迁移路径见 CHANGELOG 0.4.0 段的 "破坏性" 子节。
