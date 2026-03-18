# /img/ 缓存配置说明

## 概述

`/img/` 端点使用 nginx 原生的 `proxy_cache` 进行图像响应缓存，所有缓存逻辑完全由 nginx 处理，Lua 仅负责图像处理。

## 配置方式

### 通过环境变量配置

在 `docker-compose.yml` 中设置以下环境变量：

```yaml
environment:
  # 缓存有效期（默认 2d）
  - OR_IMG_CACHE_VALID=2d      # 支持: 1h, 7d, 30m, 2d 等

  # 最大缓存磁盘使用量（默认 2g）
  - OR_IMG_CACHE_MAX=2g        # 支持: 1g, 5g, 10g 等

  # 不活跃文件删除时间（默认 60d）
  - OR_IMG_CACHE_INACTIVE=60d   # 支持: 30d, 90d, 120d 等

  # 缓存目录（默认 /data/cache）
  - OR_IMG_CACHE_PATH=/data/cache

  # 后台更新（默认 on）
  - OR_IMG_CACHE_BACKGROUND_UPDATE=on

  # 陈旧缓存使用策略
  - OR_IMG_CACHE_USE_STALE=error timeout updating http_500 http_502 http_503 http_504
```

## 工作原理

### 配置生成流程

1. **容器启动时**，`entrypoint.sh` 读取环境变量
2. **使用 `envsubst`** 将模板文件中的占位符替换为实际值
3. **生成配置文件**：
   - `tpl.img_cache.set` → `inc/img_cache.set`（proxy_cache_path 配置）
   - `tpl.img.conf` → `default_app/img.conf`（/img/ location 配置）

### 缓存行为

- **HIT**: 命中缓存，直接返回缓存的图像
- **MISS**: 未命中缓存，处理图像后缓存结果
- **BYPASS**: 绕过缓存（请求参数 `?nocache=1` 或 Cookie `nocache=1`）

### 缓存控制

```bash
# 绕过缓存
curl "http://localhost:5080/img/test.jpg?w=200&nocache=1"

# 检查缓存状态
curl -I http://localhost:5080/img/test.jpg?w=200
# 响应头: X-Cache-Status: HIT | MISS | BYPASS
```

## 测试配置生成

### 本地测试

```bash
# 运行测试脚本
./test_config_generation.sh

# 查看生成的配置
cat nginx/conf/inc/img_cache.set
cat nginx/conf/default_app/img.conf
```

### 容器内验证

```bash
# 进入容器
docker exec -it yot sh

# 查看生成的配置
cat /usr/local/openresty/nginx/conf/inc/img_cache.set
cat /usr/local/openresty/nginx/conf/default_app/img.conf

# 查看 nginx 配置语法
nginx -t
```

## 文件结构

```
nginx/conf/
├── tpl.img_cache.set       # 缓存路径配置模板（包含环境变量占位符）
├── tpl.img.conf           # /img/ location 配置模板
├── inc/img_cache.set      # 生成的缓存路径配置（由 entrypoint.sh 生成）
└── default_app/img.conf   # 生成的 /img/ location 配置（由 entrypoint.sh 生成）
```

## Lua 代码

### vips.lua 职责

**仅负责图像处理：**
- URL 参数解析（w, h, fit, fmt, q, crop）
- 文件读取
- libvips 图像转换
- 响应发送

**完全不涉及缓存：**
- ❌ 不设置 `X-Cache-Status` 头（由 nginx 设置）
- ❌ 不管理缓存文件
- ❌ 不进行缓存逻辑判断

## 常见问题

### Q: 如何调整缓存时间？

A: 修改 `docker-compose.yml` 中的 `OR_IMG_CACHE_VALID` 环境变量，然后重启容器：

```bash
docker-compose down
docker-compose up -d
```

### Q: 如何清理缓存？

A: 删除缓存目录：

```bash
docker exec yot rm -rf /data/cache/*
```

### Q: 缓存不生效怎么办？

A: 检查以下几点：

1. 确认环境变量设置正确
2. 查看生成的配置文件
3. 检查 nginx 错误日志
4. 确认缓存目录权限正确

### Q: 如何禁用缓存？

A: 设置 `OR_IMG_CACHE_VALID=0` 或设置 `OR_IMG_CACHE_BACKGROUND_UPDATE=off`

## 性能调优建议

### 缓存大小

- **小规模应用**: `1g` - `2g`
- **中等规模应用**: `5g` - `10g`
- **大规模应用**: `20g` - `50g`

### 缓存时间

- **静态图片（不经常变化）**: `7d` - `30d`
- **动态图片（经常变化）**: `1h` - `2d`
- **实时图片（频繁变化）**: `30m` - `1h`

### 不活跃时间

建议设置为缓存有效期的 2-3 倍，以避免频繁的缓存清理。

## 相关文档

- [Nginx proxy_cache 文档](http://nginx.org/en/docs/http/ngx_http_proxy_module.html#proxy_cache)
- [libvips 文档](https://libvips.github.io/libvips/)
- 项目完整实施文档: `.memory/2026-03-18-proxy-cache-implementation.md`
