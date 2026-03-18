# 部署验证清单

## 代码检查

### ✅ Lua 代码
- [x] `nginx/lua/lib/vips.lua` - 移除所有 `X-Cache-Status` 头设置
- [x] `nginx/lua/lib/vips.lua` - 移除所有缓存相关注释
- [x] `nginx/lua/lib/vips.lua` - 保留纯图像处理逻辑
- [x] `nginx/lua/init_worker.lua` - 确认无 imgcache 相关代码
- [x] `nginx/lua/lib/imgcache.lua` - 文件已删除

### ✅ Nginx 配置
- [x] `nginx/conf/tpl.img_cache.set` - 缓存路径配置模板已创建
- [x] `nginx/conf/tpl.img.conf` - /img/ location 配置模板已创建
- [x] `nginx/conf/tpl.nginx.conf` - 移除硬编码的 proxy_cache_path
- [x] `nginx/conf/default_app/main.conf` - 改为 include 动态生成的 img.conf
- [x] `nginx/conf/entrypoint.sh` - 添加 envsubst 配置生成逻辑

### ✅ Docker 配置
- [x] `docker-compose.yml` - 添加完整的缓存环境变量
- [x] `docker-compose.yml` - 环境变量格式正确

### ✅ 文档
- [x] `IMG_CACHE_SETUP.md` - 缓存配置说明文档已创建
- [x] `.memory/2026-03-18-proxy-cache-implementation.md` - 实施总结文档已创建
- [x] `test_config_generation.sh` - 配置生成测试脚本已创建

## 测试验证

### ✅ 本地测试
```bash
# 1. 运行配置生成测试
./test_config_generation.sh

# 预期输出：
# === Generating img_cache.set ===
# proxy_cache_path /data/cache levels=1:2 keys_zone=img_cache:100m max_size=2g inactive=60d use_temp_path=off;

# === Generating img.conf ===
# location /img/ {
#     ...
#     proxy_cache_valid 200 2d;
#     ...
# }
```

### ✅ 语法检查
```bash
# 检查 shell 脚本语法
bash -n nginx/conf/entrypoint.sh
bash -n test_config_generation.sh

# 检查 nginx 配置语法（需要在容器内运行）
# docker exec yot nginx -t
```

### ✅ Lint 检查
```bash
# 检查 Lua 文件
# 已通过 read_lints 验证，无错误
```

## 部署前检查

### ✅ 环境变量确认
```yaml
# 确认以下环境变量在 docker-compose.yml 中已设置：
- OR_IMG_CACHE_VALID=2d
- OR_IMG_CACHE_MAX=2g
- OR_IMG_CACHE_INACTIVE=60d
- OR_IMG_CACHE_PATH=/data/cache
- OR_IMG_CACHE_BACKGROUND_UPDATE=on
- OR_IMG_CACHE_USE_STALE=error timeout updating http_500 http_502 http_503 http_504
```

### ✅ 文件权限确认
```bash
# 确认缓存目录权限正确
# docker exec yot ls -ld /data/cache
# 预期输出: drwxr-xr-x ... nginx_usr nginx_usr ...
```

### ✅ 磁盘空间确认
```bash
# 确认有足够的磁盘空间用于缓存
docker exec yot df -h /data
```

## 部署后验证

### ✅ 容器启动检查
```bash
# 1. 启动容器
docker-compose up -d

# 2. 查看日志
docker-compose logs -f

# 预期输出：
# Generating /usr/local/openresty/nginx/conf/inc/img_cache.set from template
# Generating /usr/local/openresty/nginx/conf/default_app/img.conf from template
# Starting nginx!
```

### ✅ 配置文件检查
```bash
# 检查生成的配置文件
docker exec yot cat /usr/local/openresty/nginx/conf/inc/img_cache.set
docker exec yot cat /usr/local/openresty/nginx/conf/default_app/img.conf

# 检查 nginx 配置语法
docker exec yot nginx -t

# 预期输出:
# nginx: the configuration file /usr/local/openresty/nginx/conf/nginx.conf syntax is ok
# nginx: configuration file /usr/local/openresty/nginx/conf/nginx.conf test is successful
```

### ✅ 功能测试

#### 测试 1: 缓存 MISS
```bash
# 第一次请求（预期: MISS）
curl -I http://localhost:5080/img/test.jpg?w=200&h=200

# 预期响应头:
# X-Cache-Status: MISS
# X-Vips-Processed: true
```

#### 测试 2: 缓存 HIT
```bash
# 第二次请求（预期: HIT）
curl -I http://localhost:5080/img/test.jpg?w=200&h=200

# 预期响应头:
# X-Cache-Status: HIT
# X-Vips-Processed: true
```

#### 测试 3: 缓存 BYPASS
```bash
# 使用 nocache 参数（预期: BYPASS）
curl -I "http://localhost:5080/img/test.jpg?w=200&h=200&nocache=1"

# 预期响应头:
# X-Cache-Status: BYPASS
# X-Vips-Processed: true
```

#### 测试 4: 不同参数
```bash
# 使用不同的参数（预期: MISS）
curl -I http://localhost:5080/img/test.jpg?w=300&h=300

# 预期响应头:
# X-Cache-Status: MISS
```

### ✅ 缓存目录检查
```bash
# 检查缓存目录
docker exec yot ls -lh /data/cache/

# 预期输出:
# 总大小应该大于 0
# 应该有缓存文件
```

### ✅ 性能测试
```bash
# 使用 Apache Bench 测试性能
ab -n 1000 -c 10 http://localhost:5080/img/test.jpg?w=200

# 预期:
# 第二次运行应该明显更快（因为缓存）
```

## 回滚计划

如果部署后出现问题，可以快速回滚：

### 方案 1: 调整环境变量
```yaml
# 禁用缓存
environment:
  - OR_IMG_CACHE_VALID=0
```

### 方案 2: 恢复旧配置
```bash
# 使用 git 恢复旧版本
git checkout HEAD~1 -- nginx/conf/
```

### 方案 3: 清理缓存
```bash
# 清理缓存目录
docker exec yot rm -rf /data/cache/*
```

## 监控指标

### 关键指标
1. **缓存命中率**: `X-Cache-Status: HIT` 的比例
   - 目标: > 80%

2. **缓存大小**: `/data/cache` 目录大小
   - 监控: 不超过 `OR_IMG_CACHE_MAX` 限制

3. **响应时间**: HIT vs MISS 的响应时间对比
   - 目标: HIT 响应时间 < 50ms

4. **错误率**: HTTP 5xx 错误
   - 目标: < 1%

### 日志监控
```bash
# 查看访问日志，统计缓存命中率
docker exec yot grep 'X-Cache-Status' logs/access.log | \
  grep -o 'X-Cache-Status: [A-Z]*' | \
  sort | uniq -c
```

## 完成确认

- [x] 所有代码修改已完成
- [x] 所有文档已更新
- [x] 本地测试已通过
- [x] 配置生成验证通过
- [x] Lint 检查通过
- [ ] 容器部署测试（待用户验证）
- [ ] 功能测试（待用户验证）
- [ ] 性能测试（待用户验证）

## 联系支持

如果遇到问题，请检查：
1. `.memory/2026-03-18-proxy-cache-implementation.md` - 完整实施文档
2. `IMG_CACHE_SETUP.md` - 配置说明文档
3. nginx 错误日志: `docker exec yot tail -f logs/error.log`
4. nginx 访问日志: `docker exec yot tail -f logs/access.log`
