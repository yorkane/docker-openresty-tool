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
- [ZipFS — ZIP 虚拟文件系统](#zipfs--zip-虚拟文件系统)
  - [HTTP 访问 ZIP 内容](#http-访问-zip-内容)
  - [WebDAV 透明接管](#webdav-透明接管)
  - [支持的 MIME 类型](#支持的-mime-类型)
- [Vips — 动态图片处理](#vips--动态图片处理)
  - [URL 参数说明](#url-参数说明)
  - [使用示例](#使用示例)
  - [响应头说明](#响应头说明)
- [**HTTP JSON API**](#http-json-api)
  - [目录列表 /api/ls/](#目录列表-apils)
  - [文件管理 /api/rm、/api/move、/api/mkdir、/api/upload](#文件管理-apirm-apimove-apimkdir-apiupload)
- [Wake-on-LAN（网络唤醒）](#wake-on-lan网络唤醒)
- [Mock 接口](#mock-接口)
- [自定义配置](#自定义配置)
- [从源码构建镜像](#从源码构建镜像)
  - [构建基础镜像](#构建基础镜像)
  - [构建工具镜像](#构建工具镜像)
- [测试](#测试)
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
- **动态图片处理**（libvips + lua-vips，支持裁切、缩放、格式转换）
- **ZIP 虚拟文件系统**（透过 HTTP 和 WebDAV 直接浏览和访问 ZIP 内部文件）

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
├── api.md                   # HTTP JSON API 完整接口文档 ★
├── test/
│   └── sanity_test.sh       # Sanity 测试脚本（113 个用例）
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
    │   │   ├── main.conf        # 主 server 块（location 规则，含 /img/ /zip/ /api/）
    │   │   ├── http_servers.conf# 额外 server 块（HTTP/HTTPS）
    │   │   ├── extra.conf       # 顶层扩展配置（stream 级）
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
            ├── dirapi.lua       # 目录 JSON API（/api/ls/）★新增
            ├── fileapi.lua      # 文件管理 API（/api/rm、move、mkdir、upload）★新增
            ├── preview_inject.lua # HTML 目录页媒体预览注入★新增
            ├── tap.lua          # 流量 Tap / 调试工具
            ├── vips.lua         # 动态图片处理（libvips + lua-vips）★新增
            ├── webdav.lua       # WebDAV 处理器
            ├── wol.lua          # Wake-on-LAN（网络唤醒）
            └── zipfs.lua        # ZIP 虚拟文件系统★新增
```

---

## 内置功能

| 功能 | 说明 | 启用方式 |
|------|------|---------|
| **自动 HTTPS（ACME）** | 对接 Let's Encrypt，自动签发/续期证书 | `OR_ACME=true` + 配置 `init.lua` |
| **HTTP Basic Auth** | 对任意 location 开启用户名密码保护 | `OR_AUTH_USER=user:pass` |
| **WebDAV** | 将挂载目录作为 WebDAV 文件服务器 | 默认挂载数据目录到 `/webdav` |
| **ZipFS（新）** | 通过 HTTP/WebDAV 直接浏览和访问 ZIP/CBZ 等压缩包内部文件 | 访问 `/zip/<path>.cbz/...`，`OR_ZIP_EXTS` 配置后缀，`OR_ZIPFS_TRANSPARENT` 控制开关 |
| **Vips 图片处理（新）** | 动态裁切、缩放、格式转换（libvips） | 访问 `/img/<path>?w=300&fmt=webp` |
| **目录 JSON API（新）** | 列出目录/ZIP 内容，支持分页排序，返回 JSON | `GET /api/ls/<path>`，详见 [api.md](api.md) |
| **文件管理 API（新）** | 删除、移动/改名、新建目录、上传文件 | `DELETE/POST /api/rm、/api/move、/api/mkdir、/api/upload`，详见 [api.md](api.md) |
| **媒体预览注入（新）** | 为所有 HTML 目录页自动注入👁预览按钮，支持图片/视频/音频全屏预览、键盘快捷键、删除 | 自动生效，无需配置；`lib/preview_inject.lua` |
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
| `luazip` | ZIP 文件处理（ZipFS 功能依赖） |
| `lua-vips` | libvips 图片处理绑定（Vips 功能依赖） |

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

## ZipFS — ZIP 虚拟文件系统

ZipFS 允许将 ZIP 压缩包当作一个**只读目录**来访问，无需解压即可通过 HTTP 浏览目录、下载内部文件，或通过 WebDAV 挂载后无缝透明访问。

实现模块：`nginx/lua/lib/zipfs.lua`（依赖 `luazip`）

### 支持的文件扩展名

默认支持 `zip` 和 `cbz` 两种后缀（大小写不敏感），可通过环境变量 **`OR_ZIP_EXTS`** 自定义：

| 配置方式 | 值 | 说明 |
|----------|-----|------|
| 默认（不设置） | `zip,cbz` | 同时支持 .zip 和 .cbz |
| 自定义扩展名 | `zip,cbz,cbr,epub` | 逗号分隔，大小写不敏感 |

```yaml
# docker-compose.yml
environment:
  OR_ZIP_EXTS: "zip,cbz,epub"   # 额外支持 .epub 格式（EPUB 本质上是 ZIP）
```

```bash
# 直接 docker run
docker run -e OR_ZIP_EXTS=zip,cbz,epub ...
```

> **注意**：libzip 只要能打开该文件格式（内部结构符合 ZIP 规范），扩展名就能工作。
> CBZ（漫画书格式）、EPUB（电子书）等本质上都是 ZIP。

### 透明接管开关

WebDAV 客户端访问 `.zip` / `.cbz` 等路径时，默认会被自动拦截并由 ZipFS 处理（透明接管）。可通过环境变量 **`OR_ZIPFS_TRANSPARENT`** 控制此行为：

| 变量值 | 行为 |
|--------|------|
| 未设置 / `true`（默认） | 启用透明接管：PROPFIND 返回 ZIP 内部目录树，GET/HEAD 直接在原 URL serve ZIP 内容（无重定向） |
| `false` | 禁用透明接管：`.zip` 路径作为普通 WebDAV 文件处理，`/zip/` HTTP 访问**不受影响** |

```yaml
# docker-compose.yml
environment:
  OR_ZIPFS_TRANSPARENT: "false"   # 关闭 WebDAV 透明 ZIP 接管
```

```bash
# 直接 docker run
docker run -e OR_ZIPFS_TRANSPARENT=false ...
```

> **说明**：禁用透明接管后，WebDAV 客户端看到的 `.zip` 就是一个普通文件（可下载/上传），
> 不再能直接浏览 ZIP 内部。通过 `/zip/` 前缀的直接 HTTP 访问不受此开关影响。

### HTTP 访问 ZIP 内容

URL 格式：
```
GET /zip/<webdav_root相对路径>/<zip文件名>.zip/[内部路径]
```

**示例：**

```bash
# 查看 ZIP 根目录列表（HTML 页面）
curl http://localhost:5080/zip/archives/myarchive.zip/

# 访问 ZIP 内部子目录
curl http://localhost:5080/zip/archives/myarchive.zip/images/

# 读取 ZIP 内部文件
curl http://localhost:5080/zip/archives/myarchive.zip/index.html

# 读取 ZIP 内深层文件
curl http://localhost:5080/zip/archives/myarchive.zip/docs/readme.md

# 读取 ZIP 内图片
curl -o out.png http://localhost:5080/zip/archives/myarchive.zip/images/logo.png
```

**目录列表效果（浏览器访问）：**

浏览器打开 `/zip/archives/myarchive.zip/` 会显示类 VS Code 暗色主题目录页，包含：
- 可点击的子目录和文件链接
- 文件大小信息
- 上级目录返回链接（`..`）

**响应头：**

| 响应头 | 值 | 说明 |
|--------|-----|------|
| `X-ZipFS` | `dir-listing` | 当前响应为目录列表页 |
| `X-ZipFS` | `file` | 当前响应为 ZIP 内部文件 |
| `Content-Type` | 自动推断 | 根据文件扩展名设置 |
| `Cache-Control` | `public, max-age=3600` | 文件响应 1 小时缓存 |

**404 场景：**
- ZIP 文件不存在：`/zip/archives/nonexistent.zip/` → `404`
- ZIP 内路径不存在：`/zip/archives/myarchive.zip/no-such-file.txt` → `404`

---

### WebDAV 透明接管

WebDAV 客户端（如 Finder、Cyberduck、davfs2）访问 WebDAV 服务时，如果请求路径包含 `.zip` 文件：

- **`PROPFIND` 请求** → 自动返回 ZIP 内部文件结构的 DAV XML 响应（`207 Multi-Status`），ZIP 文件看起来就像一个目录
- **`GET` / `HEAD` 请求** → 直接在原 URL 返回 ZIP 内部文件内容（无重定向，浏览器 URL 保持不变）

无需客户端做任何特殊配置，WebDAV 客户端可以像浏览普通目录一样浏览 ZIP 内容。

```bash
# WebDAV PROPFIND — ZIP 文件被当作目录返回其内容
curl -X PROPFIND http://localhost:5080/archives/myarchive.zip \
     -H "Depth: 1"
# → 207 XML，包含 ZIP 内部的所有文件和目录

# WebDAV PROPFIND Depth:0 — 仅返回 ZIP 自身信息
curl -X PROPFIND http://localhost:5080/archives/myarchive.zip \
     -H "Depth: 0"
```

---

### 支持的 MIME 类型

ZipFS 根据文件扩展名自动设置 Content-Type：

| 扩展名 | Content-Type |
|--------|-------------|
| `.html`, `.htm` | `text/html; charset=utf-8` |
| `.css` | `text/css` |
| `.js` | `application/javascript` |
| `.json` | `application/json` |
| `.png` | `image/png` |
| `.jpg`, `.jpeg` | `image/jpeg` |
| `.webp` | `image/webp` |
| `.svg` | `image/svg+xml` |
| `.pdf` | `application/pdf` |
| `.md`, `.txt` | `text/plain; charset=utf-8` |
| 其他 | `application/octet-stream` |

---

## Vips — 动态图片处理

Vips 通过 [libvips](https://www.libvips.org/) 实现高性能动态图片处理，支持缩放、裁切和格式转换，无需预生成缩略图。

实现模块：`nginx/lua/lib/vips.lua`（依赖 `lua-vips` + `libvips`）  
图片来源：与 WebDAV 共享同一个根目录（`$webdav_root` = `/webdav`）

### URL 参数说明

URL 格式：
```
GET /img/<webdav_root相对路径>?[参数]
```

| 参数 | 说明 | 示例 |
|------|------|------|
| `w` | 目标宽度（像素） | `w=400` |
| `h` | 目标高度（像素） | `h=300` |
| `fit` | 缩放模式（见下表） | `fit=cover` |
| `crop` | 先裁切再缩放，格式 `x,y,宽,高` | `crop=100,50,600,400` |
| `fmt` | 输出格式：`jpeg` \| `webp` \| `png` \| `avif` \| `gif` | `fmt=webp` |
| `q` | 质量 1–100（jpeg/webp/avif，默认 82） | `q=80` |

**`fit` 缩放模式：**

| 值 | 说明 |
|----|------|
| `contain`（默认）| 保持宽高比，缩放到 `w`×`h` 框内 |
| `cover` | 保持宽高比，缩放覆盖 `w`×`h` 框，并居中裁切 |
| `fill` | 拉伸到精确的 `w`×`h`（不保持宽高比） |
| `scale` | 按 `w` 等比例缩放（忽略 `h`） |

**快速通道（无参数时直接透传）：**

当 URL 不包含任何处理参数时，直接流式返回原始文件，不经过 libvips 处理，性能最优。

### 使用示例

```bash
# 按宽度缩放（保持比例）
curl "http://localhost:5080/img/images/photo.jpg?w=400"

# 指定宽高（contain 模式，不裁切）
curl "http://localhost:5080/img/images/photo.jpg?w=300&h=200"

# Cover 模式（覆盖填充，居中裁切）
curl "http://localhost:5080/img/images/photo.jpg?w=200&h=200&fit=cover"

# 转换格式为 WebP + 调整质量
curl "http://localhost:5080/img/images/photo.png?fmt=webp&q=75"

# 先裁切 (x=100, y=50, w=600, h=400) 再缩放到 300px 宽，输出 AVIF
curl "http://localhost:5080/img/images/photo.jpg?crop=100,50,600,400&w=300&fmt=avif&q=70"

# 等比缩放宽度
curl "http://localhost:5080/img/images/photo.jpg?w=800&fit=scale"

# 直接透传（不处理，仅返回原图）
curl "http://localhost:5080/img/images/photo.jpg"
```

**在 HTML 中使用：**

```html
<!-- 响应式缩略图，自动转 WebP -->
<img src="/img/images/banner.jpg?w=800&fmt=webp&q=80" alt="banner">

<!-- 头像正方形裁切 -->
<img src="/img/avatars/user.jpg?w=100&h=100&fit=cover" alt="avatar">

<!-- 原图 -->
<img src="/img/images/full-quality.png" alt="original">
```

### 响应头说明

| 响应头 | 示例值 | 说明 |
|--------|--------|------|
| `X-Vips` | `passthrough` | 无参数直接透传 |
| `X-Vips` | `processed` | 经过 libvips 处理 |
| `X-Vips-Size` | `200x150` | 输出图片的实际尺寸 |
| `Content-Type` | `image/webp` | 输出格式的 MIME 类型 |
| `Cache-Control` | `public, max-age=86400` | 处理后图片缓存 24 小时 |

**不可用时的降级：**

如果 lua-vips 未安装，访问带处理参数的 `/img/` 路径会返回 `503`，并附带文本说明，不会导致 nginx 崩溃。

---

## HTTP JSON API

> 📄 **完整接口文档请见 [api.md](api.md)**

镜像内置一组轻量 JSON API，所有端点均以 `/api/` 为前缀，与 WebDAV（`/`）完全隔离，互不干扰。

### 目录列表 `/api/ls/`

列出目录内容或透明浏览 ZIP 内部结构，返回 JSON，支持分页和字段排序。

```
GET /api/ls/<path>?page=1&page_size=50&sort=name&order=asc
```

```bash
# 列出根目录
curl http://localhost:5080/api/ls/

# 列出某目录，按修改时间降序
curl "http://localhost:5080/api/ls/archives?sort=mtime&order=desc"

# 直接浏览 ZIP 内部（无需解压）
curl http://localhost:5080/api/ls/archives/book.cbz/chapter1
```

| 参数 | 默认值 | 说明 |
|------|--------|------|
| `page` | `1` | 页码（从 1 开始） |
| `page_size` | `50` | 每页条数（上限 `OR_API_PAGE_SIZE_MAX`，默认 200） |
| `sort` | `name` | 排序字段：`name` \| `size` \| `mtime` \| `ctime` \| `type` |
| `order` | `asc` | 排序方向：`asc` \| `desc` |

### 文件管理 `/api/rm`、`/api/move`、`/api/mkdir`、`/api/upload`

| 方法 | 路径 | 功能 |
|------|------|------|
| `DELETE` | `/api/rm/<path>` | 删除文件或目录（目录递归删除，等同 `rm -rf`） |
| `POST` | `/api/move` | 移动/重命名，body: `{"from":"/src","to":"/dst","overwrite":true}` |
| `POST` | `/api/mkdir/<path>` | 创建目录（`mkdir -p` 语义，幂等） |
| `POST` | `/api/upload/<path>` | 上传文件（raw body，自动创建父目录，直接覆盖写） |

```bash
# 上传文件
curl -X POST http://localhost:5080/api/upload/docs/notes.txt \
     --data-binary "hello world"

# 新建多级目录
curl -X POST http://localhost:5080/api/mkdir/archives/2026/march

# 移动/改名
curl -X POST http://localhost:5080/api/move \
     -H "Content-Type: application/json" \
     -d '{"from":"/docs/draft.txt","to":"/docs/final.txt"}'

# 删除文件
curl -X DELETE http://localhost:5080/api/rm/docs/old-file.txt
```

> 所有操作均在 `/api/` 前缀下进行，不会影响 WebDAV 客户端的正常挂载与使用。  
> 环境变量 `OR_FILEAPI_DISABLE=true` 可一键关闭所有文件管理端点。

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

## 测试

项目提供完整的 sanity 测试脚本，覆盖所有核心功能：

```bash
# 确保容器已启动
docker compose up -d

# 运行测试（默认目标 http://localhost:5080）
bash test/sanity_test.sh

# 指定目标地址
bash test/sanity_test.sh http://your-host:5080
```

**测试覆盖范围（113 个用例）：**

| 测试组 | 用例数 | 覆盖内容 |
|--------|--------|---------|
| 1. Core Service Health | 3 | 健康检查 `/noc.gif`、Mock 接口 |
| 2. WebDAV Basic | 3 | PROPFIND 目录、XML 响应格式 |
| 3. ZipFS HTTP | 18 | 目录列表、各类文件读取、MIME 类型、404 场景 |
| 4. Vips 图片处理 | 20 | 缩放/裁切/格式转换/各 fit 模式/404 |
| 5. ZipFS 多后缀 | 11 | `.cbz`/`.ZIP` 目录列表、文件读取、WebDAV PROPFIND |
| 6. WebDAV ZIP 透明接管 | 6 | PROPFIND 拦截、Depth 控制、GET 直接 serve（无 302） |
| 7. OR_ZIPFS_TRANSPARENT 开关 | 4 | 关闭后透明接管停止、恢复后重新生效 |
| 8. Directory JSON API 基础 | 15 | 结构/字段/分页/404/错误/透明开关联动 |
| 9. Directory JSON API — ZIP 内部 | 9 | ZIP 根目录/子目录浏览、分页、cbz 兼容 |
| 10. Directory JSON API — 排序 | 8 | sort/order 回显、顺序验证、非法值回退 |
| 11. 文件管理 API | 17 | mkdir/upload/move/rm 完整流程、冲突/覆盖/404/405/路径穿越 |

**输出示例：**

```
=== docker-openresty-tool Sanity Tests ===
    Target: http://localhost:5080

▶ 1. Core Service Health
  ✓ Health check /noc.gif (HTTP 200)
  ✓ Mock endpoint /mock/test (HTTP 200)
  ...

▶ 4. Vips — Dynamic Image Processing
  ✓ Vips resize cover (w=100,h=100,fit=cover) (HTTP 200)
  ✓ Vips cover output 100x100 (header 'X-Vips-Size: 100x100')
  ✓ Vips format conversion to WebP (HTTP 200)
  ...

═══════════════════════════════════════
  Results: 113 passed  0 failed  0 skipped  / 113 total
═══════════════════════════════════════
```

**测试数据：**

测试脚本会自动检查 `data/` 目录，如果测试 PNG 图片或 `test_assets.zip` 不存在，会自动生成：
- `data/images/` — 4 张纯色 PNG 测试图（不同分辨率和颜色）
- `data/archives/test_assets.zip` — 包含 HTML、CSS、JSON、Markdown 和图片的测试 ZIP 包

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

### Fix 4: ZipFS `parse_zip_uri` 中 Lua 字符串查找模式错误

**问题**：`lib/zipfs.lua` 中使用 `rest:find("%.zip", 1, true)` 查找 `.zip` 扩展名。  
`true` 参数表示**纯文本（plain）搜索**，此时搜索的字面字符串是 `%.zip`（5个字符），而不是 `.zip`（4个字符），导致任何路径都无法匹配，`parse_zip_uri` 始终返回 `nil`，所有 ZIP 请求均 404。

**修复**：纯文本模式下应使用字面字符串 `".zip"` 而非 Lua 模式转义写法 `"%.zip"`：

```lua
-- 修复前（错误：plain 模式下搜索的是 "%.zip" 这 5 个字符）
local zip_end = rest:find("%.zip", 1, true)

-- 修复后（plain 模式下搜索 ".zip" 这 4 个字符）
local zip_end = rest:find(".zip", 1, true)
```

> **说明**：`str:find(pattern, init, plain)` 第 4 个参数为 `true` 时，`pattern` 被作为普通字符串处理，  
> Lua 正则转义字符（如 `%`）不再有特殊含义。`"%.zip"` 在 plain 模式下就是字面量 5 个字符。

---

## 许可证

本项目基于 [MIT License](LICENSE) 开源。

---

> 项目地址：[https://github.com/yorkane/docker-openresty-tool](https://github.com/yorkane/docker-openresty-tool)
