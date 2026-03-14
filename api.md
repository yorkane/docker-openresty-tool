# API 文档

本文档描述 docker-openresty-tool 提供的 HTTP API 接口。

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

> **注意**：超过最大值时自动截断为 `OR_API_PAGE_SIZE_MAX`，不报错。

### 成功响应 `200 OK`

```json
{
  "path":      "/archives",
  "page":      1,
  "page_size": 50,
  "total":     3,
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

条目按如下规则排序：
1. `"dir"` 和 `"zip"` 排在 `"file"` 之前
2. 同类型内按文件名**字母序（大小写不敏感）**升序排列

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

## 实现说明

- **模块**：`nginx/lua/lib/dirapi.lua`
- **普通目录**：通过 LuaJIT FFI 调用 POSIX `opendir` / `readdir` / `stat`，无外部依赖
- **ZIP 内部浏览**：通过 `luazip` 库迭代 ZIP 中央目录，提取直接子项（子目录/文件）
- **路径路由**：解析请求路径中是否包含配置的 ZIP 扩展名；有则进入 ZIP 模式，无则进入文件系统模式
- **时间**：
  - 普通目录：读取 `st_mtime` / `st_ctime`，格式化为 UTC ISO-8601
  - ZIP 内部：返回空字符串（luazip 不暴露 ZIP 内部时间戳）
- **ZIP 检测**：ZIP 扩展名读取 `OR_ZIP_EXTS` 环境变量，与 `lib.zipfs` 保持一致
- **安全性**：检测路径中的 `..` 并返回 400；`Cache-Control: no-store` 防止缓存
- **JSON**：内置极简编码器，无需 `cjson` 依赖（字符串特殊字符均正确转义）
