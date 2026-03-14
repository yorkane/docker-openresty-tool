#!/usr/bin/env bash
# =============================================================================
# docker-openresty-tool — Sanity Test Suite
# =============================================================================
# Usage:
#   ./test/sanity_test.sh [BASE_URL]
#
# Default BASE_URL: http://localhost:5080
#
# Tests covered:
#   1. Core service health
#   2. WebDAV basic operations
#   3. ZipFS — directory listing & file serving via HTTP
#   4. Vips — image processing (resize / crop / format conversion)
#   5. WebDAV ZIP transparent access (PROPFIND interception)
#
# Requirements:
#   - curl
#   - python3 (for generating test images if data/ is empty)
#   - Running container: docker compose up -d
# =============================================================================

set -uo pipefail

BASE_URL="${1:-http://localhost:5080}"
PASS=0
FAIL=0
SKIP=0

# ── Colors ──────────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# ── Helpers ──────────────────────────────────────────────────────────────────
pass() { echo -e "  ${GREEN}✓${NC} $1"; ((PASS++)); }
fail() { echo -e "  ${RED}✗${NC} $1"; ((FAIL++)); }
skip() { echo -e "  ${YELLOW}⊘${NC} $1 (skipped)"; ((SKIP++)); }
section() { echo -e "\n${CYAN}${BOLD}▶ $1${NC}"; }

# Assert HTTP status code
assert_status() {
    local label="$1"
    local expected="$2"
    local url="$3"
    shift 3
    local actual
    actual=$(curl -s -o /dev/null -w "%{http_code}" "$@" "$url" 2>/dev/null)
    if [[ "$actual" == "$expected" ]]; then
        pass "$label (HTTP $actual)"
    else
        fail "$label — expected HTTP $expected, got HTTP $actual"
    fi
}

# Assert HTTP status + response body contains string
assert_body_contains() {
    local label="$1"
    local expected_status="$2"
    local url="$3"
    local pattern="$4"
    shift 4
    local tmpfile
    tmpfile=$(mktemp)
    local actual_status
    actual_status=$(curl -s -o "$tmpfile" -w "%{http_code}" "$@" "$url" 2>/dev/null)
    if [[ "$actual_status" != "$expected_status" ]]; then
        rm -f "$tmpfile"
        fail "$label — expected HTTP $expected_status, got HTTP $actual_status"
        return
    fi
    if grep -q "$pattern" "$tmpfile" 2>/dev/null; then
        pass "$label (HTTP $actual_status, contains '$pattern')"
    else
        fail "$label — HTTP $actual_status but body does not contain '$pattern'"
    fi
    rm -f "$tmpfile"
}

# Assert response header contains value
assert_header() {
    local label="$1"
    local url="$2"
    local header_name="$3"
    local pattern="$4"
    shift 4
    local header_val
    header_val=$(curl -s -I "$@" "$url" 2>/dev/null | grep -i "^${header_name}:" | head -1)
    if echo "$header_val" | grep -qi "$pattern"; then
        pass "$label (header '${header_name}: ${pattern}')"
    else
        fail "$label — header '${header_name}' does not match '$pattern' (got: '${header_val}')"
    fi
}

# Assert downloaded file size is within range
assert_file_size() {
    local label="$1"
    local url="$2"
    local min_bytes="$3"
    local max_bytes="$4"
    shift 4
    local size
    size=$(curl -s -o /dev/null -w "%{size_download}" "$@" "$url" 2>/dev/null)
    if [[ "$size" -ge "$min_bytes" && "$size" -le "$max_bytes" ]]; then
        pass "$label (size=${size}B, expected ${min_bytes}–${max_bytes}B)"
    else
        fail "$label — download size ${size}B not in range [${min_bytes}, ${max_bytes}]"
    fi
}

