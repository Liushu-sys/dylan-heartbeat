# Dylan Heartbeat 项目文档

> 一个连接 Kelivo（AI 聊天客户端）与 DeepSeek API 的智能网关，集成主动唤醒与日记功能。
> 维护者：Codex | 最后更新：2026-07-24

---

## 一、项目背景与用户需求

### 1.1 背景
用户使用 **Kelivo**（一款 iOS 上的 AI 聊天客户端）与 AI（女朋友角色名为"SY"）对话。Kelivo 本身支持直接对接 DeepSeek API，但无法满足以下需求：

- 每次换 WiFi 网络（宿舍 → 家 → 校园网）都需要改 IP 地址
- 没有主动唤醒机制——AI 不能主动发消息
- 无法记录聊天时间戳，用于判断何时该主动联系
- 无法通过 Bark 推送接收 AI 主动发出的消息
- 对话历史、日记等功能分散在不同平台

### 1.2 核心需求
| 需求 | 说明 |
|------|------|
| **统一网关** | 搭建一个中间服务，Kelivo 所有请求先走网关，再转发给 DeepSeek |
| **主动唤醒** | 长时间不聊天时，AI 自动通过 Bark 推送发消息"找你" |
| **固定地址** | 不管在哪都能用，不需要每次换网络改配置 |
| **时间追踪** | 记录最后一次聊天时间，作为唤醒判断依据 |
| **日记功能** | AI 自行判断是否要写日记，自动保存到服务器 |
| **消息识别** | 让 AI 知道自己发出了什么 Bark 推送，避免重复推送 |
| **推理模式** | 支持 DeepSeek 的推理模式选择（轻度/中度/深度） |
| **全天候运行** | Mac 关机/断网不影响服务，24 小时在线 |

### 1.3 整体架构

```
用户手机（Kelivo App）
    │  HTTPS 请求（待配 HTTPS）
    ▼
云服务器（阿里云香港 47.82.159.182:3000）
    │
    ├── Gateway（server.js）
    │     ├── 接收 Kelivo 请求（/v1/chat/completions + /chat/completions）
    │     ├── 提取消息 + 注入 Bark 事件
    │     ├── 记录时间戳到 enhanced_messages.json（最近 50 条）
    │     ├── 转发请求到 DeepSeek API
    │     ├── 返回回复给 Kelivo（SSE 流式/JSON）
    │     ├── 代理 DeepSeek 余额查询
    │     └── 提供 Bark 推送头像（/avatar.jpg）
    │
    ├── Wake-up（wake_up.js）
    │     ├── 定时检查 enhanced_messages.json
    │     ├── 调用 DeepSeek 生成唤醒消息
    │     ├── 通过 Bark API 推送到手机
    │     ├── 保存日记（[DIARY]标签提取）
    │     └── 记录唤醒事件回 enhanced_messages.json
    │
    └── 管理页面（/admin）
          ├── 查看服务状态（gateway / wake-up）
          ├── 修改唤醒间隔等配置
          ├── 修改模型、API Key、Bark 设置
          └── 查看日记内容
```

---

## 二、核心配置与操作逻辑

### 2.1 服务器部署

**云服务器配置：**
- 服务商：阿里云（国际站）
- 地域：香港（免备案）
- 规格：2 核 1G，30G 流量/月
- 费用：28 元/月
- 镜像：Ubuntu 22.04+
- 公网 IP：`47.82.159.182`
- 防火墙（安全组）：已开放端口 22（SSH）和 3000（网关）

**服务管理：**
- 使用 PM2 进程管理
- 两个进程：`gateway`（server.js）和 `wake-up`（wake_up.js）
- PM2 已配置 `pm2 save` + `pm2 startup`，服务器重启后自动恢复

