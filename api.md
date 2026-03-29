# API 文档

本文档描述 docker-openresty-tool 提供的全部 HTTP JSON API 接口。

> **快速跳转**
>
> | 接口 | 方法 | 路径 | 功能 |
> |------|------|------|------|
> | [目录列表](#目录-json-api--get-apilspath) | `GET` | `/api/ls/<path>` | 列出目录或 ZIP 内部文件，支持分页、排序 |
> | [删除](#删除文件或目录--delete-apirmpath) | `DELETE` | `/api/rm/<path>` | 删除文件或目录（递归） |
> | [移动/改名](#移动--改名--post-apimove) | `POST` | `/api/move` | 移动或重命名文件/目录 |
> | [新建目录](#新建目录--post-apimkdirpath) | `POST` | `/api/mkdir/<path>` | 创建目录（mkdir -p） |
> | [上传文件](#上传文件--post-apiuploadpath) | `POST` | `/api/upload/<path>` | 上传单个文件 |
> | [实时图片处理](#实时图片处理--post-apiimg) | `POST` | `/api/img` | 二进制图片处理（缩放/裁切/转格式），高吞吐实时服务 |
> | [批量图片处理](#批量图片处理--post-apibatch-img) | `POST` | `/api/batch-img` | 本地文件/目录批量处理，支持本地 imgproxy 和远程算力两种模式 |
> | [Gallery 整理](#gallery-整理--post-apigallerize) | `POST` | `/api/gallerize` | 整理 gallery 目录结构、生成封面、批量转换图片为 `.jiff` |

---

## 目录 JSON API — `GET /api/ls/<path>`

列出指定目录下的子目录和文件，返回 JSON 格式，支持分页。

`<path>` 支持两种寻址模式：

| 模式 | 示例 | 说明 |
|------|------|------|
| **普通目录** | `/api/ls/archives` | 列出文件系统目录的直接子项 |
| **ZIP 内部路径** | `/api/ls/archives/book.cbz` | 列出 ZIP 文件根目录的内容 |
| **ZIP 子目录** | `/api/ls/archives/book.cbz/chapter1` | 列出 ZIP 内部 `chapter1/` 目录的内容 |

当路径中包含 ZIP 兼容扩展名（由 `OR_ZIP_EXTS` 配置）时，API 自动切换为 **ZIP 内部浏览模式**，无论 `OR_ZIPFS_TRANSPARENT` 的状态如何。

### 路由

```
GET /api/ls/<path>
GET /api/ls/<path>?page=<N>&page_size=<N>
```

- `<path>` 相对于 WebDAV 根目录（`/webdav`，可通过 nginx 变量 `$webdav_root` 配置）
- 路径两端的斜线可选：`/api/ls/archives` 和 `/api/ls/archives/` 效果相同
- **只列出当前目录的直接子项**，不递归展开子目录
- 当 `<path>` 中含有 ZIP 兼容扩展名时（如 `.zip`、`.cbz`），自动进入 **ZIP 内部浏览模式**

### 查询参数

| 参数 | 类型 | 默认值 | 说明 |
|------|------|--------|------|
| `page` | int ≥ 1 | `1` | 页码，从 1 开始 |
| `page_size` | int ≥ 1 | `50` | 每页条目数，最大值由 `OR_API_PAGE_SIZE_MAX` 控制（默认 200） |
| `sort` | string | `name` | 排序字段：`name` \| `size` \| `mtime` \| `ctime` \| `type` |
| `order` | string | `asc` | 排序方向：`asc`（升序）\| `desc`（降序） |

> **注意**：超过最大值时自动截断为 `OR_API_PAGE_SIZE_MAX`，不报错。`sort` 传入非法值时静默回退为 `name`；`order` 传入非法值时静默回退为 `asc`。

### 成功响应 `200 OK`

```json
{
  "path":      "/archives",
  "page":      1,
  "page_size": 50,
  "total":     3,
  "sort":      "name",
  "order":     "asc",
  "items": [
    {
      "name":  "test_assets.cbz",
      "type":  "zip",
      "size":  3032,
      "mtime": "2026-03-14T12:01:10Z",
      "ctime": "2026-03-14T12:01:10Z"
    },
    {
      "name":  "subdir",
      "type":  "dir",
      "size":  128,
      "mtime": "2026-03-14T11:00:00Z",
      "ctime": "2026-03-14T11:00:00Z"
    },
    {
      "name":  "readme.txt",
      "type":  "file",
      "size":  512,
      "mtime": "2026-03-01T08:00:00Z",
      "ctime": "2026-03-01T08:00:00Z"
    }
  ]
}
```

#### 响应字段说明

| 字段 | 类型 | 说明 |
|------|------|------|
| `path` | string | 请求的目录路径（以 `/` 开头），不含末尾斜线 |
| `page` | int | 当前页码 |
| `page_size` | int | 本次请求的每页容量 |
| `total` | int | 该目录下**所有**子项总数（分页前） |
| `sort` | string | 本次排序所用的字段（回显请求参数，非法值已回退为 `name`） |
| `order` | string | 本次排序方向（回显请求参数，非法值已回退为 `asc`） |
| `items` | array | 当前页的条目列表 |

#### 条目（item）字段说明

| 字段 | 类型 | 说明 |
|------|------|------|
| `name` | string | 文件或目录名称（不含路径） |
| `type` | string | 类型：`"dir"` \| `"file"` \| `"zip"` |
| `size` | int | 文件大小（字节）；目录为目录本身的 dirent 大小 |
| `mtime` | string | 最后修改时间，ISO-8601 UTC 格式（`YYYY-MM-DDThh:mm:ssZ`） |
| `ctime` | string | 元数据变更时间（inode change time），ISO-8601 UTC 格式 |

#### `type` 字段值说明

| 值 | 含义 |
|----|------|
| `"dir"` | 普通文件系统目录，**或** ZIP 内部的虚拟子目录 |
| `"file"` | 普通文件，**或** ZIP 内部的普通文件 |
| `"zip"` | ZIP 兼容压缩包（扩展名匹配 `OR_ZIP_EXTS`），**且** `OR_ZIPFS_TRANSPARENT=true`（默认）。关闭后返回 `"file"` |

> **注意**：在 ZIP 内部浏览模式下，`mtime` 和 `ctime` 字段为空字符串 `""`（ZIP 格式的内部时间戳精度有限，luazip 不对外暴露，因此不填充）。

#### 排序规则

排序由 `sort` 和 `order` 参数控制，排序作用于**全量数据**，分页在排序之后进行。

| `sort` 值 | 排序依据 | 相同时的次要排序 |
|-----------|----------|-----------------|
| `name`（默认）| 文件名（大小写不敏感） | — |
| `size` | 文件大小（字节） | 名称升序 |
| `mtime` | 最后修改时间 | 名称升序 |
| `ctime` | 元数据变更时间 | 名称升序 |
| `type` | 类型优先级：`dir` < `zip` < `file` | 名称升序 |

`order=asc` 为升序（默认），`order=desc` 为降序。

### 错误响应

所有错误均返回 `application/json`，结构如下：

```json
{
  "error":   "<错误代码>",
  "message": "<可读描述>"
}
```

| HTTP 状态 | error 代码 | 触发条件 |
|-----------|-----------|----------|
| `400` | `bad_request` | 路径包含 `..`（路径穿越检测） |
| `404` | `not_found` | 路径不存在（文件系统或 ZIP 文件均不存在） |
| `404` | `not_found` | 路径存在但不是目录（是普通文件且不含 ZIP 扩展名） |
| `500` | `internal` | 无法打开目录或 ZIP 文件（权限不足、文件损坏等） |

---

## 使用示例

### 列出根目录

```bash
curl http://localhost:5080/api/ls/
```

```json
{
  "path": "/",
  "page": 1,
  "page_size": 50,
  "total": 2,
  "items": [
    { "name": "archives", "type": "dir",  "size": 160, "mtime": "2026-03-14T12:51:26Z", "ctime": "2026-03-14T12:51:26Z" },
    { "name": "images",   "type": "dir",  "size": 192, "mtime": "2026-03-14T12:00:23Z", "ctime": "2026-03-14T12:00:23Z" }
  ]
}
```

### 列出包含 ZIP 的目录

当 `OR_ZIPFS_TRANSPARENT=true`（默认），`.zip`/`.cbz` 文件显示为 `type:"zip"`：

```bash
curl http://localhost:5080/api/ls/archives
```

```json
{
  "path": "/archives",
  "page": 1,
  "page_size": 50,
  "total": 3,
  "items": [
    { "name": "book.cbz",       "type": "zip",  "size": 10240, "mtime": "...", "ctime": "..." },
    { "name": "archive.zip",    "type": "zip",  "size": 5120,  "mtime": "...", "ctime": "..." },
    { "name": "notes.txt",      "type": "file", "size": 128,   "mtime": "...", "ctime": "..." }
  ]
}
```

### 浏览 ZIP 内部结构

直接在路径中"进入" ZIP 文件，API 会透明地列出 ZIP 内部内容：

```bash
# 列出 ZIP 文件的根目录
curl http://localhost:5080/api/ls/archives/book.cbz
```

```json
{
  "path": "/archives/book.cbz",
  "page": 1,
  "page_size": 50,
  "total": 4,
  "items": [
    { "name": "chapter1", "type": "dir",  "size": 0, "mtime": "", "ctime": "" },
    { "name": "chapter2", "type": "dir",  "size": 0, "mtime": "", "ctime": "" },
    { "name": "cover.jpg","type": "file", "size": 204800, "mtime": "", "ctime": "" },
    { "name": "info.txt", "type": "file", "size": 512,    "mtime": "", "ctime": "" }
  ]
}
```

```bash
# 列出 ZIP 内部子目录
curl http://localhost:5080/api/ls/archives/book.cbz/chapter1
```

```json
{
  "path": "/archives/book.cbz/chapter1",
  "page": 1,
  "page_size": 50,
  "total": 3,
  "items": [
    { "name": "page001.jpg", "type": "file", "size": 102400, "mtime": "", "ctime": "" },
    { "name": "page002.jpg", "type": "file", "size": 98304,  "mtime": "", "ctime": "" },
    { "name": "page003.jpg", "type": "file", "size": 110592, "mtime": "", "ctime": "" }
  ]
}
```

> **说明**：
> - ZIP 内部浏览模式下 `mtime` 和 `ctime` 为空字符串（ZIP 格式时间戳不通过 luazip 暴露）
> - ZIP 内部模式不受 `OR_ZIPFS_TRANSPARENT` 影响——只要路径中含有 ZIP 扩展名，就会进入 ZIP 内部
> - 这与 `/zip/` 端点共享同一个 ZIP 文件（luazip），内容完全一致

### 分页

每页 2 条，获取第 2 页：

```bash
curl "http://localhost:5080/api/ls/archives?page=2&page_size=2"
```

```json
{
  "path": "/archives",
  "page": 2,
  "page_size": 2,
  "total": 5,
  "items": [
    { "name": "file3.zip", "type": "zip",  "size": 2048, "mtime": "...", "ctime": "..." },
    { "name": "readme.md", "type": "file", "size": 256,  "mtime": "...", "ctime": "..." }
  ]
}
```

### 排序

按文件大小降序（最大的文件排最前）：

```bash
curl "http://localhost:5080/api/ls/archives?sort=size&order=desc"
```

```json
{
  "path": "/archives",
  "page": 1,
  "page_size": 50,
  "total": 3,
  "sort": "size",
  "order": "desc",
  "items": [
    { "name": "book.cbz",    "type": "zip",  "size": 10240, "mtime": "...", "ctime": "..." },
    { "name": "archive.zip", "type": "zip",  "size": 5120,  "mtime": "...", "ctime": "..." },
    { "name": "notes.txt",   "type": "file", "size": 128,   "mtime": "...", "ctime": "..." }
  ]
}
```

按修改时间降序（最新文件排最前），取第 1 页：

```bash
curl "http://localhost:5080/api/ls/archives?sort=mtime&order=desc&page=1&page_size=10"
```

按 `type` 升序（dirs → zip → files），同类内按名称升序（即默认展示风格）：

```bash
curl "http://localhost:5080/api/ls/archives?sort=type&order=asc"
```

### 超出范围的页返回空 items

```bash
curl "http://localhost:5080/api/ls/archives?page=999"
```

```json
{
  "path": "/archives",
  "page": 999,
  "page_size": 50,
  "total": 3,
  "items": []
}
```

### 错误：路径不存在

```bash
curl http://localhost:5080/api/ls/no_such_dir
```

```json
{
  "error": "not_found",
  "message": "path not found"
}
```

---

## 环境变量配置

| 变量 | 默认值 | 说明 |
|------|--------|------|
| `OR_API_PAGE_SIZE_MAX` | `200` | `page_size` 允许的最大值，超过时自动截断 |
| `OR_ZIPFS_TRANSPARENT` | `true` | 控制 ZIP 兼容文件是否以 `type:"zip"` 返回（`false` 时返回 `"file"`） |
| `OR_ZIP_EXTS` | `zip,cbz` | 逗号分隔的 ZIP 兼容文件扩展名列表，大小写不敏感 |

### docker-compose 示例

```yaml
services:
  openresty:
    image: yorkane/docker-openresty-tool:latest
    environment:
      OR_API_PAGE_SIZE_MAX: "500"      # 允许最大 500 条/页
      OR_ZIPFS_TRANSPARENT: "true"     # zip 文件视为虚拟目录（默认）
      OR_ZIP_EXTS: "zip,cbz,epub"      # 同时支持 epub 格式
```

---

## 文件管理 API

以下四个端点提供文件和目录的增删改（移动/改名）操作。  
所有路径均相对于 WebDAV 根目录（`/webdav`，可通过 `$webdav_root` 配置）。  
这些端点位于 `/api/` 前缀下，**不会与 WebDAV 协议（`/`）产生冲突**。

---

### 删除文件或目录 — `DELETE /api/rm/<path>`

删除指定路径的文件或目录。**目录会被递归删除**（相当于 `rm -rf`）。

```
DELETE /api/rm/<path>
```

#### 成功响应 `200 OK`

```json
{ "ok": true }
```

#### 示例

```bash
# 删除单个文件
curl -X DELETE http://localhost:5080/api/rm/archives/old-notes.txt

# 删除目录（递归）
curl -X DELETE http://localhost:5080/api/rm/archives/old-backups
```

---

### 移动 / 改名 — `POST /api/move`

移动文件或目录到新路径，也可用于重命名。  
目标路径的父目录若不存在，会**自动创建**。

```
POST /api/move
Content-Type: application/json
```

#### 请求体

| 字段 | 类型 | 必填 | 说明 |
|------|------|------|------|
| `from` | string | ✓ | 源路径（相对于 webdav_root） |
| `to` | string | ✓ | 目标路径（相对于 webdav_root） |
| `overwrite` | bool | — | `true` 时允许覆盖已存在的目标（默认 `false`） |

#### 成功响应 `200 OK`

```json
{ "ok": true }
```

#### 示例

```bash
# 重命名文件
curl -X POST http://localhost:5080/api/move \
     -H "Content-Type: application/json" \
     -d '{"from": "/archives/draft.txt", "to": "/archives/final.txt"}'

# 移动目录（跨目录）
curl -X POST http://localhost:5080/api/move \
     -H "Content-Type: application/json" \
     -d '{"from": "/tmp/upload", "to": "/archives/2026/upload"}'

# 覆盖目标（overwrite: true）
curl -X POST http://localhost:5080/api/move \
     -H "Content-Type: application/json" \
     -d '{"from": "/archives/new.zip", "to": "/archives/backup.zip", "overwrite": true}'
```

---

### 新建目录 — `POST /api/mkdir/<path>`

创建目录，自动创建所有缺失的父目录（等同于 `mkdir -p`）。  
如果目标路径**已经是目录**，幂等返回 `200`。

```
POST /api/mkdir/<path>
```

#### 成功响应 `200 OK`

```json
{ "ok": true }
```

#### 示例

```bash
# 创建单级目录
curl -X POST http://localhost:5080/api/mkdir/archives/photos

# 创建多级目录（自动创建父目录）
curl -X POST http://localhost:5080/api/mkdir/archives/2026/march/raw
```

---

### 上传文件 — `POST /api/upload/<path>`

上传单个文件，请求体为**原始文件字节**。  
目标文件的父目录若不存在，会**自动创建**。  
若目标文件已存在，会**直接覆盖**。

```
POST /api/upload/<path>
Content-Type: <任意>
```

#### 成功响应 `200 OK`

```json
{ "ok": true, "size": 1024 }
```

`size` 为写入后的文件字节数。

#### 示例

```bash
# 上传文本文件
curl -X POST http://localhost:5080/api/upload/notes/todo.txt \
     -H "Content-Type: text/plain" \
     --data-binary "Buy milk\nFix CI"

# 上传二进制文件（图片）
curl -X POST http://localhost:5080/api/upload/images/cover.png \
     -H "Content-Type: image/png" \
     --data-binary @/path/to/local/cover.png

# 上传到自动创建的深层目录
curl -X POST http://localhost:5080/api/upload/archives/2026/march/report.pdf \
     -H "Content-Type: application/pdf" \
     --data-binary @report.pdf
```

---

### 文件管理 API 错误码

所有文件管理 API 错误均返回 `application/json`，格式与目录 API 一致：

```json
{ "error": "<错误代码>", "message": "<可读描述>" }
```

| HTTP 状态 | error 代码 | 触发条件 |
|-----------|-----------|----------|
| `400` | `bad_request` | 路径包含 `..`；请求体为空；JSON 字段缺失；上传路径以 `/` 结尾 |
| `403` | `forbidden` | 尝试删除 webdav_root 本身；路径逃出 webdav_root 范围；`OR_FILEAPI_DISABLE=true` |
| `404` | `not_found` | 源路径不存在（`rm` / `move` 的 `from`） |
| `405` | `method_not_allowed` | 使用了错误的 HTTP 方法（如 GET 到 `/api/rm/`） |
| `409` | `conflict` | 移动目标已存在且未设置 `overwrite:true`；`mkdir` 时路径存在但是普通文件 |
| `500` | `internal` | 文件系统操作失败（权限不足、磁盘满等） |

### 环境变量

| 变量 | 默认值 | 说明 |
|------|--------|------|
| `OR_FILEAPI_DISABLE` | _(未设置)_ | 设为 `"true"` 时禁用所有文件管理端点，统一返回 403 |

---

## 实时图片处理 — `POST /api/img`

将图片二进制直接 POST 到此接口，服务端通过 imgproxy 完成缩放、裁切、格式转换后立即返回处理结果。  
**参数与 `/img/` 完全一致**，但不使用 nginx proxy_cache，专为需要最高吞吐量的实时处理场景设计。

内部通过 **HTTP API** 与 imgproxy 通信（使用 `IMGPROXY_UPSTREAM` 配置，默认 `imgproxy:8080`），使用 imgproxy 的 raw upload 模式。

```
POST /api/img?w=200&h=150&fit=cover&fmt=webp&q=80
Content-Type: image/jpeg   (或任何图片 MIME 类型)
Body: <raw image bytes>
```

### 与 `/img/` 的对比

| 特性 | `/img/<path>` | `/api/img` |
|------|--------------|------------|
| 图片来源 | 服务器本地文件（通过 imgproxy 的 `local://` URL 读取） | 请求 body（通过 imgproxy raw upload 处理） |
| Nginx 缓存 | ✅ proxy_cache | ❌ 无缓存（每次都处理） |
| 适用场景 | 静态资源加速 | 实时处理流水线、高并发转换服务 |
| 磁盘 I/O | imgproxy 读取磁盘文件 | 纯内存操作到 imgproxy |
| CPU 使用 | 缓存命中时为零 | 每请求全速处理，饱和所有核心 |

### imgproxy 架构说明

两个接口均通过 imgproxy 处理图片：

- **imgproxy** 是独立 Docker 容器（`imgproxy` 服务名，端口 8080）
- 图片通过 `local://` URL 传递给 imgproxy，路径相对于 `IMGPROXY_LOCAL_FILESYSTEM_ROOT=/data`
- **重要**：`local://` URL 使用**三斜杠**格式（`local:///.imgproxy-tmp/xxx`），否则 imgproxy 会将路径中首个段解析为 hostname，导致 404
- imgproxy 不对 `local://` URL 做 base64 编码（raw URL 直传）
- 格式通过 `/format:<ext>` 处理段指定（如 `/format:webp`），不是 `@webp` 后缀

### 查询参数

| 参数 | 类型 | 默认值 | 说明 |
|------|------|--------|------|
| `w` | int | — | 目标宽度（像素），不填则不限制 |
| `h` | int | — | 目标高度（像素），不填则不限制 |
| `fit` | string | `contain` | 缩放模式：`contain` \| `cover` \| `fill` \| `scale` |
| `crop` | string | — | 先裁切再缩放，格式：`x,y,width,height`（像素坐标） |
| `fmt` | string | 同输入格式 | 输出格式：`jpeg` \| `webp` \| `png` \| `avif` \| `gif` |
| `q` | int 1-100 | `82` | 输出质量（jpeg / webp / avif 有效） |

#### `fit` 模式说明

| 值 | 行为 |
|----|------|
| `contain`（默认）| 等比缩放，完整放入目标框，不裁切 |
| `cover` | 等比缩放，覆盖整个目标框，居中裁切多余部分 |
| `fill` | 不保持比例，强制拉伸填满目标尺寸 |
| `scale` | 按 `w` 等比缩放（仅支持 `w` 参数） |

### 请求

- **Method**: `POST`
- **Content-Type**: `image/jpeg`、`image/webp`、`image/png`、`image/avif` 等（任意 imgproxy 支持的格式）
- **Body**: 原始图片二进制字节（无需 multipart/form-data 封装）

### 响应

#### 成功 `200 OK`

- **Body**: 处理后的图片二进制
- **Content-Type**: 对应输出格式的 MIME 类型
- **响应头**:

| 头 | 说明 |
|----|------|
| `X-Imgproxy` | `processed`（处理完成）或 `passthrough`（无参数直通） |
| `Content-Length` | 输出字节数 |
| `Cache-Control` | `private, max-age=86400` |

#### 错误响应

所有错误均返回 `application/json`：

| HTTP 状态 | error 代码 | 触发条件 |
|-----------|-----------|----------|
| `400` | `bad_request` | 请求 body 为空 |
| `405` | `method_not_allowed` | 使用了非 POST 方法 |
| `415` | `unsupported_media_type` | 图片格式无法解码（损坏或不支持的格式） |
| `502` | `bad_gateway` | imgproxy 处理失败（超时、格式错误等） |
| `500` | `internal` | 图片编码失败 |

### 示例

```bash
# 缩放为 400px 宽，保持比例，转为 webp
curl -X POST "http://localhost:5080/api/img?w=400&fmt=webp&q=85" \
     -H "Content-Type: image/jpeg" \
     --data-binary @photo.jpg \
     -o thumb.webp

# cover 模式裁切为 200×200 缩略图
curl -X POST "http://localhost:5080/api/img?w=200&h=200&fit=cover&fmt=jpeg&q=80" \
     -H "Content-Type: image/png" \
     --data-binary @avatar.png \
     -o avatar_thumb.jpg

# 先裁切区域再缩放
curl -X POST "http://localhost:5080/api/img?crop=100,50,800,600&w=400&fmt=webp" \
     -H "Content-Type: image/jpeg" \
     --data-binary @screenshot.jpg \
     -o cropped.webp

# 仅转换格式（无缩放）
curl -X POST "http://localhost:5080/api/img?fmt=avif&q=70" \
     -H "Content-Type: image/jpeg" \
     --data-binary @photo.jpg \
     -o photo.avif

# 无参数直通（返回原图，不处理）
curl -X POST "http://localhost:5080/api/img" \
     -H "Content-Type: image/jpeg" \
     --data-binary @photo.jpg \
     -o original_copy.jpg
```

### 高并发使用建议

- **CPU 并发**：imgproxy 自动启用内部线程池（`IMGPROXY_MAX_WORKERS=0` = auto），每个请求可饱和所有 CPU 核心。
- **连接池**：建议客户端使用 HTTP keep-alive + 连接池，减少 TCP 握手开销。
- **body 缓冲**：nginx 配置 `client_body_buffer_size 32m`，32 MB 以内的图片全程内存处理；超过则自动落盘临时文件，Lua 侧透明处理。
- **无缓存**：本接口不缓存，适合每次输入都不同的场景（如用户上传图片处理、动态水印等）。  
  如需缓存处理结果，请使用 `/img/<path>` 接口（nginx proxy_cache）。

### 动态图保护（Animated WebP/GIF）

- 接口会自动检测 **动态 WebP** 和 **动态 GIF**（通过文件头扫描）。
- 检测到动态图时，直接返回原始字节（HTTP 200），响应头标记为 `X-Imgproxy: passthrough-animated`。
- 这避免了缩放/转码导致动画帧丢失的问题。
- 如需强制处理（会丢失动画），使用 `ignore_exts` 参数排除该格式。

### 扩展名过滤（`ignore_exts`）

- 参数 `ignore_exts=gif,webp` 可指定跳过的格式。
- 匹配的文件将原样返回（`/api/img`）或在批量任务中跳过（`/api/batch-img`）。
- 适用于：
  - 保留动态图完整性
  - 避免对已经压缩良好的格式二次处理
  - 减少处理耗时

---

## 批量图片处理 — `POST /api/batch-img`

对服务器本地文件或目录中的图片进行批量处理（缩放、裁切、格式转换）。  
支持两种处理模式：**本地模式**（使用 imgproxy HTTP API 在当前实例处理）和**远程模式**（将图片转发给另一台高算力实例的 `/api/img` 接口处理）。

```
POST /api/batch-img
Content-Type: application/json
```

### 请求 Body（JSON）

#### 必填字段

| 字段 | 类型 | 说明 |
|------|------|------|
| `path` | string | 本地文件或目录路径（相对于 webdav_root，或绝对路径） |

#### 图片处理参数（与 `/api/img` 完全一致）

| 参数 | 类型 | 默认值 | 说明 |
|------|------|--------|------|
| `w` | int | — | 目标宽度（像素） |
| `h` | int | — | 目标高度（像素） |
| `fit` | string | `contain` | 缩放模式：`contain` \| `cover` \| `fill` \| `scale` |
| `crop` | string | — | 先裁切再缩放，格式：`"x,y,width,height"` |
| `fmt` | string | 同输入格式 | 输出格式：`jpeg` \| `webp` \| `png` \| `avif` \| `gif` |
| `q` | int 1-100 | `82` | 输出质量（jpeg/webp/avif 有效） |
| `ignore_exts` | string | — | 逗号分隔的扩展名列表，匹配的文件将原样复制/跳过（如 `"gif,webp"` 保留动态图） |

#### 输出控制

| 参数 | 类型 | 默认值 | 说明 |
|------|------|--------|------|
| `out_suffix` | string | — | 在文件名后、扩展名前插入后缀，例如 `"-thumb"` → `photo.jpg → photo-thumb.jpg` |
| `out_dir` | string | — | 将输出写到此目录（保留文件名）；目录不存在时自动创建 |
| `overwrite` | bool | `true` | 输出文件已存在时是否覆盖；`false` 时跳过，计入 `skipped` |
| `recursive` | bool | `false` | 是否递归处理子目录 |

> `out_suffix` 和 `out_dir` 均不指定时，原地覆盖源文件（配合 `fmt` 可同时转换格式并重命名扩展名）。

#### 处理模式

| 参数 | 类型 | 默认值 | 说明 |
|------|------|--------|------|
| `mode` | string | `"local"` | `"local"` — imgproxy HTTP API 本地处理；`"remote"` — 转发给远端 `/api/img` |

#### 远程模式参数（`mode=remote` 时生效）

| 参数 | 类型 | 默认值 | 说明 |
|------|------|--------|------|
| `remote_url` | string | **必填** | 远端 `/api/img` 完整 URL，如 `http://10.0.0.5:5080/api/img` |
| `concurrency` | int 1-64 | `4` | 同时向远端发送的并发请求数；建议设为远端 CPU 核心数 |
| `connect_timeout_ms` | int | `5000` | TCP 连接超时（毫秒） |
| `send_timeout_ms` | int | `30000` | 发送图片数据超时（毫秒） |
| `recv_timeout_ms` | int | `60000` | 接收处理结果超时（毫秒） |

### 成功响应 `200 OK`

```json
{
  "ok":      true,
  "total":   42,
  "done":    41,
  "skipped": 1,
  "errors":  [],
  "results": [
    {
      "src":      "/data/photos/a.jpg",
      "dst":      "/data/thumbs/a.jpg",
      "size_in":  2048000,
      "size_out": 184320,
      "ms":       38
    }
  ]
}
```

| 字段 | 类型 | 说明 |
|------|------|------|
| `ok` | bool | 所有文件均无错误时为 `true` |
| `total` | int | 扫描到的图片文件总数 |
| `done` | int | 成功处理的文件数 |
| `skipped` | int | 因 `overwrite=false` 跳过的文件数 |
| `errors` | array | 处理失败的条目，每项含 `src` 和 `error` 字段 |
| `results` | array | 成功处理的详情，每项含 `src`、`dst`、`size_in`、`size_out`（字节）、`ms`（耗时毫秒） |

### 错误响应

| HTTP 状态 | error 代码 | 触发条件 |
|-----------|-----------|----------|
| `400` | `bad_request` | 缺少 `path`；路径包含 `..`；`mode=remote` 但未提供 `remote_url` 或 URL 格式错误 |
| `405` | `method_not_allowed` | 非 POST 请求 |

### 示例

#### 本地模式：将目录下所有图片压缩为 webp 缩略图

```bash
# 目录 /data/photos 下的所有图片 → /data/thumbs/，转 webp，宽度 800px
curl -X POST http://localhost:5080/api/batch-img \
     -H "Content-Type: application/json" \
     -d '{
       "path":       "/data/photos",
       "w":          800,
       "fit":        "contain",
       "fmt":        "webp",
       "q":          82,
       "out_dir":    "/data/thumbs",
       "overwrite":  true,
       "mode":       "local"
     }'
```

#### 本地模式：原地转换格式（jpg → webp），文件名加 `-web` 后缀

```bash
curl -X POST http://localhost:5080/api/batch-img \
     -H "Content-Type: application/json" \
     -d '{
       "path":       "/data/originals",
       "fmt":        "webp",
       "q":          85,
       "out_suffix": "-web",
       "mode":       "local"
     }'
# photo.jpg → photo-web.webp（保留原文件）
```

#### 本地模式：递归处理子目录，原地覆盖

```bash
curl -X POST http://localhost:5080/api/batch-img \
     -H "Content-Type: application/json" \
     -d '{
       "path":      "/data/gallery",
       "recursive": true,
       "w":         1920,
       "h":         1080,
       "fit":       "contain",
       "q":         88,
       "overwrite": true,
       "mode":      "local"
     }'
```

#### 远程模式：将本地文件批量发送到高算力实例处理

```bash
# 本地实例 → 远端高算力实例 10.0.0.5:5080
# 并发 16，最大化利用远端带宽和算力
curl -X POST http://localhost:5080/api/batch-img \
     -H "Content-Type: application/json" \
     -d '{
       "path":               "/data/raw",
       "w":                  1200,
       "fmt":                "webp",
       "q":                  82,
       "out_dir":            "/data/processed",
       "mode":               "remote",
       "remote_url":         "http://10.0.0.5:5080/api/img",
       "concurrency":        16,
       "connect_timeout_ms": 3000,
       "send_timeout_ms":    60000,
       "recv_timeout_ms":    120000
     }'
```

### 并发与性能调优

#### 本地模式
- imgproxy 自动启用内部多线程处理单张图片，`IMGPROXY_MAX_WORKERS=0` 可饱和所有 CPU 核心。
- 文件顺序处理；如需更高并发，可在多个 nginx worker 上同时发起多个 `/api/batch-img` 请求（传入不同子目录）。

#### 远程模式
- `concurrency` 控制同时飞行的请求数，**建议设置为远端机器 CPU 核心数**，例如 16 核机器设 16。
- 过高的 `concurrency` 会造成远端内存压力（每个并发请求各自在内存中保留解码像素 + 输出 buffer）；建议从 8 开始测试。
- 本地 → 远端的带宽是瓶颈时，可以在多台本地机器上同时运行，指向同一个远端实例。
- `recv_timeout_ms` 需根据最大图片处理时间调整；处理 4K 图片转 avif 可能超过 30 秒。

#### 本地 vs 远程对比

| 特性 | `mode=local` | `mode=remote` |
|------|-------------|---------------|
| CPU 使用 | 当前实例 | 远端高算力实例 |
| 网络 I/O | 无 | 双向（上传原图 + 下载结果） |
| 磁盘写入 | 本地 | 本地（结果由本地写入） |
| 适用场景 | 单机处理，I/O 带宽足够 | 本地算力弱，远端 GPU/高核数实例 |
| 并发控制 | vips 线程池（自动） | `concurrency` 参数 |
| 容错 | 单文件失败不中断整体 | 单文件失败记录 errors，继续处理 |

---

## 实现说明

### 目录 API（`lib/dirapi.lua`）

- **普通目录**：通过 LuaJIT FFI 调用 POSIX `opendir` / `readdir` / `stat`，无外部依赖
- **ZIP 内部浏览**：通过 `luazip` 库迭代 ZIP 中央目录，提取直接子项（子目录/文件）
- **路径路由**：解析请求路径中是否包含配置的 ZIP 扩展名；有则进入 ZIP 模式，无则进入文件系统模式
- **时间**：
  - 普通目录：读取 `st_mtime` / `st_ctime`，格式化为 UTC ISO-8601
  - ZIP 内部：返回空字符串（luazip 不暴露 ZIP 内部时间戳）
- **ZIP 检测**：ZIP 扩展名读取 `OR_ZIP_EXTS` 环境变量，与 `lib.zipfs` 保持一致
- **安全性**：检测路径中的 `..` 并返回 400；`Cache-Control: no-store` 防止缓存
- **JSON**：内置极简编码器，无需 `cjson` 依赖（字符串特殊字符均正确转义）

### 文件管理 API（`lib/fileapi.lua`）

- **模块**：`nginx/lua/lib/fileapi.lua`，路由在 `nginx/conf/default_app/main.conf`
- **与 WebDAV 隔离**：所有端点均在 `/api/` 前缀下，WebDAV 操作使用 HTTP 方法（PUT / DELETE / MOVE / COPY）在 `/` 路径下运行，两者互不干扰
- **FFI 系统调用**：`stat`、`mkdir`、`rename`、`unlink`、`rmdir` 直接通过 LuaJIT FFI 调用，无 shell 子进程开销
- **递归删除**：`rmdir_recursive()` 用 `opendir/readdir` 遍历目录树后逐层删除，纯 Lua 实现
- **mkdir -p**：`mkdir_p()` 按路径分段逐级检查并创建，幂等，不报错已存在的目录
- **文件上传**：支持 nginx 将大请求体 spool 到临时文件的场景（`ngx.req.get_body_file()`），流式复制，无内存峰值
- **JSON 解析**：`parse_move_body()` 用正则从 JSON 字符串提取 `from`/`to`/`overwrite`，无需 `cjson` 依赖
- **安全性**：所有路径均检测 `..`（400）并验证最终路径仍在 `webdav_root` 内（403）


### 批量图片处理 API（`lib/batchapi.lua`）

- **模块**：`nginx/lua/lib/batchapi.lua`，路由在 `nginx/conf/default_app/main.conf`
- **双模式设计**：`mode=local` 通过 HTTP 调用 imgproxy raw upload API（高性能）；`mode=remote` 通过 TCP HTTP/1.1 转发至远端 `/api/img`
- **并发控制**：远端模式使用 `ngx.semaphore` 信号量精确控制飞行中的请求数，防止远端过载
- **连接复用**：远端 socket 调用 `setkeepalive(10000, 64)` 归还连接池，降低 TCP 握手开销
- **输出命名**：三种方式：原地覆盖、`out_suffix`（插入文件名后缀）、`out_dir`（写到新目录）
- **文件扫描**：LuaJIT FFI `opendir/readdir`，可选递归子目录，支持过滤非图片文件
- **安全性**：检测路径 `..`（400），`webdav_root` 相对路径自动补全
- **imgproxy URL**：使用三斜杠 `local:///` 格式避免 hostname 解析问题

---

## Gallery 整理 — `POST /api/gallerize`

对服务器本地 gallery 目录进行整理：规范化目录结构、生成封面缩略图、将所有图片批量转换为 `.jiff`（WebP 格式，扩展名重命名）。

### 请求参数

| 字段 | 类型 | 必填 | 说明 |
|------|------|------|------|
| `path` | string | ✅ | 目标目录路径（相对于 webdav root） |
| `type` | string | ✅ | 处理类型：`"v1"` 或 `"v2"`；其他值返回 **403** |
| `extra_file_path` | string | — | 非图片文件的目标目录，绝对或相对路径均可 |
| `w` | int | — | 图片转换目标宽度（默认 `2560`） |
| `h` | int | — | 图片转换目标高度（默认 `2560`） |
| `fit` | string | — | 缩放模式（默认 `contain`） |
| `q` | int | — | 输出质量 1-100（默认 `90`） |

### Type `v1` 处理步骤

```
POST /api/gallerize
{"path": "/comics/my-collection", "type": "v1", "extra_file_path": "/trash/extras"}
```

**步骤 0 — 幂等跳过检测（Step 5 in spec）**  
若目录中所有可处理图片都已是 `.jiff` 且存在 `##cover.jiff`，认为该 gallery 已处理完毕，直接返回 `{"ok":true,"skipped":true}`。

**步骤 1 — 移动非图片文件**  
将根目录（非子目录）中的非图片文件移动到 `extra_file_path`。  
若未指定 `extra_file_path`，此步骤跳过。

**步骤 2 — 扁平化目录结构**  
- 保留第一层子目录（每个子目录视为一个独立 gallery）
- 将二级及更深层子目录中的图片文件上移到其所在的第一层目录
- 嵌套目录中的非图片文件同样移动到 `extra_file_path`
- 清理空目录

**步骤 3 — 单 gallery 提升**  
若整理后只有一个第一层子目录，认为这是单一 gallery，将其内容全部提升至根目录，删除空子目录。

**步骤 4 — 目录名校验**  
检查所有第一层子目录名称是否兼容 Windows 文件系统：
- 不超过 38 个字符
- 无非法字符：`< > : " / \ | ? *`
- 非保留名：`CON PRN AUX NUL COM1-9 LPT1-9`
- 不以空格或 `.` 结尾
- 校验失败返回 **400**

**步骤 5 — 生成封面 `##cover.jiff`**  
- 若目录已有 `##cover.jiff`，跳过
- 否则取目录内按文件名排序的第一张图片，生成封面缩略图
- 封面规格：**360×504 cover fit、WebP、q=80**，文件名固定为 `##cover.jiff`
- 多 gallery 场景：每个第一层子目录各自生成封面
- 单 gallery 场景（step 3 提升后）：在根目录生成封面

**步骤 6 — 批量转换图片**  
- 将目录中所有非 `.jiff` 图片转换为 `.jiff`（实为 WebP 内容）
- 默认规格：**2560×2560 contain fit、WebP、q=90**，可通过请求参数覆盖
- 转换成功后删除原文件（原地替换）
- 多 gallery 场景：每个第一层子目录独立处理

### 响应示例

**多 gallery 场景成功：**
```json
{
  "ok": true,
  "path": "/comics/my-collection",
  "type": "v1",
  "steps": {
    "move_non_images": {"count": 2},
    "flatten": {"dirs": ["gallery_a", "gallery_b"]},
    "promote": {"performed": false},
    "covers": {
      "gallery_a": {"generated": true, "details": {"source":"img1.png","cover":"##cover.jiff","width":360,"height":504}},
      "gallery_b": {"generated": true, "details": {"source":"img3.jpeg","cover":"##cover.jiff","width":360,"height":504}}
    },
    "convert": {"processed": 3, "skipped": 0, "errors": {}}
  }
}
```

**单 gallery 提升场景成功：**
```json
{
  "ok": true,
  "path": "/comics/single-book",
  "type": "v1",
  "steps": {
    "flatten": {"dirs": ["chapter"]},
    "promote": {"performed": true, "dir": "chapter"},
    "covers": {".": {"generated": true, "details": {"source":"page001.jpg","cover":"##cover.jiff","width":360,"height":504}}},
    "convert": {"processed": 120, "skipped": 0, "errors": {}}
  }
}
```

**已处理，跳过：**
```json
{"ok": true, "skipped": true, "reason": "gallery already processed"}
```

### 错误码

| HTTP | error | 说明 |
|------|-------|------|
| 400 | `bad_request` | 缺少必填字段、路径穿越、目录名不符规范 |
| 403 | `forbidden` | `type` 不为 `v1`/`v2`；路径超出 webdav root |
| 404 | `not_found` | 目标目录不存在 |
| 405 | `method_not_allowed` | 非 POST 请求 |

### 关于 `.jfif` 格式

`.jfif` 是 WebP 图片的重命名扩展名，内容与 `.webp` 完全一致，只是文件名后缀不同。使用 `.jfif` 的目的是：
- 与未处理的原始图片文件区分（通过扩展名快速判断是否已转换）
- 对文件管理器的 WebP 预览支持不做假设，可配置关联程序

### 实现细节

- **模块**：`nginx/lua/lib/gallerize.lua`，通过 imgproxy HTTP API 处理图片
- **文件操作**：LuaJIT FFI `opendir/readdir/rename/mkdir/rmdir/unlink`，零 shell 调用
- **幂等性**：重复请求已处理的目录会立即返回 skip，不做任何修改
- **动态图保护**：继承 `imgproc` 的动态 WebP/GIF 检测，自动跳过不处理
- **安全性**：`..` 路径穿越检测（400），路径必须在 webdav root 范围内（403）
- **imgproxy URL**：封面和图片转换均通过 HTTP 转发给 imgproxy，使用 raw upload 模式
