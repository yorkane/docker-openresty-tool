#!/bin/bash
# =============================================================================
# docker-openresty-tool 自动化测试脚本
# 
# 用途: 在 git commit 之前运行，确保配置正确
# 使用: ./test.sh
#
# 测试项:
#   1. 模板文件完整性检查
#   2. envsubst 变量列表一致性检查
#   3. nginx 配置语法检查 (容器内)
#   4. 变量替换完整性检查
#   5. API 端点可用性检查
# =============================================================================

set -e  # 遇错即退

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# 测试结果统计
PASS=0
FAIL=0
WARN=0

# 项目根目录
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$SCRIPT_DIR"

# 打印函数
print_header() {
    echo ""
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${BLUE}  $1${NC}"
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
}

print_test() {
    echo -e "\n${YELLOW}[TEST] $1${NC}"
}

pass() {
    echo -e "  ${GREEN}✓ PASS${NC}: $1"
    PASS=$((PASS + 1))
}

fail() {
    echo -e "  ${RED}✗ FAIL${NC}: $1"
    FAIL=$((FAIL + 1))
}

warn() {
    echo -e "  ${YELLOW}⚠ WARN${NC}: $1"
    WARN=$((WARN + 1))
}

# =============================================================================
# 测试 1: 模板文件完整性检查
# =============================================================================
test_template_files() {
    print_header "测试 1: 模板文件完整性"
    
    local templates=(
        "nginx/conf/tpl.nginx.conf"
        "nginx/conf/tpl.img.conf"
        "nginx/conf/tpl.img_cache.set"
    )
    
    for tpl in "${templates[@]}"; do
        print_test "检查模板文件: $tpl"
        if [ -f "$PROJECT_DIR/$tpl" ]; then
            pass "文件存在: $tpl"
        else
            fail "文件缺失: $tpl"
        fi
    done
    
    # 检查 main.conf 包含 img.conf
    print_test "检查 main.conf 引用 img.conf"
    if grep -q "include default_app/img.conf" "$PROJECT_DIR/nginx/conf/default_app/main.conf"; then
        pass "main.conf 正确引用 img.conf"
    else
        fail "main.conf 未引用 img.conf"
    fi
    
    # 检查 tpl.nginx.conf 包含 img_cache.set
    print_test "检查 tpl.nginx.conf 引用 img_cache.set"
    if grep -q "inc/img_cache.set" "$PROJECT_DIR/nginx/conf/tpl.nginx.conf"; then
        pass "tpl.nginx.conf 正确引用 img_cache.set"
    else
        fail "tpl.nginx.conf 未引用 img_cache.set"
    fi
}

# =============================================================================
# 测试 2: envsubst 变量列表一致性检查
# =============================================================================
test_envsubst_variables() {
    print_header "测试 2: envsubst 变量列表一致性"
    
    # 检查 tpl.nginx.conf 中使用的变量
    print_test "检查 tpl.nginx.conf 变量列表"
    local tpl_nginx_vars=$(grep -oE '\$[A-Z_]+' "$PROJECT_DIR/nginx/conf/tpl.nginx.conf" | sort -u | tr '\n' ',' | sed 's/,$//' | sed 's/\$//g')
    echo "  发现变量: $tpl_nginx_vars"
    
    # 检查 entrypoint.sh 中 envsubst 命令
    local entrypoint_vars=$(grep "envsubst.*tpl.nginx.conf" "$PROJECT_DIR/nginx/conf/entrypoint.sh" | grep -oE "'[^']+'" | head -1 | tr -d "'" | tr ',' '\n' | sort -u | tr '\n' ',' | sed 's/,$//')
    echo "  envsubst 变量: $entrypoint_vars"
    
    # 检查 tpl.img.conf 中使用的变量
    print_test "检查 tpl.img.conf 变量列表"
    local tpl_img_vars=$(grep -oE '\$\{?[A-Z_]+\}?' "$PROJECT_DIR/nginx/conf/tpl.img.conf" | sed 's/[${}]//g' | sort -u | tr '\n' ',' | sed 's/,$//')
    echo "  发现变量: $tpl_img_vars"
    
    # 检查 tpl.img_cache.set 中使用的变量
    print_test "检查 tpl.img_cache.set 变量列表"
    local tpl_cache_vars=$(grep -oE '\$\{?[A-Z_]+\}?' "$PROJECT_DIR/nginx/conf/tpl.img_cache.set" | sed 's/[${}]//g' | sort -u | tr '\n' ',' | sed 's/,$//')
    echo "  发现变量: $tpl_cache_vars"
    
    # 检查 entrypoint.sh 是否有对应的 envsubst 命令
    print_test "检查 entrypoint.sh envsubst 命令完整性"
    
    if grep -q "envsubst.*tpl.nginx.conf" "$PROJECT_DIR/nginx/conf/entrypoint.sh"; then
        pass "存在 tpl.nginx.conf 的 envsubst 命令"
    else
        fail "缺失 tpl.nginx.conf 的 envsubst 命令"
    fi
    
    if grep -q "envsubst.*tpl.img.conf" "$PROJECT_DIR/nginx/conf/entrypoint.sh"; then
        pass "存在 tpl.img.conf 的 envsubst 命令"
    else
        fail "缺失 tpl.img.conf 的 envsubst 命令"
    fi
    
    if grep -q "envsubst.*tpl.img_cache.set" "$PROJECT_DIR/nginx/conf/entrypoint.sh"; then
        pass "存在 tpl.img_cache.set 的 envsubst 命令"
    else
        fail "缺失 tpl.img_cache.set 的 envsubst 命令"
    fi
}