**常用 PM2 命令：**
```bash
pm2 status                          # 查看两个服务状态
pm2 logs gateway --lines 30         # 查看网关日志
pm2 logs wake-up --lines 30         # 查看唤醒日志
pm2 restart gateway                 # 重启网关
pm2 restart wake-up                 # 重启唤醒服务
pm2 restart gateway --update-env    # 修改 .env 后重启（重载环境变量）
pm2 delete gateway && pm2 start server.js --name gateway  # 完全重载
```

**部署命令：**
```bash
scp /Users/liushujun/Documents/heartbeat/server.js root@47.82.159.182:/root/dylan-heartbeat/
scp /Users/liushujun/Documents/heartbeat/wake_up.js root@47.82.159.182:/root/dylan-heartbeat/
ssh -o StrictHostKeyChecking=no root@47.82.159.182 "cd /root/dylan-heartbeat && pm2 restart gateway"
```

### 2.2 网关核心逻辑（server.js）

**路由结构：**

| 路由 | 方法 | 用途 |
|------|------|------|
| `/v1/chat/completions` | POST | 主要聊天接口，转发到 DeepSeek |
| `/chat/completions` | POST | 兼容 Kelivo 的备用路由 |
| `/v1/models` | GET | 返回可用模型列表 |
| `/v1/dashboard/billing/subscription` | GET | 代理 DeepSeek 余额查询 |
| `/v1/dashboard/billing/usage` | GET | 代理 DeepSeek 用量查询 |
| `/v1/user/balance` | GET | Kelivo 余额查询（在 onRequest 钩子中拦截处理） |
| `/admin` | GET | 管理页面（Basic Auth 保护） |
| `/admin/save` | POST | 保存配置 |
| `/internal/wake-event` | POST | wake_up.js 记录唤醒事件 |
| `/internal/heartbeat` | POST | wake_up.js 心跳 |
| `/test-bark` | GET | 测试 Bark 推送 |
| `/avatar.jpg` | GET | 返回 Bark 推送头像图片 |

**聊天处理流程（`chatHandler` 函数）：**
```
1. 从 req.body 提取 messages
2. 注入 Bark 事件到对话上下文（读取 enhanced_messages.json 中的 assistant 事件）
3. 记录最后一条用户消息到 enhanced_messages.json（加 UTC+0 时间戳，最多 50 条）
4. 转发完整请求到 DeepSeek API（透传所有参数，包括 reasoning_effort）
5. 检测响应是否为 SSE 流式（以 "data:" 开头）
   - 是 SSE → 通过 reply.raw 直通原始流数据
   - 不是 SSE → 解析 JSON 后 reply.send(data)
```

**鉴权流程（onRequest 钩子）：**
```
/admin → 直接放行（后续 Basic Auth 校验）
/v1/user/balance → 在钩子中拦截并代理到 DeepSeek（不经过路由）
公网 /v1/* 请求 → 需要 GATEWAY_API_KEY 验证
带任何 Authorization Bearer token 的请求 → 放行
其他 → 403 Forbidden
```

### 2.3 用户侧配置

**Kelivo 客户端设置：**
- 供应商分类：**DeepSeek**（选 DeepSeek 才能显示推理模式选择器）
- API Base URL：`http://47.82.159.182:3000/v1`（待升级为 HTTPS）
- API Key：`sk-gw-yhjnskyebsjagdubskn`
- 模型名：自定义（如 `deepseek-v4-flash`、`deepseek-reasoner` 等）

**Bark APP 配置（iOS）：**
- 已配置推送 key，Bark 通知正常工作
- 推送标题固定为 **S**
- 推送头像使用 HTTPS 图床链接（https://s41.ax1x.com/2026/07/24/pmg4mM4.jpg）

### 2.4 环境变量（.env）

