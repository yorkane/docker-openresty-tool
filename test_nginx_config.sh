#!/bin/bash
# 本地测试脚本 - 验证 nginx 配置生成和语法

set -e

echo "=== 本地测试 nginx 配置生成 ==="

# 设置环境变量（模拟 entrypoint.sh）
export NGX_APP=${NGX_APP:-default_app}
export NGX_PID=${NGX_PID:-test.pid}
export NGX_PORT=${NGX_PORT:-80}
export NGX_HOST=${NGX_HOST:-_}
export NGX_LOG_LEVEL=${NGX_LOG_LEVEL:-warn}
export NGX_DNS=${NGX_DNS:-"local=on valid=60s"}
export NGX_DNS_TIMEOUT=${NGX_DNS_TIMEOUT:-5}
export NGX_CACHE_SIZE=${NGX_CACHE_SIZE:-10m}
export NGX_LS_CACHE_SIZE=${NGX_LS_CACHE_SIZE:-20m}
export NGX_LS_STALE_SIZE=${NGX_LS_STALE_SIZE:-20m}

export OR_IMG_CACHE_VALID=${OR_IMG_CACHE_VALID:-2d}
export OR_IMG_CACHE_MAX=${OR_IMG_CACHE_MAX:-2g}
export OR_IMG_CACHE_INACTIVE=${OR_IMG_CACHE_INACTIVE:-60d}
export OR_IMG_CACHE_PATH=${OR_IMG_CACHE_PATH:-/data/cache}
export OR_IMG_CACHE_BACKGROUND_UPDATE=${OR_IMG_CACHE_BACKGROUND_UPDATE:-on}
export OR_IMG_CACHE_USE_STALE=${OR_IMG_CACHE_USE_STALE:-"error timeout updating http_500 http_502 http_503 http_504"}

# 设置工作目录
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# 创建输出目录
mkdir -p /tmp/nginx-test/conf/inc
mkdir -p /tmp/nginx-test/conf/default_app

echo ""
echo "=== 1. 生成 nginx.conf ==="
envsubst '$NGX_PID,$NGX_CACHE_SIZE,$NGX_LS_CACHE_SIZE,$NGX_LS_STALE_SIZE,$NGX_DNS,$NGX_DNS_TIMEOUT,$NGX_LOG_LEVEL,$NGX_APP,$NGX_HOST,$NGX_PORT' \
  < nginx/conf/tpl.nginx.conf > /tmp/nginx-test/conf/nginx.conf

echo "✅ nginx.conf 生成成功"
echo ""
echo "=== 检查关键变量替换 ==="
grep -E "(lua_shared_dict|resolver|error_log|listen|server_name)" /tmp/nginx-test/conf/nginx.conf | head -10

echo ""
echo "=== 2. 生成 img_cache.set ==="
envsubst '$OR_IMG_CACHE_PATH,$OR_IMG_CACHE_MAX,$OR_IMG_CACHE_INACTIVE,$OR_IMG_CACHE_VALID' \
  < nginx/conf/tpl.img_cache.set > /tmp/nginx-test/conf/inc/img_cache.set

echo "✅ img_cache.set 生成成功"
echo ""
cat /tmp/nginx-test/conf/inc/img_cache.set

echo ""
echo "=== 3. 生成 img.conf ==="
envsubst '$OR_IMG_CACHE_VALID,$OR_IMG_CACHE_BACKGROUND_UPDATE,$OR_IMG_CACHE_USE_STALE' \
  < nginx/conf/tpl.img.conf > /tmp/nginx-test/conf/default_app/img.conf

echo "✅ img.conf 生成成功"
echo ""
cat /tmp/nginx-test/conf/default_app/img.conf

echo ""
echo "=== 4. 检查 main.conf 语法 ==="
# 检查是否有明显的语法错误
if grep -q "^}" nginx/conf/default_app/main.conf; then
  echo "❌ 发现可能的语法错误：多余的 '}'"
  grep -n "^}" nginx/conf/default_app/main.conf
  exit 1
fi

echo "✅ main.conf 语法检查通过"

echo ""
echo "=== 测试完成 ==="
echo "所有配置文件生成成功！"
echo ""
echo "生成的文件位置："
echo "  - /tmp/nginx-test/conf/nginx.conf"
echo "  - /tmp/nginx-test/conf/inc/img_cache.set"
echo "  - /tmp/nginx-test/conf/default_app/img.conf"