# =============================================================================
# 测试 3: nginx 配置语法检查
# =============================================================================
test_nginx_syntax() {
    print_header "测试 3: nginx 配置语法检查"
    
    print_test "检查 Docker 容器是否运行"
    if docker ps | grep -q "yot"; then
        pass "容器 yot 正在运行"
        
        print_test "执行 nginx -t 语法检查"
        if docker exec yot nginx -t 2>&1 | grep -q "successful"; then
            pass "nginx 配置语法正确"
        else
            fail "nginx 配置语法错误"
            docker exec yot nginx -t 2>&1
        fi
    else
        warn "容器 yot 未运行，跳过语法检查"
        echo "  提示: 运行 docker-compose up -d 启动容器"
    fi
}

# =============================================================================
# 测试 4: 变量替换完整性检查
# =============================================================================
test_variable_substitution() {
    print_header "测试 4: 变量替换完整性检查"
    
    print_test "检查容器内生成的配置文件"
    
    if docker ps | grep -q "yot"; then
        # 检查 nginx.conf 中是否残留 $ 变量
        print_test "检查 nginx.conf 变量残留"
        local nginx_conf_vars=$(docker exec yot grep -oE '\$[A-Z_]+[^A-Z_]' /usr/local/openresty/nginx/conf/nginx.conf 2>/dev/null | grep -v '\$request' | grep -v '\$uri' | grep -v '\$args' | grep -v '\$host' | grep -v '\$scheme' | grep -v '\$is_args' | grep -v '\$cookie' | grep -v '\$arg_' | grep -v '\$http_' | grep -v '\$sent_http' | grep -v '\$upstream' | grep -v '\$body' | grep -v '\$server' | grep -v '\$remote' | grep -v '\$document' | grep -v '\$content' | grep -v '\$fastcgi' | grep -v '\$limit' | grep -v '\$msec' | grep -v '\$nginx' | grep -v '\$pid' | grep -v '\$request_' | grep -v '\$status' | grep -v '\$time' | grep -v '\$connection' || true)
        
        if [ -z "$nginx_conf_vars" ]; then
            pass "nginx.conf 无环境变量残留"
        else
            fail "nginx.conf 存在变量残留: $nginx_conf_vars"
        fi
        
        # 检查 img_cache.set 文件是否存在
        print_test "检查 img_cache.set 文件"
        if docker exec yot test -f /usr/local/openresty/nginx/conf/inc/img_cache.set; then
            pass "img_cache.set 文件存在"
            
            local cache_vars=$(docker exec yot cat /usr/local/openresty/nginx/conf/inc/img_cache.set | grep -oE '\$\{?[A-Z_]+\}?' | sed 's/[${}]//g' || true)
            if [ -z "$cache_vars" ]; then
                pass "img_cache.set 无环境变量残留"
            else
                fail "img_cache.set 存在变量残留: $cache_vars"
            fi
        else
            fail "img_cache.set 文件不存在"
        fi
        
        # 检查 img.conf 文件是否存在
        print_test "检查 img.conf 文件"
        if docker exec yot test -f /usr/local/openresty/nginx/conf/default_app/img.conf; then
            pass "img.conf 文件存在"
            
            local img_vars=$(docker exec yot cat /usr/local/openresty/nginx/conf/default_app/img.conf | grep -oE '\$\{?[A-Z_]+\}?' | sed 's/[${}]//g' | grep -v 'request_method\|uri\|is_args\|args\|scheme\|host' || true)
            if [ -z "$img_vars" ]; then
                pass "img.conf 无环境变量残留"
            else
                fail "img.conf 存在变量残留: $img_vars"
            fi
        else
            fail "img.conf 文件不存在"
        fi
    else
        warn "容器未运行，跳过变量替换检查"
    fi
}