```env
# DeepSeek API
TARGET_API_URL=https://api.deepseek.com/v1/chat/completions
TARGET_API_KEY=sk-97bbf363d7f74ec8b51893a7c643b334
MODEL_NAME=deepseek-chat

# 网关鉴权
GATEWAY_API_KEY=sk-gw-yhjnskyebsjagdubskn
ALLOW_PUBLIC_API=true

# Bark 推送
BARK_KEY=sR9H88tqYYNHzwa378uJmj
PUSH_PROVIDER=bark
CUSTOM_ICON_URL=https://s41.ax1x.com/2026/07/24/pmg4mM4.jpg

# 唤醒配置
DAY_WAKE_AFTER_MINUTES=60
NIGHT_WAKE_AFTER_MINUTES=9999
DAY_CHECK_INTERVAL_MINUTES=10
NIGHT_CHECK_INTERVAL_MINUTES=9999
WAKE_DAY_START_HOUR=8
WAKE_DAY_END_HOUR=2

# 管理页面
ADMIN_USER=admin
ADMIN_PASSWORD=adminsysj020605

# 其他
PORT=3000
TIME_ZONE=Asia/Shanghai
DIARY_ENABLED=true
DIARY_DIR=diary
WEATHER_ENABLED=false
```

---

## 三、目前达成的功能总结

### ✅ 已稳定运行

| 功能 | 状态 | 说明 |
|------|------|------|
| **聊天转发** | ✅ | Kelivo → 网关 → DeepSeek → 回复返回 |
| **SSE 流式直通** | ✅ | DeepSeek 流式回复正确处理 |
| **推理模式** | ✅ | Kelivo 界面可选轻度/中度/深度推理 |
| **余额查询** | ✅ | 代理 DeepSeek 真实余额接口 |
| **24h 云服务器** | ✅ | Mac 关机/断网不影响，28 元/月 |
| **公网访问** | ✅ | 手机数据流量/WiFi 均可连接 |
| **API Key 鉴权** | ✅ | 防止未授权访问 |
| **时间戳记录** | ✅ | 每次聊天自动记录到 enhanced_messages.json |
| **Bark 主动唤醒** | ✅ | 长时间不聊天 → AI 生成消息 → 推送手机 |
| **唤醒内容智能生成** | ✅ | AI 基于最近对话决定发什么消息 |
| **Bark 事件注入** | ✅ | AI 知道自己推送过什么，避免重复 |
| **推送标题固定** | ✅ | 统一显示为 "S" |
| **推送头像** | ✅ | HTTPS 图床链接，Bar 通知带头像 |
| **日记功能** | ⚠️ | wake_up 可写可存；网关聊天需在 Kelivo 记忆/提示词中手动添加日记规则 |
| **管理页面** | ✅ | Web 界面查看状态、改配置、看日记 |
| **PM2 自动恢复** | ✅ | 服务器重启后服务自动启动 |

### 📋 本地存储文件

| 文件 | 路径 | 说明 |
|------|------|------|
| `server.js` | `/root/dylan-heartbeat/server.js` | 网关主程序 |
| `wake_up.js` | `/root/dylan-heartbeat/wake_up.js` | 自动唤醒服务 |
| `.env` | `/root/dylan-heartbeat/.env` | 环境配置 |
| `enhanced_messages.json` | `/root/dylan-heartbeat/enhanced_messages.json` | 聊天记录（最近 50 条） |
| `ntfy_priority.js` | `/root/dylan-heartbeat/ntfy_priority.js` | 推送优先级辅助 |
| `diary/*.md` | `/root/dylan-heartbeat/diary/` | 日记文件（按日期命名） |
| `avatar.jpg` | `/root/dylan-heartbeat/avatar.jpg` | Bark 推送头像图片 |

### 📌 待办/待完善

| 事项 | 优先级 | 状态 | 说明 |
|------|--------|------|------|
| **日记自动保存（网关聊天）** | 中 | ⏳ 待 Codex 修改 server.js | 在 Kelivo 聊天时 AI 写的 [DIARY] 标签需要网关自动提取并保存到 diary 文件夹 |
| **HTTPS 加密** | 中 | ⏳ 等待域名审核 | 域名 `sysylll.top` 已购买（14元/年），阿里云实名认证审核中。审核通过后装 Caddy 配 Let's Encrypt 证书。届时 Kelivo 地址改为 `https://sysylll.top:443/v1` |
| **SSH 密钥登录** | 低 | ❌ 可选加固 | 替代密码登录，更安全。当前密码 `bYwku0-dantyx-qozgiq` 足够复杂，非刚需 |

