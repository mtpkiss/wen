---
title: 部署指南
nav_order: 6
---

# 部署指南

`wen` 的部署模型是 **「前置反代 + plain HTTP 应用进程」**:Nginx / Caddy /
k8s ingress 在前面终止 TLS、压缩、限流、静态 CDN,wen 进程只跑 HTTP/1.1。
这是与 Express + Node 一致的主流部署形态。

不在本页覆盖的边界(TLS / HTTP/2 / WebSocket / 大文件上传等)见
[README — 定位与边界](https://github.com/mtpkiss/wen#定位与边界)。

## 一份最小 Nginx 反代

```nginx
upstream wen_app {
    server 127.0.0.1:8080;
    keepalive 32;                # 复用到 wen 的 TCP 连接,降低握手开销
}

server {
    listen 443 ssl http2;
    server_name app.example.com;

    ssl_certificate     /etc/letsencrypt/live/app.example.com/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/app.example.com/privkey.pem;

    # TLS / HTTP2 在这里终止;wen 永远只见到明文 HTTP/1.1
    # 压缩也在这里;wen 不自写 gzip / Brotli
    gzip on;
    gzip_types text/plain text/css application/json application/javascript;

    location / {
        proxy_pass http://wen_app;
        proxy_http_version 1.1;
        proxy_set_header Connection "";

        # 透传给 wen,让 req.clientIp() / req.protocol() / req.secure() 正确
        proxy_set_header Host              $host;
        proxy_set_header X-Forwarded-For   $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_set_header X-Forwarded-Host  $host;

        # 大文件上传/下载若 nginx 缓冲会拖延首字节,且压不住内存:
        proxy_request_buffering off;     # 上传:边收边转发
        proxy_buffering         off;     # 下载/SSE:不缓冲响应
        proxy_read_timeout      300s;
    }
}

# HTTP → HTTPS 重定向
server {
    listen 80;
    server_name app.example.com;
    return 301 https://$host$request_uri;
}
```

对应 wen 侧需要做的:

```cangjie
let app = wen()
app.trustProxy = true                                  // 信任 X-Forwarded-* 头
app.cookieSecret = readSecretFromEnvOrKMS()            // 不要硬编码
app.use(session())                                     // 默认 MemorySessionStore — 多实例请换 Redis 等
app.listen(8080)
```

注意 `trustProxy` 当前是 `Bool`,**假定单层反代**部署。若你的拓扑是 LB → CDN → app
多层,请在反代层自己校验或替换 `X-Forwarded-*` 头(否则攻击者可伪造 `X-Forwarded-For`
绕过 IP 限制)—— 见 [ROADMAP 中 `trust proxy` 完整语义](https://github.com/mtpkiss/wen/blob/main/ROADMAP.md)。

## HSTS preload 三步式部署

`helmet()` 默认发 HSTS `max-age=15552000`(180 天)+ `includeSubDomains`,不带 `preload`。
要把站点提交到浏览器 [HSTS preload 列表](https://hstspreload.org/) 需走完三步,**任一步都不可跳过**:

| 阶段 | 配置 | 等待 |
|---|---|---|
| 1. 起步 | `helmet()` —— 默认 180 天 HSTS,带 `includeSubDomains` 不带 `preload` | 至少 1~2 周,确认无任何混合内容 / 子域 HTTP-only 服务 |
| 2. 加长 | `helmet(hstsMaxAge: 31536000)` —— 升到 1 年 | 再观察 1~2 周 |
| 3. 提交 | `helmet(hstsMaxAge: 31536000, hstsPreload: true)` —— 加 `preload` 指令,再去 hstspreload.org 提交申请 | 提交后**不可撤销**(撤销可能耗时 1 年以上) |

> 跳到第 3 步前请确保:**所有子域**都能 HTTPS,**所有外链资源**都已迁 HTTPS。
> 一旦 preload 通过,任何子域走 HTTP 都会被浏览器直接拒绝连接。

## Graceful shutdown

`app.close(timeoutMs!: Int64 = 5000)` 优雅关闭:

- 停止接受新连接
- 等在途请求 drain 完成,或超时
- 幂等;`listen` 之前调用是 no-op

```cangjie
import std.os.posix.*   // 或对应平台的信号 API

main(): Int64 {
    let app = wen()
    // ... 注册路由 ...

    // 一个独立协程接 SIGTERM / SIGINT,触发优雅关闭
    spawn {
        waitForSignal([SIGTERM, SIGINT])
        println("[wen] shutting down, draining in-flight requests...")
        app.close(timeoutMs: 30000)          // 容器编排通常给 30s 缓冲
        println("[wen] bye")
    }

    app.listen(8080)
    return 0
}
```

> 信号 API 的具体形态以当前 cjc 标准库为准。如标准库尚未提供信号接口,可
> 通过监听 `/admin/shutdown` 端点(配 bearer auth)触发 `app.close()` 替代。

## Kubernetes 部署

`Deployment` 与 `Service` 的最小骨架:

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: wen-app
spec:
  replicas: 3                            # 多实例;session 必须用 Redis 等共享存储
  selector:
    matchLabels: { app: wen-app }
  template:
    metadata:
      labels: { app: wen-app }
    spec:
      terminationGracePeriodSeconds: 35   # 必须 ≥ app.close 的 timeoutMs + 余量
      containers:
        - name: wen
          image: registry.example.com/wen-app:0.4.0
          ports:
            - containerPort: 8080
          env:
            - name: WEN_COOKIE_SECRET
              valueFrom: { secretKeyRef: { name: wen-secrets, key: cookie-secret } }
          readinessProbe:
            httpGet: { path: /healthz, port: 8080 }
            periodSeconds: 5
            failureThreshold: 2          # 2 次失败即从 Service 摘除,流量止血快
          livenessProbe:
            httpGet: { path: /healthz, port: 8080 }
            periodSeconds: 10
            failureThreshold: 6          # 容忍偶发,避免抖动重启
          lifecycle:
            preStop:                     # 配合优雅关闭:先睡几秒等流量摘除,再让进程收 SIGTERM
              exec: { command: ["sh", "-c", "sleep 5"] }
          resources:
            requests: { cpu: 100m, memory: 64Mi }
            limits:   { cpu: 1,    memory: 256Mi }
```

`/healthz` 路由可以极简:

```cangjie
app.get("/healthz", { _, res => res.send("ok") })
```

readiness 与 liveness 用同一端点是常见做法;真要分离时,readiness 可以加上"依赖检查"
(Redis / DB 可达),liveness 保持极简,**只要进程在跑就返 200**(避免依赖抖动触发重启循环)。

## 进程 / 并发模型

- wen 是**单进程 + 内部多线程**:`app.listen(port)` 阻塞当前线程,服务器开一组 worker
  线程处理连接(每连接一线程,有 `maxConnections` 上限)
- **不要自己 fork 多进程**:同进程内 `app.locals` / `MemorySessionStore` 不可跨进程共享
- 多实例横向扩展:**反代层负载均衡**(nginx upstream / k8s Service)
- 多实例下 session / 速率限制状态等**必须用共享存储**(Redis 等);默认的内存实现仅供单实例

## 监控与日志要点

最少应该捕捉的信号:

- `wen_contrib.requestId()` + `wen_contrib.logger()` 链路,把请求 ID 透传给上游(`X-Request-Id`)
  以便日志关联;格式自定义里加 `req.clientIp()` / `res.statusCode`
- 5xx 数量与比例(异常冒泡 / handler 抛错)
- handler 耗时分布(`logger` 已带毫秒)— 关注 p99,绝对值取决于业务
- session store 命中率与 `touch` / `save` 比例(若自实现 Redis store,加上自己的 metrics)
- 反代层的 `upstream_response_time` vs `request_time` 差值 — 差值大说明响应在 nginx
  缓冲层堆积,看看是不是该关 `proxy_buffering`(SSE / 大下载场景)
