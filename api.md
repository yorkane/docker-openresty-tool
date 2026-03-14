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
