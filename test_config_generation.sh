#!/bin/bash
# Test script to verify nginx configuration generation with envsubst

set -e

echo "=== Testing nginx configuration generation ==="

# Set test environment variables
export OR_IMG_CACHE_VALID="2d"
export OR_IMG_CACHE_MAX="2g"
export OR_IMG_CACHE_INACTIVE="60d"
export OR_IMG_CACHE_PATH="/data/cache"
export OR_IMG_CACHE_BACKGROUND_UPDATE="on"
export OR_IMG_CACHE_USE_STALE="error timeout updating http_500 http_502 http_503 http_504"

echo ""
echo "Environment variables:"
echo "  OR_IMG_CACHE_VALID=$OR_IMG_CACHE_VALID"
echo "  OR_IMG_CACHE_MAX=$OR_IMG_CACHE_MAX"
echo "  OR_IMG_CACHE_INACTIVE=$OR_IMG_CACHE_INACTIVE"
echo "  OR_IMG_CACHE_PATH=$OR_IMG_CACHE_PATH"
echo "  OR_IMG_CACHE_BACKGROUND_UPDATE=$OR_IMG_CACHE_BACKGROUND_UPDATE"
echo "  OR_IMG_CACHE_USE_STALE=$OR_IMG_CACHE_USE_STALE"

echo ""
echo "=== Generating img_cache.set ==="
envsubst '$OR_IMG_CACHE_PATH,$OR_IMG_CACHE_MAX,$OR_IMG_CACHE_INACTIVE,$OR_IMG_CACHE_VALID' < /Users/kate/WorkBuddy/Claw/docker-openresty-tool/nginx/conf/tpl.img_cache.set

echo ""
echo "=== Generating img.conf ==="
envsubst '$OR_IMG_CACHE_VALID,$OR_IMG_CACHE_BACKGROUND_UPDATE,$OR_IMG_CACHE_USE_STALE' < /Users/kate/WorkBuddy/Claw/docker-openresty-tool/nginx/conf/tpl.img.conf

echo ""
echo "=== Configuration generation successful ==="
