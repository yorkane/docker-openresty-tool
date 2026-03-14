# docker-openresty-tool

> 一个功能完备、开箱即用的 OpenResty Docker 工具镜像，集成自动 SSL（ACME/Let's Encrypt）、WebDAV、Wake-on-LAN、Mock 接口、HTTP 基础认证等扩展能力，专为生产与开发双场景设计。

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![OpenResty](https://img.shields.io/badge/OpenResty-1.25.3.2-green)](https://openresty.org)
[![Alpine](https://img.shields.io/badge/Alpine-3.20-lightgrey)](https://alpinelinux.org)

---

## 目录

- [项目简介](#项目简介)
- [架构概览](#架构概览)
- [镜像分层](#镜像分层)
- [目录结构](#目录结构)
- [内置功能](#内置功能)
- [预安装 Lua 库](#预安装-lua-库)
- [环境变量](#环境变量)
- [快速开始](#快速开始)
  - [前置条件](#前置条件)
  - [方式一：Docker Compose（推荐）](#方式一docker-compose推荐)
  - [方式二：直接 docker run](#方式二直接-docker-run)
- [macOS 本地开发注意事项](#macos-本地开发注意事项)
- [SSL 证书](#ssl-证书)
  - [生成账户密钥](#生成账户密钥)
  - [生成自签名默认证书](#生成自签名默认证书)
  - [启用 ACME 自动证书（Let's Encrypt）](#启用-acme-自动证书lets-encrypt)
- [HTTP 基础认证](#http-基础认证)
- [WebDAV 服务](#webdav-服务)
- [Wake-on-LAN（网络唤醒）](#wake-on-lan网络唤醒)
- [Mock 接口](#mock-接口)
- [自定义配置](#自定义配置)
- [从源码构建镜像](#从源码构建镜像)
  - [构建基础镜像](#构建基础镜像)
  - [构建工具镜像](#构建工具镜像)
- [调试与运维](#调试与运维)
- [已知问题与修复记录](#已知问题与修复记录)
- [许可证](#许可证)

---

## 项目简介

`docker-openresty-tool` 是基于 [OpenResty](https://openresty.org)（Nginx + LuaJIT）深度定制的 Docker 镜像。  
它在官方 OpenResty Alpine 镜像的基础上，额外集成了：

- 更全面的 Nginx 编译模块（HTTP/2、HTTP/3、WebDAV、FancyIndex 等）
- 精选的 Lua 第三方库（ACME、HTTP 客户端、模板引擎、加密库等）
- 灵活的容器启动入口（环境变量驱动配置，支持 `envsubst` 模板渲染）
- 开箱即用的应用内置脚本（WebDAV、WoL、Basic Auth、Mock）

---

## 架构概览

```
┌─────────────────────────────────────────────────────┐
│              docker-openresty-tool:latest            │
│                                                      │
│  ┌──────────────────────────────────────────────┐   │
│  │               orabase:1 (基础镜像)            │   │
│  │  Alpine 3.20 + OpenResty 1.25.3.2            │   │
│  │  + OpenSSL 1.1.1w + PCRE 8.45               │   │
│  │  + WebDAV Ext + FancyIndex                   │   │
│  │  + LuaRocks 库 + 自定义 Lua 库               │   │
│  └──────────────────────────────────────────────┘   │
│                                                      │
│  工具层（nginx/ 挂载或内置）                          │
│  ┌─────────┐  ┌──────────┐  ┌──────────────────┐   │
│  │ conf/   │  │  lua/    │  │  bins/ / site/   │   │
│  │ nginx配置│  │ Lua 脚本 │  │  辅助脚本/静态文件│   │
│  └─────────┘  └──────────┘  └──────────────────┘   │
│                                                      │
│  entrypoint.sh → envsubst 渲染配置 → openresty 启动   │
└─────────────────────────────────────────────────────┘
```

---

## 镜像分层

| 镜像 | Dockerfile | 说明 |
|------|-----------|------|
| `orabase:1` | `base.Dockerfile` | 基础层：Alpine + 编译 OpenResty 及所有依赖 |
| `yorkane/docker-openresty-tool:latest` | `Dockerfile` | 工具层：在基础镜像上叠加 nginx/ 目录及运行时 Lua 库 |

> **注意**：需先构建 `orabase:1`，再构建工具镜像。

---

## 目录结构

```
docker-openresty-tool/
├── base.Dockerfile          # 基础镜像：编译 OpenResty + Alpine 环境
├── Dockerfile               # 工具镜像：叠加 nginx/ 配置与 Lua 库
├── docker-compose.yml       # 快速启动编排文件
├── LICENSE                  # MIT 许可证
├── README.md
└── nginx/                   # 挂载到容器 /usr/local/openresty/nginx
    ├── cert/                # SSL 账户密钥存放目录（.gitignore 中）
    ├── conf/                # Nginx 配置文件
    │   ├── entrypoint.sh    # 容器启动入口脚本
    │   ├── nginx.conf       # 主配置（由 tpl.nginx.conf 渲染生成）
    │   ├── tpl.nginx.conf   # envsubst 模板，环境变量驱动
    │   ├── main80.conf      # HTTP 80 端口扩展配置
    │   ├── main443.conf     # HTTPS 443 端口扩展配置
    │   ├── stream.conf      # TCP/UDP 流代理配置
    │   ├── cert/            # 默认证书目录（default.key / default.pem）
    │   ├── default_app/     # 默认虚拟主机配置
    │   │   ├── main.conf        # 主 server 块（location 规则）
    │   │   ├── http_servers.conf# 额外 server 块（HTTP/HTTPS）
    │   │   ├── extra.conf       # 额外 location 块
    │   │   └── init_worker.lua  # worker 初始化 Lua 脚本
    │   ├── extra/           # 用户自定义扩展配置目录
    │   └── inc/             # 公共 include 片段（mime.types 等）
    └── lua/                 # Lua 脚本目录
        ├── env.lua          # 环境变量加载模块（启动时动态生成）
        ├── _env.lua         # 内部环境变量模板
        ├── init.lua         # http_init_by_lua 入口（ACME 初始化）
        ├── init_worker.lua  # init_worker_by_lua 入口
        ├── mocks.lua        # Mock 接口处理器
        ├── ngx_mock.lua     # Nginx Mock 工具模块
        └── lib/             # 内置 Lua 库
            ├── basic_auth.lua   # HTTP 基础认证
            ├── tap.lua          # 流量 Tap / 调试工具
            ├── webdav.lua       # WebDAV 处理器
            └── wol.lua          # Wake-on-LAN（网络唤醒）
```

---

## 内置功能

| 功能 | 说明 | 启用方式 |
|------|------|---------|
| **自动 HTTPS（ACME）** | 对接 Let's Encrypt，自动签发/续期证书 | `OR_ACME=true` + 配置 `init.lua` |
| **HTTP Basic Auth** | 对任意 location 开启用户名密码保护 | `OR_AUTH_USER=user:pass` |
| **WebDAV** | 将挂载目录作为 WebDAV 文件服务器 | 默认挂载数据目录到 `/webdav` |
| **FancyIndex** | 美观的目录浏览页面 | 在 location 中启用 `fancyindex on` |
| **Wake-on-LAN** | 通过 HTTP 接口远程唤醒局域网设备 | 调用 `lib/wol.lua` |
| **Mock 接口** | 快速返回 JSON/文本模拟响应 | 访问 `/mock/` 路径 |
| **健康检查端点** | `/noc.gif` 返回 200，用于 SLB 心跳 | 默认启用 |
| **流代理（Stream）** | TCP/UDP 四层代理 | `stream.conf` |
| **Gzip 压缩** | 响应体压缩，Mock 接口默认启用 | 按 location 开启 |
| **GeoIP 模块** | 地理位置识别（动态模块） | 按需加载 |

---

## 预安装 Lua 库

### 通过 LuaRocks 安装

| 库名 | 用途 |
|------|------|
| `lua-resty-http` | 非阻塞 HTTP 客户端 |
| `lua-resty-redis-connector` | Redis 连接池封装 |
| `lua-resty-template` | 高性能 Lua 模板引擎 |
| `lua-ffi-zlib` | zlib 压缩 FFI 绑定 |
| `luasocket` | TCP/UDP Socket 库 |
| `luazip` | ZIP 文件处理 |

### 手动集成的库

| 库名 | 来源 / 用途 |
|------|------------|
| `lua-resty-acme` | Let's Encrypt ACME 协议客户端 |
| `lua-resty-openssl` | OpenSSL FFI 绑定 |
| `lua-resty-lrucache` | LRU 缓存（openresty 官方） |
| `lua-resty-string` | 字符串工具（openresty 官方） |
| `lua-resty-cookie` | Cookie 解析 |
| `lua-resty-hmac` | HMAC 签名验证 |
| `lua-resty-shell` | 非阻塞 Shell 执行 |
| `lua-resty-ctxvar` | 请求上下文变量管理 |
| `luajit-iconv` | libiconv 字符编码转换 |
| `lfs_ffi` | 文件系统操作（FFI） |

> **注意**：`lua-resty-klib`（作者自研工具库）在本镜像中**未默认安装**，
> 如需使用，请手动克隆并安装：
> ```bash
> # 进入容器后执行
> cd /usr/local/openresty/lualib
> git clone https://github.com/yorkane/lua-resty-klib.git klib
> ```

---

## 环境变量

容器启动时，`entrypoint.sh` 读取以下环境变量并动态生成 Nginx 配置：

| 变量名 | 默认值 | 说明 |
|--------|--------|------|
| `NGX_PORT` | `80` | Nginx 监听端口 |
| `NGX_WORKER` | `auto` | Worker 进程数，`auto` 自动匹配 CPU 核心数 |
| `NGX_HOST` | `_` | 虚拟主机 server_name，`_` 匹配所有域名 |
| `NGX_LOG_LEVEL` | `warn` | Nginx 日志级别（debug/info/notice/warn/error/crit） |
| `NGX_LOG_FILE` | `false` | `true` 时写入文件，`false` 时输出到 stdout/stderr |
| `NGX_OVERWRITE_CONFIG` | `false` | `true` 时每次启动都重新渲染 `nginx.conf` |
| `NGX_APP` | `default_app` | 应用目录名，对应 `conf/<NGX_APP>/` |
| `OR_ACME` | _(未设置)_ | 非空时启用 ACME 自动证书 |
| `OR_AUTH_USER` | _(未设置)_ | 格式 `username:password`，启用 HTTP Basic Auth |
| `GID` | `1000` | 容器内 nginx 进程 GID |
| `UID` | `1000` | 容器内 nginx 进程 UID |

> 所有 `NGX_`、`OR_`、`OPENRESTY_` 前缀的环境变量会自动写入 `lua/env.lua`，  
> 在 Lua 脚本中通过 `require('env').变量名` 访问。

---

## 快速开始

### 前置条件

- Docker >= 20.10
- Docker Compose V2（`docker compose`）或 V1（`docker-compose`）
- 可用端口（默认 5080）

### 方式一：Docker Compose（推荐）

```bash
# 1. 克隆项目
git clone https://github.com/yorkane/docker-openresty-tool.git
cd docker-openresty-tool

# 2. 准备数据目录
mkdir -p data

# 3. 启动服务
docker compose up -d

# 4. 验证
curl http://localhost:5080/noc.gif   # → HTTP 200，健康检查
curl http://localhost:5080/mock/test # → Mock 接口测试
```

**docker-compose.yml 配置说明：**

```yaml
version: "3"
services:
  yot:
    image: yorkane/docker-openresty-tool:latest
    container_name: yot
    environment:
      - NGX_OVERWRITE_CONFIG=true   # 每次启动重新渲染配置
      - NGX_PORT=80
      - NGX_WORKER=auto
      - NGX_HOST=${NGX_HOST:-_}     # 匹配所有域名
      - NGX_LOG_FILE=false          # 日志输出到 stdout
      - NGX_LOG_LEVEL=warn
      - GID=1000
      - UID=1000
      # - OR_AUTH_USER=admin:admin  # 取消注释启用 Basic Auth
    entrypoint: ["sh", "/usr/local/openresty/nginx/conf/entrypoint.sh"]
    volumes:
      - ./data:/webdav              # WebDAV 数据目录
      - ./data:/data                # nginx 临时文件目录
      - ./nginx:/usr/local/openresty/nginx  # 挂载配置，支持热更新
    restart: unless-stopped
    ports:
      - "5080:80"
```

### 方式二：直接 docker run

```bash
docker run -d \
  --name yot \
  -p 5080:80 \
  -v $(pwd)/data:/webdav \
  -v $(pwd)/data:/data \
  -v $(pwd)/nginx:/usr/local/openresty/nginx \
  -e NGX_OVERWRITE_CONFIG=true \
  -e NGX_LOG_LEVEL=warn \
  --entrypoint sh \
  yorkane/docker-openresty-tool:latest \
  /usr/local/openresty/nginx/conf/entrypoint.sh

# 查看日志
docker logs -f yot

# 进入容器调试
docker exec -it yot sh
```

---

## macOS 本地开发注意事项

在 macOS 上通过 Docker Desktop 运行时，有以下几点需要注意：

### 1. `/data` 目录不可用

macOS 文件系统对 Docker 挂载有限制，直接挂载系统根目录 `/data` 会失败。  
请改用项目相对路径：

```yaml
volumes:
  - ./data:/webdav   # ✅ 相对路径，可写
  - ./data:/data     # ✅ nginx 临时文件目录
```

### 2. 挂载卷中的脚本权限丢失

macOS HFS+/APFS 文件系统挂载到 Linux 容器后，文件的可执行权限（`+x`）不会保留。  
这会导致 `entrypoint.sh` 无法直接作为 ENTRYPOINT 执行。

**解决方案**：在 `docker-compose.yml` 或 `docker run` 中用 `entrypoint` 字段覆盖：

```yaml
# docker-compose.yml
entrypoint: ["sh", "/usr/local/openresty/nginx/conf/entrypoint.sh"]
```

```bash
# docker run
--entrypoint sh ... /usr/local/openresty/nginx/conf/entrypoint.sh
```

### 3. 挂载 nginx 目录实现热更新

将 `./nginx` 挂载到容器内路径，修改配置后无需重建镜像，只需 reload：

```bash
docker exec yot nginx -s reload
```

---

## SSL 证书

### 生成账户密钥

ACME（自动证书）需要一个 RSA 4096 账户私钥：

```bash
openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:4096 \
  -out nginx/cert/account.key
```

### 生成自签名默认证书

用于在域名证书未就绪时提供 HTTPS 服务（占位证书）：

```bash
openssl req -newkey rsa:2048 -nodes \
  -keyout nginx/conf/cert/default.key \
  -x509 -days 365 \
  -out nginx/conf/cert/default.pem \
  -subj "/CN=your-domain.com"
```

### 启用 ACME 自动证书（Let's Encrypt）

**第一步：** 编辑 `nginx/lua/init.lua`，填写你的邮箱和域名：

```lua
local env = require('env')
if env.OR_ACME then
    require("resty.acme.autossl").init({
        tos_accepted = true,
        staging = true,            -- 建议先用 staging 测试，确认后改 false
        account_key_path = "/usr/local/openresty/nginx/cert/account.key",
        account_email = "your@email.com",          -- 替换为你的邮箱
        domain_whitelist = { "example.com" },      -- 替换为你的域名
    })
end
```

**第二步：** 启动容器时传入环境变量：

```bash
docker run -d \
  -e OR_ACME=true \
  -e NGX_HOST=example.com \
  -p 80:80 -p 443:443 \
  -v $(pwd)/nginx:/usr/local/openresty/nginx \
  yorkane/docker-openresty-tool:latest
```

> **提示**：Let's Encrypt 生产环境有频率限制，建议先用 `staging = true` 验证流程。

---

## HTTP 基础认证

通过环境变量 `OR_AUTH_USER` 开启，格式为 `用户名:密码`：

```bash
# docker-compose 方式
environment:
  - OR_AUTH_USER=admin:mysecretpassword

# docker run 方式
docker run -e OR_AUTH_USER=admin:mysecretpassword ...
```

凭据会被自动写入 `lua/env.lua`，由 `lib/basic_auth.lua` 在 Lua 层面进行校验（Base64 解码对比），无需额外的 `.htpasswd` 文件。

---

## WebDAV 服务

镜像内置 `nginx-dav-ext-module`（支持 PROPFIND、MKCOL、COPY、MOVE 等完整 WebDAV 方法），并集成了 `lib/webdav.lua` 进行权限增强处理。

**挂载数据目录：**

```yaml
volumes:
  - ./data:/webdav
```

**客户端连接（以 macOS Finder 为例）：**

1. Finder → 前往 → 连接服务器
2. 输入 `http://your-host:5080`
3. 如启用了 Basic Auth，输入对应用户名密码

**命令行测试：**

```bash
# 列出目录
curl -X PROPFIND http://localhost:5080/ -H "Depth: 1"

# 上传文件
curl -T localfile.txt http://localhost:5080/localfile.txt

# 创建目录
curl -X MKCOL http://localhost:5080/newdir/
```

---

## Wake-on-LAN（网络唤醒）

`lib/wol.lua` 提供通过 HTTP 接口向局域网设备发送 Magic Packet 的能力，适合用于远程开机场景。

在 `conf/default_app/extra.conf` 中配置对应 location，传入目标 MAC 地址即可触发网络唤醒。

---

## Mock 接口

访问 `/mock/` 路径可获得模拟响应，由 `lua/mocks.lua` 处理。  
该功能默认启用 gzip 压缩，适用于前端联调或 API 测试场景。

```bash
# 测试 Mock 接口
curl http://localhost:5080/mock/your-api-path
```

---

## 自定义配置

### 修改 Nginx 配置

1. 编辑 `nginx/conf/default_app/main.conf` 添加自定义 `location`
2. 在 `nginx/conf/default_app/http_servers.conf` 添加额外 server 块
3. 挂载 `./nginx` 目录后，修改文件并执行 reload 即时生效：

```bash
docker exec yot nginx -s reload
```

### 使用 Lua 环境变量

容器启动时，所有以 `NGX_`、`OR_`、`OPENRESTY_` 开头的环境变量会自动写入：

```
/usr/local/openresty/nginx/lua/env.lua
```

在 Lua 脚本中使用：

```lua
local env = require('env')
local host = env.NGX_HOST        -- 读取 NGX_HOST
local auth = env.OR_AUTH_USER    -- 读取 OR_AUTH_USER
```

### 添加自定义 Lua 模块

将 `.lua` 文件放入 `nginx/lua/` 或 `nginx/lua/lib/` 目录，通过 `require` 加载：

```lua
local mylib = require('lib.mymodule')
```

---

## 从源码构建镜像

### 构建基础镜像

基础镜像负责完整编译 OpenResty，构建时间较长（约 10-20 分钟）：

```bash
# 构建 orabase:1
docker build -t orabase:1 -f base.Dockerfile .
```

主要编译参数（可通过 `--build-arg` 覆盖）：

| 参数 | 默认值 | 说明 |
|------|--------|------|
| `RESTY_VERSION` | `1.25.3.2` | OpenResty 版本 |
| `RESTY_OPENSSL_VERSION` | `1.1.1w` | OpenSSL 版本 |
| `RESTY_PCRE_VERSION` | `8.45` | PCRE 版本 |
| `RESTY_J` | `8` | 并行编译线程数 |
| `RESTY_IMAGE_TAG` | `3.20` | Alpine 版本 |

**自定义版本示例：**

```bash
docker build \
  --build-arg RESTY_VERSION=1.25.3.2 \
  --build-arg RESTY_J=4 \
  -t orabase:1 -f base.Dockerfile .
```

### 构建工具镜像

```bash
docker build -t yorkane/docker-openresty-tool:latest .
```

**保存与导出（离线分发）：**

```bash
# 保存镜像为 tar 包
docker save yorkane/docker-openresty-tool:latest | gzip > dort.tar.gz

# 在目标机器上加载
docker load < dort.tar.gz
```

---

## 调试与运维

```bash
# 查看容器实时日志
docker logs -f yot

# 进入容器 Shell
docker exec -it yot sh

# 测试 HTTP 服务
curl http://127.0.0.1:5080/noc.gif

# 测试 HTTPS 服务
curl -k https://127.0.0.1:5443/

# 重载 Nginx 配置（无需重启容器）
docker exec yot nginx -s reload

# 测试 Nginx 配置语法
docker exec yot nginx -t

# 查看资源占用
docker stats yot --no-stream

# 强制重建并重启
docker rm -f yot && docker compose up -d
```

---

## 已知问题与修复记录

### Fix 1: `http_servers.conf` 中 include 路径错误

**问题**：`http_servers.conf` 中使用 `include main.conf;`，但 Nginx 的 include 路径相对于 `conf/` 目录，`main.conf` 实际位于 `conf/default_app/main.conf`，导致启动时报 `cannot open ... main.conf`。

**修复**：

```nginx
# 修复前
include main.conf;

# 修复后
include default_app/main.conf;
```

---

### Fix 2: `main.conf` 依赖未安装的 `lua-resty-klib`

**问题**：`main.conf` 的 `rewrite_by_lua_block` 中调用了 `require('klib.dump').logs()`，但 `lua-resty-klib` 在工具镜像中未默认安装，导致首页请求返回 500。

**修复**：注释掉该调试行（该行仅为请求头日志打印，不影响核心功能）：

```lua
-- require('klib.dump').logs(ngx.req.get_headers())  -- klib not bundled in this build
```

如需启用，请先手动安装 `lua-resty-klib`，参见[预安装 Lua 库](#预安装-lua-库)章节。

---

### Fix 3: macOS 挂载卷权限问题导致 entrypoint 无法执行

**问题**：在 macOS 上将 `./nginx` 挂载到容器后，`entrypoint.sh` 的可执行权限丢失，容器因 `permission denied` 无法启动。

**修复**：在 `docker-compose.yml` 中通过 `entrypoint` 字段覆盖，使用 `sh` 显式执行脚本：

```yaml
entrypoint: ["sh", "/usr/local/openresty/nginx/conf/entrypoint.sh"]
```

---

## 许可证

本项目基于 [MIT License](LICENSE) 开源。

---

> 项目地址：[https://github.com/yorkane/docker-openresty-tool](https://github.com/yorkane/docker-openresty-tool)
