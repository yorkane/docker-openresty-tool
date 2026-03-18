# 经验教训总结

本文档总结了在图片缓存迁移项目（从 Lua 磁盘缓存迁移到 nginx proxy_cache）过程中遇到的问题和解决方案。

## 📋 问题一览

| # | 问题类型 | 症状 | 根本原因 | 解决方案 |
|---|---------|------|---------|---------|
| 1 | 配置错误 | `worker_processes` 无效值 | envsubst 替换后变量值带引号 | 扩展 sed 模式移除特殊值引号 |
| 2 | 变量未替换 | nginx 配置中残留 `$NGX_*` 变量 | envsubst 参数语法错误 | 显式列出所有变量 |
| 3 | 语法错误 | nginx 报 `unexpected "}"` | 编辑残留代码片段 | 清理多余代码行 |
| 4 | API 丢失 | `/api/ls/` 返回 404 | 修复语法时误删 location | 恢复 location 配置 |

---

## 🔍 详细分析

### 问题 1: worker_processes 无效值

**错误信息:**
```
nginx: [emerg] invalid value "auto" in /usr/local/openresty/nginx/conf/nginx.conf:5
```

**原因分析:**
- `envsubst` 直接将环境变量值替换到模板中
- 环境变量 `$NGX_WORKER=auto` 被替换为 `"auto"` (带引号)
- nginx 的 `worker_processes` 指令不接受带引号的 `"auto"`

**错误代码:**
```bash
# 只有 true/false 的处理
sed -r 's/="(true|false)"/=\1/'
```

**修复:**
```bash
# 扩展为包含 auto
sed -r 's/="(true|false|auto)"/=\1/'
```

**教训:**
> ⚠️ nginx 配置指令的值语法各不相同，需要区分：
> - 字符串值：需要引号（如 `server_name "example.com"`）
> - 关键字值：不能有引号（如 `worker_processes auto;`）
> - 布尔值：不能有引号（如 `gzip on;`）
> - 数值：不能有引号（如 `worker_connections 1024;`）

---

### 问题 2: 变量未替换

**错误信息:**
```
nginx: [emerg] unknown directive "NGX_CACHE_SIZE" in /usr/local/openresty/nginx/conf/nginx.conf:XX
nginx: [emerg] unknown directive "NGX_LS_CACHE_SIZE" in ...
```

**原因分析:**
- 尝试使用模式匹配: `envsubst '$NGX_$OR_'`
- `envsubst` 不支持正则或前缀匹配，需要显式列出每个变量

**错误代码:**
```bash
envsubst '$NGX_$OR_' < template > output  # ❌ 语法错误
```

**修复:**
```bash
# 显式列出所有需要替换的变量
envsubst '$NGX_PID,$NGX_CACHE_SIZE,$NGX_LS_CACHE_SIZE,$NGX_LS_STALE_SIZE,$NGX_DNS,$NGX_DNS_TIMEOUT,$NGX_LOG_LEVEL,$NGX_APP,$NGX_HOST,$NGX_PORT' < tpl.nginx.conf > nginx.conf

envsubst '$OR_IMG_CACHE_PATH,$OR_IMG_CACHE_MAX,$OR_IMG_CACHE_INACTIVE,$OR_IMG_CACHE_VALID' < tpl.img_cache.set > inc/img_cache.set

envsubst '$OR_IMG_CACHE_VALID,$OR_IMG_CACHE_BACKGROUND_UPDATE,$OR_IMG_CACHE_USE_STALE' < tpl.img.conf > default_app/img.conf
```

**教训:**
> ⚠️ `envsubst` 变量列表语法：
> - 格式: `envsubst '$VAR1,$VAR2,$VAR3'` (用逗号分隔，整体用单引号)
> - 不支持正则/通配符匹配
> - 未列出的变量不会被替换，保留原样

---

### 问题 3: 语法错误 (unexpected "}")

**错误信息:**
```
nginx: [emerg] unexpected "}" in /usr/local/openresty/nginx/conf/default_app/main.conf:284
```

**原因分析:**
- 在修复问题 2 时，编辑操作不完整
- 旧的代码片段残留在文件中，导致 `{}` 不匹配

**教训:**
> ⚠️ 编辑 nginx 配置时的最佳实践：
> 1. 使用 `nginx -t` 验证语法
> 2. 检查 `{}` 配对（vim: `%` 跳转）
> 3. 使用编辑器语法高亮
> 4. 每次修改后立即测试

---

### 问题 4: API 端点丢失

**错误信息:**
```
HTTP 404 Not Found: {"error":"not_found","message":"no such API endpoint"}
```

**原因分析:**
- 在修复问题 3 时，误删了 `/api/ls/` 的 location 配置
- 只保留了通用的 `/api/` 404 处理

**教训:**
> ⚠️ 修改配置文件时：
> 1. 使用 `git diff` 检查变更范围
> 2. 对照备份或版本历史
> 3. 不要删除与修复目标无关的代码

---

## ✅ 最佳实践总结

### 1. 配置模板化流程

```
环境变量 → envsubst → 临时配置 → sed 后处理 → 最终配置 → nginx -t 验证
```

### 2. 测试检查清单

在 commit 之前必须通过以下检查：

- [ ] **语法检查**: `nginx -t` 通过
- [ ] **变量检查**: 最终配置文件中无 `$` 变量残留
- [ ] **API 检查**: 关键端点可访问
- [ ] **功能检查**: 核心功能正常工作
- [ ] **容器启动**: Docker 容器正常启动

### 3. 关键命令

```bash
# 检查变量残留
grep -E '\$[A-Z_]+' nginx.conf

# 检查 nginx 语法
nginx -t

# 检查容器日志
docker logs yot 2>&1 | head -50

# 测试 API 端点
curl -s http://localhost:5080/api/ls/ | head -20
```

### 4. 变量替换规则

| 类型 | 环境变量示例 | sed 处理 | 最终值 |
|-----|-------------|---------|-------|
| 字符串 | `NGX_HOST=example.com` | 无 | `example.com` |
| 数值 | `NGX_PORT=8080` | 移除引号 | `8080` |
| 布尔 | `NGX_LOG_FILE=true` | 移除引号 | `true` |
| 关键字 | `NGX_WORKER=auto` | 移除引号 | `auto` |

---

## 🛠️ 自动化测试

参见 `test.sh` 脚本，每次 commit 前运行：

```bash
./test.sh
```

测试通过后才能执行 `git commit` 和 `git push`。

---

## 📚 相关文档

- [nginx proxy_cache 官方文档](http://nginx.org/en/docs/http/ngx_http_proxy_module.html#proxy_cache)
- [envsubst GNU 文档](https://www.gnu.org/software/gettext/manual/html_node/envsubst-Invocation.html)
- [OpenResty 最佳实践](https://openresty.org/cn/)