### 🔧 常见维护操作

```bash
# 查看服务状态
pm2 status

# 查看网关日志
pm2 logs gateway --lines 30

# 查看唤醒日志
pm2 logs wake-up --lines 30

# 重启服务
pm2 restart gateway
pm2 restart wake-up

# 修改配置后重启
pm2 restart gateway --update-env

# 完全重载（代码修改后）
pm2 delete gateway && cd /root/dylan-heartbeat && pm2 start server.js --name gateway

# 部署新代码
scp server.js root@47.82.159.182:/root/dylan-heartbeat/
ssh root@47.82.159.182 "cd /root/dylan-heartbeat && pm2 restart gateway"
```

### 🔐 安全说明

当前数据安全状态：
- 传输加密：**HTTP 明文**（HTTPS 待配。配之前，公共场所 WiFi 下有人用 Wireshark 可能抓包看到内容。自家/数据流量下基本安全。）
- 服务器登录：**密码登录**（密码足够复杂，暴力破解需数百年）
- API 鉴权：**Bearer Token 验证**（外部无法直接调用接口）
- 数据存储：**明文 JSON 文件**（阿里云运维人员理论上可访问，但实际上无人会查看普通用户数据）

---

## 四、下一任 Codex 交接说明

### 4.1 待完成功能

**任务 1：网关添加日记提取与保存**
在 `chatHandler` 函数中，在 DeepSeek 返回响应后，检查响应文本中是否包含 `[DIARY]...[/DIARY]` 标签。如果包含，提取内容并追加到 `/root/dylan-heartbeat/diary/{日期}.md` 文件中。参考 `wake_up.js` 中 `appendDiaryEntry()` 函数的实现（约第 76 行）。

**任务 2：配置 HTTPS（域名通过后）**
等域名 `sysylll.top` 实名认证通过后：
1. 登录服务器安装 Caddy
2. 配置 Caddyfile 反向代理到 localhost:3000
3. 修改防火墙开放 443 端口
4. 更新 Kelivo 地址为 `https://sysylll.top/v1`

### 4.2 关键代码位置

| 逻辑 | 文件 | 行号（近似） |
|------|------|------------|
| dotenv 加载 | `server.js` | 第 1 行（含 override: true） |
| onRequest 拦截器 | `server.js` | ~500-540 行 |
| 余额查询拦截 | `server.js` | ~502-514 行 |
| 聊天处理函数 | `server.js` | ~536-610 行 |
| Bark 事件注入 | `server.js` | ~565-582 行 |
| 日记路由`/avatar.jpg` | `server.js` | ~1722-1730 行 |
| 管理页面 | `server.js` | ~740-850 行 |
| app.listen | `server.js` | ~1725 行 |
| Bark 推送函数 | `wake_up.js` | ~94-150 行 |
| 日记标签提取 | `wake_up.js` | ~63-88 行 |
| 唤醒主循环 | `wake_up.js` | ~500-600 行 |
| 管理页配置项 | `server.js` | ~1200-1400 行（HTML 表单） |

### 4.3 服务器连接信息

```
IP:      47.82.159.182
SSH:     ssh -o StrictHostKeyChecking=no root@47.82.159.182
密码:     bYwku0-dantyx-qozgiq（管理页密码已改为 adminsysj020605）
系统:    Ubuntu 22.04+
管理页:  http://47.82.159.182:3000/admin（账号 admin / 密码 adminsysj020605）
```

---

*文档生成时间：2026-07-24 | 由 Codex 维护*