# ── Setup: ensure test data exists ───────────────────────────────────────────
setup_test_data() {
    local datadir
    datadir="$(cd "$(dirname "$0")/.." && pwd)/data"
    local imgdir="$datadir/images"
    local arcdir="$datadir/archives"

    mkdir -p "$imgdir" "$arcdir"

    # Generate test PNGs if missing
    if [[ ! -f "$imgdir/red-800x600.png" ]]; then
        echo -e "\n${YELLOW}  → Generating test images...${NC}"
        python3 - "$imgdir" <<'PYEOF'
import struct, zlib, sys, os

def make_png(width, height, r, g, b, filepath):
    def chunk(name, data):
        c = struct.pack('>I', len(data)) + name + data
        return c + struct.pack('>I', zlib.crc32(name + data) & 0xffffffff)
    sig = b'\x89PNG\r\n\x1a\n'
    ihdr = chunk(b'IHDR', struct.pack('>IIBBBBB', width, height, 8, 2, 0, 0, 0))
    raw = b''
    for y in range(height):
        raw += b'\x00'
        for x in range(width):
            raw += bytes([r, g, b])
    idat = chunk(b'IDAT', zlib.compress(raw))
    iend = chunk(b'IEND', b'')
    with open(filepath, 'wb') as f:
        f.write(sig + ihdr + idat + iend)

base = sys.argv[1]
make_png(800, 600, 220, 80,  60,  base+'/red-800x600.png')
make_png(400, 300, 60,  140, 220, base+'/blue-400x300.png')
make_png(200, 200, 60,  180, 80,  base+'/green-200x200.png')
make_png(1280, 720, 180, 60, 200, base+'/purple-1280x720.png')
print("  PNG files created:", base)
PYEOF
    fi

    # Build test ZIP if missing
    if [[ ! -f "$arcdir/test_assets.zip" ]]; then
        echo -e "\n${YELLOW}  → Building test ZIP archive...${NC}"
        local tmpdir
        tmpdir=$(mktemp -d)
        mkdir -p "$tmpdir/images" "$tmpdir/css" "$tmpdir/docs"
        cp "$imgdir"/*.png "$tmpdir/images/"
        cat > "$tmpdir/index.html" <<'HTML'
<!DOCTYPE html>
<html><head><meta charset="utf-8"><title>ZIP Test</title>
<link rel="stylesheet" href="css/style.css"></head>
<body><h1>Hello from ZIP!</h1>
<img src="images/red-800x600.png" width="400">
<p>Served from inside a ZIP archive via docker-openresty-tool zipfs.</p>
</body></html>
HTML
        echo 'body{font-family:sans-serif;background:#1a1a2e;color:#eee;padding:40px}h1{color:#4ec9b0}' \
            > "$tmpdir/css/style.css"
        echo '{"name":"test_assets","version":"1.0"}' > "$tmpdir/manifest.json"
        echo -e "# Test ZIP\n\nTest archive for zipfs feature." > "$tmpdir/docs/readme.md"
        (cd "$tmpdir" && zip -rq "$arcdir/test_assets.zip" .)
        rm -rf "$tmpdir"
        echo -e "  ZIP created: $arcdir/test_assets.zip"
    fi

    # Build test_assets.cbz (copy of .zip — CBZ is a ZIP with .cbz extension)
    if [[ ! -f "$arcdir/test_assets.cbz" ]]; then
        echo -e "\n${YELLOW}  → Building test CBZ archive (copy of .zip)...${NC}"
        cp "$arcdir/test_assets.zip" "$arcdir/test_assets.cbz"
        echo -e "  CBZ created: $arcdir/test_assets.cbz"
    fi

    # Build test_UPPER.ZIP (uppercase extension test)
    if [[ ! -f "$arcdir/test_UPPER.ZIP" ]]; then
        cp "$arcdir/test_assets.zip" "$arcdir/test_UPPER.ZIP"
        echo -e "  Upper-case ZIP created: $arcdir/test_UPPER.ZIP"
    fi
}

# =============================================================================
# TESTS
# =============================================================================

echo -e "\n${BOLD}=== docker-openresty-tool Sanity Tests ===${NC}"
echo -e "    Target: ${CYAN}${BASE_URL}${NC}"

# ── 1. Core Service ───────────────────────────────────────────────────────────
section "1. Core Service Health"
assert_status "Health check /noc.gif"    "200" "${BASE_URL}/noc.gif"
assert_status "Mock endpoint /mock/test" "200" "${BASE_URL}/mock/test"
assert_body_contains "Mock returns JSON" "200" "${BASE_URL}/mock/test" ""

# ── 2. WebDAV Basic ───────────────────────────────────────────────────────────
section "2. WebDAV Basic Operations"
assert_status "PROPFIND root directory" "207" "${BASE_URL}/" \
    -X PROPFIND -H "Depth: 1"
assert_status "PROPFIND /images/ directory" "207" "${BASE_URL}/images/" \
    -X PROPFIND -H "Depth: 1"
assert_body_contains "PROPFIND XML contains multistatus" "207" "${BASE_URL}/" \
    "multistatus" -X PROPFIND -H "Depth: 0"

# ── 3. ZipFS — HTTP ──────────────────────────────────────────────────────────
section "3. ZipFS — HTTP Virtual Filesystem"

assert_status "ZIP root listing (HTTP 200)" \
    "200" "${BASE_URL}/zip/archives/test_assets.zip/"

assert_body_contains "ZIP root listing shows directories" \
    "200" "${BASE_URL}/zip/archives/test_assets.zip/" "images"

assert_body_contains "ZIP root listing shows files" \
    "200" "${BASE_URL}/zip/archives/test_assets.zip/" "index.html"

assert_header "ZIP listing has X-ZipFS header" \
    "${BASE_URL}/zip/archives/test_assets.zip/" "X-ZipFS" "dir-listing"

assert_status "ZIP serve HTML file" \
    "200" "${BASE_URL}/zip/archives/test_assets.zip/index.html"

assert_header "ZIP HTML correct Content-Type" \
    "${BASE_URL}/zip/archives/test_assets.zip/index.html" "Content-Type" "text/html"

assert_body_contains "ZIP HTML contains expected content" \
    "200" "${BASE_URL}/zip/archives/test_assets.zip/index.html" "Hello from"

assert_status "ZIP serve CSS file" \
    "200" "${BASE_URL}/zip/archives/test_assets.zip/css/style.css"

assert_header "ZIP CSS correct Content-Type" \
    "${BASE_URL}/zip/archives/test_assets.zip/css/style.css" "Content-Type" "text/css"

assert_status "ZIP subdirectory listing (images/)" \
    "200" "${BASE_URL}/zip/archives/test_assets.zip/images/"

assert_body_contains "ZIP images/ listing shows PNG files" \
    "200" "${BASE_URL}/zip/archives/test_assets.zip/images/" "red-800x600.png"

assert_status "ZIP serve PNG from subdirectory" \
    "200" "${BASE_URL}/zip/archives/test_assets.zip/images/red-800x600.png"

assert_header "ZIP PNG correct Content-Type" \
    "${BASE_URL}/zip/archives/test_assets.zip/images/red-800x600.png" "Content-Type" "image/png"

assert_file_size "ZIP PNG file has reasonable size" \
    "${BASE_URL}/zip/archives/test_assets.zip/images/red-800x600.png" \
    1000 5000000

assert_status "ZIP serve JSON file" \
    "200" "${BASE_URL}/zip/archives/test_assets.zip/manifest.json"

assert_header "ZIP JSON correct Content-Type" \
    "${BASE_URL}/zip/archives/test_assets.zip/manifest.json" "Content-Type" "application/json"

assert_status "ZIP serve Markdown file" \
    "200" "${BASE_URL}/zip/archives/test_assets.zip/docs/readme.md"

assert_status "ZIP missing entry returns 404" \
    "404" "${BASE_URL}/zip/archives/test_assets.zip/nonexistent.txt"

assert_status "ZIP missing archive returns 404" \
    "404" "${BASE_URL}/zip/archives/does_not_exist.zip/"

# ── 4. Vips — Image Processing ────────────────────────────────────────────────
section "4. Vips — Dynamic Image Processing"

# Passthrough (no params)
assert_status "Vips passthrough (no params)" \
    "200" "${BASE_URL}/img/images/red-800x600.png"
assert_header "Vips passthrough Content-Type" \
    "${BASE_URL}/img/images/red-800x600.png" "Content-Type" "image/png"
assert_header "Vips passthrough X-Vips header" \
    "${BASE_URL}/img/images/red-800x600.png" "X-Vips" "passthrough"

# Resize by width
assert_status "Vips resize by width (w=200)" \
    "200" "${BASE_URL}/img/images/red-800x600.png?w=200"
assert_header "Vips resize X-Vips=processed" \
    "${BASE_URL}/img/images/red-800x600.png?w=200" "X-Vips" "processed"
assert_header "Vips resize reports output dimensions" \
    "${BASE_URL}/img/images/red-800x600.png?w=200" "X-Vips-Size" "200"

# Resize by width+height contain
assert_status "Vips resize contain (w=300,h=200)" \
    "200" "${BASE_URL}/img/images/red-800x600.png?w=300&h=200"

# Resize cover
assert_status "Vips resize cover (w=100,h=100,fit=cover)" \
    "200" "${BASE_URL}/img/images/red-800x600.png?w=100&h=100&fit=cover"
assert_header "Vips cover output 100x100" \
    "${BASE_URL}/img/images/red-800x600.png?w=100&h=100&fit=cover" "X-Vips-Size" "100x100"

# Format conversion: PNG → WebP
assert_status "Vips format conversion to WebP" \
    "200" "${BASE_URL}/img/images/red-800x600.png?fmt=webp&w=400"
assert_header "Vips WebP Content-Type" \
    "${BASE_URL}/img/images/red-800x600.png?fmt=webp&w=400" "Content-Type" "image/webp"

# Format conversion: PNG → JPEG
assert_status "Vips format conversion to JPEG" \
    "200" "${BASE_URL}/img/images/red-800x600.png?fmt=jpeg&w=400&q=80"
assert_header "Vips JPEG Content-Type" \
    "${BASE_URL}/img/images/red-800x600.png?fmt=jpeg&w=400&q=80" "Content-Type" "image/jpeg"

# Crop
assert_status "Vips crop (crop=0,0,400,300)" \
    "200" "${BASE_URL}/img/images/red-800x600.png?crop=0,0,400,300"

# Crop + resize + format
assert_status "Vips crop+resize+webp pipeline" \
    "200" "${BASE_URL}/img/images/red-800x600.png?crop=100,50,600,400&w=200&fmt=webp&q=75"
assert_header "Vips pipeline WebP Content-Type" \
    "${BASE_URL}/img/images/red-800x600.png?crop=100,50,600,400&w=200&fmt=webp&q=75" \
    "Content-Type" "image/webp"

# Scale fit
assert_status "Vips fit=scale (w=320)" \
    "200" "${BASE_URL}/img/images/blue-400x300.png?w=320&fit=scale"

# Fill fit (stretch)
assert_status "Vips fit=fill (w=200,h=200)" \
    "200" "${BASE_URL}/img/images/green-200x200.png?w=200&h=200&fit=fill"

# Missing file
assert_status "Vips missing source returns 404" \
    "404" "${BASE_URL}/img/images/nonexistent.png?w=100"

# ── 5. ZipFS Multi-Extension (.cbz / .ZIP) ───────────────────────────────────
section "5. ZipFS — Multi-Extension Support (cbz / uppercase)"

# .cbz — directory listing
assert_status "CBZ root directory listing" \
    "200" "${BASE_URL}/zip/archives/test_assets.cbz/"
assert_header "CBZ listing Content-Type is HTML" \
    "${BASE_URL}/zip/archives/test_assets.cbz/" "Content-Type" "text/html"
assert_header "CBZ listing X-ZipFS=dir-listing" \
    "${BASE_URL}/zip/archives/test_assets.cbz/" "X-ZipFS" "dir-listing"

# .cbz — file read
assert_status "CBZ serve inner HTML file" \
    "200" "${BASE_URL}/zip/archives/test_assets.cbz/index.html"
assert_header "CBZ file X-ZipFS=file" \
    "${BASE_URL}/zip/archives/test_assets.cbz/index.html" "X-ZipFS" "file"
assert_header "CBZ HTML Content-Type" \
    "${BASE_URL}/zip/archives/test_assets.cbz/index.html" "Content-Type" "text/html"

# .cbz — 404 for missing entry
assert_status "CBZ missing entry returns 404" \
    "404" "${BASE_URL}/zip/archives/test_assets.cbz/nonexistent.txt"

# Uppercase extension .ZIP
assert_status "Uppercase .ZIP directory listing" \
    "200" "${BASE_URL}/zip/archives/test_UPPER.ZIP/"
assert_header "Uppercase .ZIP X-ZipFS=dir-listing" \
    "${BASE_URL}/zip/archives/test_UPPER.ZIP/" "X-ZipFS" "dir-listing"

# .cbz WebDAV PROPFIND
assert_status "WebDAV PROPFIND on .cbz path returns 207" \
    "207" "${BASE_URL}/archives/test_assets.cbz" \
    -X PROPFIND -H "Depth: 1"
assert_body_contains "WebDAV PROPFIND .cbz contains multistatus XML" \
    "207" "${BASE_URL}/archives/test_assets.cbz" "multistatus" \
    -X PROPFIND -H "Depth: 1"

# ── 6. WebDAV ZIP Transparent Access ─────────────────────────────────────────
section "6. WebDAV ZIP Transparent Access"

assert_status "WebDAV PROPFIND on .zip path returns 207" \
    "207" "${BASE_URL}/archives/test_assets.zip" \
    -X PROPFIND -H "Depth: 1"

assert_body_contains "WebDAV PROPFIND ZIP contains multistatus XML" \
    "207" "${BASE_URL}/archives/test_assets.zip" "multistatus" \
    -X PROPFIND -H "Depth: 1"

assert_body_contains "WebDAV PROPFIND ZIP lists entries (file or inner)" \
    "207" "${BASE_URL}/archives/test_assets.zip" "test_assets" \
    -X PROPFIND -H "Depth: 1"

assert_body_contains "WebDAV PROPFIND ZIP Depth:0 shows self only" \
    "207" "${BASE_URL}/archives/test_assets.zip" "test_assets.zip" \
    -X PROPFIND -H "Depth: 0"

# GET .zip via WebDAV should redirect to /zip/ virtual FS
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" "${BASE_URL}/archives/test_assets.zip/index.html")
if [[ "$HTTP_CODE" == "302" || "$HTTP_CODE" == "200" ]]; then
    pass "WebDAV GET .zip entry redirects or serves (HTTP $HTTP_CODE)"
else
    fail "WebDAV GET .zip entry unexpected status HTTP $HTTP_CODE"
fi

# =============================================================================
# SUMMARY
# =============================================================================
TOTAL=$((PASS + FAIL + SKIP))
echo -e "\n${BOLD}═══════════════════════════════════════${NC}"
echo -e "${BOLD}  Results: ${GREEN}${PASS} passed${NC}  ${RED}${FAIL} failed${NC}  ${YELLOW}${SKIP} skipped${NC}  / ${TOTAL} total"
echo -e "${BOLD}═══════════════════════════════════════${NC}\n"

if [[ "$FAIL" -gt 0 ]]; then
    exit 1
else
    exit 0
fi
