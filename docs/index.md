---
title: Wen 文档
description: 仓颉(Cangjie)Express 风格 Web 框架 — 官方文档
---

# Wen 文档

**Wen**(文)—— 一个用华为仓颉(Cangjie)编程语言编写的、**面向原生高性能**的
Express 风格 Web 框架。**纯标准库、零第三方依赖**,API 贴近 Express,**路由用
trie 索引(O(M),M 是请求路径段数)**。

仓库地址:[github.com/mtpkiss/wen](https://github.com/mtpkiss/wen)

## 文档导航

- [快速上手](getting-started.md) — 安装、第一个程序、workspace 拆分(`wen` / `wen_contrib`)
- [内置中间件参考](middleware.md) — `logger` / `helmet` / `csrf` / `cors` / `basicAuth` /
  `bearerAuth` / `requestId` / `methodOverride` 等
- [API 参考](api.md) — 核心类型、路由、请求/响应、流式、文件、会话、ETag
- [Session 存储扩展指南](session-store-extensions.md) — 生产环境 session 存储自定义

## 项目状态

当前版本:**0.4.0**(1.0 锁定就绪)。完整历史见仓库根的
[`CHANGELOG.md`](https://github.com/mtpkiss/wen/blob/main/CHANGELOG.md);
路线图见 [`ROADMAP.md`](https://github.com/mtpkiss/wen/blob/main/ROADMAP.md)。

## 适用范围

**适用**:任意规模的 RESTful / JSON API 与服务端渲染业务,部署模型为
「前置反代 + plain HTTP 应用进程」(Nginx / Caddy / k8s ingress 终止 TLS)。

**不在覆盖范围**(由反代或专门库负责):TLS / HTTP/2、响应压缩、限流 / WAF、
WebSocket、超大文件流式上传、多层代理头防护。详见
[README](https://github.com/mtpkiss/wen#定位与边界)。