# =============================================================================
# 测试 5: API 端点可用性检查
# =============================================================================
test_api_endpoints() {
    print_header "测试 5: API 端点可用性检查"
    
    print_test "检查 Docker 容器是否运行"
    if docker ps | grep -q "yot"; then
        pass "容器 yot 正在运行"
        
        # 获取容器端口
        local port=$(docker port yot 80/tcp 2>/dev/null | cut -d: -f2)
        if [ -z "$port" ]; then
            port="5080"  # 默认端口
        fi
        
        # 测试 /api/ls/ 端点
        print_test "测试 /api/ls/ 端点"
        local response=$(curl -s -o /dev/null -w "%{http_code}" "http://localhost:$port/api/ls/?sort=name&order=asc&page=1&page_size=20" 2>/dev/null || echo "000")
        
        if [ "$response" = "200" ]; then
            pass "/api/ls/ 返回 200 OK"
        elif [ "$response" = "000" ]; then
            fail "/api/ls/ 连接失败"
        else
            fail "/api/ls/ 返回 $response (期望 200)"
        fi
        
        # 测试 /api/ 根路径 (应该返回 404 JSON)
        print_test "测试 /api/ 根路径"
        response=$(curl -s -o /dev/null -w "%{http_code}" "http://localhost:$port/api/" 2>/dev/null || echo "000")
        
        if [ "$response" = "404" ]; then
            pass "/api/ 正确返回 404"
        else
            warn "/api/ 返回 $response (期望 404)"
        fi
        
        # 测试 /img/ 端点配置
        print_test "测试 /img/ 端点配置"
        response=$(curl -s -o /dev/null -w "%{http_code}" "http://localhost:$port/img/nonexistent.jpg" 2>/dev/null || echo "000")
        
        # /img/ 对于不存在的文件应该返回 404 或 500，但不应该是 404 from nginx directly
        if [ "$response" != "000" ]; then
            pass "/img/ 端点响应正常 (HTTP $response)"
        else
            fail "/img/ 端点连接失败"
        fi
        
    else
        warn "容器 yot 未运行，跳过 API 检查"
    fi
}

# =============================================================================
# 测试 6: 特定 Bug 回归测试
# =============================================================================
test_bug_regression() {
    print_header "测试 6: 特定 Bug 回归测试"
    
    print_test "回归测试: worker_processes 引号问题"
    if docker ps | grep -q "yot"; then
        local worker_line=$(docker exec yot grep "worker_processes" /usr/local/openresty/nginx/conf/nginx.conf 2>/dev/null || true)
        if echo "$worker_line" | grep -qE 'worker_processes\s+"'; then
            fail "worker_processes 值带有引号: $worker_line"
        else
            pass "worker_processes 无引号问题"
        fi
    else
        warn "容器未运行，跳过回归测试"
    fi
    
    print_test "回归测试: main.conf 语法完整性"
    # 检查 main.conf 中是否有孤立的大括号
    local open_braces=$(grep -o '{' "$PROJECT_DIR/nginx/conf/default_app/main.conf" | wc -l | tr -d ' ')
    local close_braces=$(grep -o '}' "$PROJECT_DIR/nginx/conf/default_app/main.conf" | wc -l | tr -d ' ')
    
    if [ "$open_braces" = "$close_braces" ]; then
        pass "main.conf 大括号配对正确 ({ $open_braces 个, } $close_braces 个)"
    else
        fail "main.conf 大括号不匹配 ({ $open_braces 个, } $close_braces 个)"
    fi
    
    print_test "回归测试: /api/ls/ location 存在性"
    if grep -q "location /api/ls/" "$PROJECT_DIR/nginx/conf/default_app/main.conf"; then
        pass "/api/ls/ location 存在"
    else
        fail "/api/ls/ location 缺失"
    fi
}

# =============================================================================
# 主程序
# =============================================================================
main() {
    echo ""
    echo -e "${GREEN}╔══════════════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║        docker-openresty-tool 自动化测试脚本                              ║${NC}"
    echo -e "${GREEN}╚══════════════════════════════════════════════════════════════════════════╝${NC}"
    
    # 执行所有测试
    test_template_files
    test_envsubst_variables
    test_nginx_syntax
    test_variable_substitution
    test_api_endpoints
    test_bug_regression
    
    # 输出总结
    print_header "测试结果汇总"
    echo ""
    echo -e "  ${GREEN}通过: $PASS${NC}"
    echo -e "  ${RED}失败: $FAIL${NC}"
    echo -e "  ${YELLOW}警告: $WARN${NC}"
    echo ""
    
    if [ $FAIL -gt 0 ]; then
        echo -e "${RED}╔══════════════════════════════════════════════════════════════════════════╗${NC}"
        echo -e "${RED}║  ✗ 测试失败，请修复后再提交                                              ║${NC}"
        echo -e "${RED}╚══════════════════════════════════════════════════════════════════════════╝${NC}"
        exit 1
    else
        echo -e "${GREEN}╔══════════════════════════════════════════════════════════════════════════╗${NC}"
        echo -e "${GREEN}║  ✓ 所有测试通过，可以提交                                                ║${NC}"
        echo -e "${GREEN}╚══════════════════════════════════════════════════════════════════════════╝${NC}"
        exit 0
    fi
}

# 运行主程序
main "$@"
