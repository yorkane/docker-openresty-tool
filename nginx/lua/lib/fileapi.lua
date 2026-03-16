-- lib/fileapi.lua
-- File management JSON API for OpenResty
--
-- Routes (all under /api/, never conflict with WebDAV at /):
--
--   DELETE /api/rm/<path>
--       Delete a file or directory (directories deleted recursively).
--       Returns 200 on success.
--
--   POST   /api/move
--       Move or rename a file/directory.
--       Request body (application/json): {"from": "/src/path", "to": "/dst/path"}
--       "overwrite": true   may be added to allow clobbering an existing target.
--       Returns 200 on success.
--
--   POST   /api/mkdir/<path>
--       Create a directory (and all missing parents, like mkdir -p).
--       Returns 200 on success, 409 if a non-directory already occupies the path.
--
--   POST   /api/upload/<path>
--       Upload / overwrite a single file.
--       Request body: raw file bytes (any Content-Type).
--       Parent directories are created automatically.
--       Returns 200 on success.
--
-- All endpoints share:
--   • 400  bad_request   — path traversal (..) detected; invalid JSON body
--   • 403  forbidden     — attempt to escape webdav_root
--   • 404  not_found     — source path does not exist (rm / move)
--   • 409  conflict      — target already exists and overwrite not requested;
--                          mkdir on a path that exists as a regular file
--   • 500  internal      — OS / syscall error
--
-- Error response body:
--   { "error": "<code>", "message": "<detail>" }
--
-- Success response body (all):
--   { "ok": true }
--   (Additional fields may appear — see each handler.)
--
-- Path rules:
--   Paths are always relative to webdav_root (nginx $webdav_root variable).
--   Leading/trailing slashes are tolerated.
--   ".." components are rejected with 400.
--   Paths that would escape webdav_root after resolution are rejected with 403.
--
-- Env vars (read from env.lua, same pattern as dirapi.lua):
--   OR_FILEAPI_DISABLE  — set to "true" to disable all fileapi endpoints (returns 403)

local _M = {}

-- ──────────────────────────────────────────────────────────
-- FFI: stat, mkdir, rename, unlink, rmdir (musl libc)
-- ──────────────────────────────────────────────────────────
local ffi = require("ffi")

-- Guard against duplicate cdef across hot-reloads.
-- We reuse the stat_t defined by dirapi if it was already loaded; otherwise define it.
if not pcall(function() return ffi.sizeof("struct stat_t") end) then
    ffi.cdef[[
    struct stat_t {
        unsigned long  st_dev;
        unsigned long  st_ino;
        unsigned int   st_mode;
        unsigned int   st_nlink;
        unsigned int   st_uid;
        unsigned int   st_gid;
        unsigned long  st_rdev;
        unsigned long  __pad1;
        long           st_size;
        int            st_blksize;
        int            __pad2;
        long           st_blocks;
        long           st_atime;
        unsigned long  st_atime_nsec;
        long           st_mtime;
        unsigned long  st_mtime_nsec;
        long           st_ctime;
        unsigned long  st_ctime_nsec;
        unsigned int   __unused[2];
    };
    int stat(const char *path, struct stat_t *buf);
    ]]
end

-- These syscall wrappers are always safe to re-declare (they're just type aliases).
if not pcall(function() ffi.sizeof("DIR") end) then
    ffi.cdef[[
    typedef void DIR;
    typedef struct {
        unsigned long  d_ino;
        long           d_off;
        unsigned short d_reclen;
        unsigned char  d_type;
        char           d_name[256];
    } dirent_t;
    DIR*      opendir(const char *name);
    dirent_t *readdir(DIR *dp);
    int       closedir(DIR *dp);
    ]]
end

-- Additional syscalls needed only by fileapi
-- Wrap in pcall to tolerate multiple requires in the same worker.
pcall(ffi.cdef, [[
    int mkdir(const char *path, unsigned int mode);
    int rename(const char *oldpath, const char *newpath);
    int unlink(const char *path);
    int rmdir(const char *path);
    int lstat(const char *path, struct stat_t *buf);
]])

local C          = ffi.C
local S_IFMT     = 0xF000
local S_IFDIR    = 0x4000
local DT_UNKNOWN = 0
local DT_DIR     = 4
local DT_LNK     = 10

-- ──────────────────────────────────────────────────────────
-- Helpers
-- ──────────────────────────────────────────────────────────

local function send_json(status, body)
    ngx.status = status
    ngx.header["Content-Type"]           = "application/json; charset=utf-8"
    ngx.header["Cache-Control"]          = "no-store"
    ngx.header["X-Content-Type-Options"] = "nosniff"
    ngx.print(body)
    ngx.exit(status)
end

local function json_str(s)
    s = tostring(s or "")
    s = s:gsub('\\','\\\\'):gsub('"','\\"')
           :gsub('\n','\\n'):gsub('\r','\\r'):gsub('\t','\\t')
    return '"' .. s .. '"'
end

local function err(code, msg)
    return string.format('{"error":%s,"message":%s}', json_str(code), json_str(msg))
end

local OK_JSON = '{"ok":true}'

-- stat a path; returns table or nil
local function do_stat(path)
    local st = ffi.new("struct stat_t")
    if C.stat(path, st) ~= 0 then return nil end
    return {
        size   = tonumber(st.st_size),
        mode   = tonumber(st.st_mode),
        is_dir = bit.band(tonumber(st.st_mode), S_IFMT) == S_IFDIR,
    }
end

-- Validate and resolve a user-supplied relative path into an absolute FS path.
-- Returns: abs_path, nil          on success
--          nil,      err_body_str on failure (caller should send 400/403)
local function resolve_path(webdav_root, user_path)
    -- Reject path traversal
    if user_path:find("%.%.") then
        return nil, err("bad_request", "path traversal not allowed")
    end

    -- Normalise: collapse multiple slashes, strip trailing slash
    local rel = user_path:gsub("//+", "/"):gsub("/+$", "")
    if rel == "" then rel = "/" end

    -- Build absolute path
    local abs
    if rel == "/" then
        abs = webdav_root
    else
        -- rel must start with / at this point
        if rel:sub(1,1) ~= "/" then rel = "/" .. rel end
        abs = webdav_root .. rel
    end

    -- Safety: resolved path must stay within webdav_root
    if abs:sub(1, #webdav_root) ~= webdav_root then
        return nil, err("forbidden", "path outside webdav root")
    end

    return abs, nil
end

-- Check if fileapi is disabled
local function is_disabled()
    local ok, env = pcall(require, "env")
    if ok and env and env.OR_FILEAPI_DISABLE == "true" then
        return true
    end
    return false
end

-- ──────────────────────────────────────────────────────────
-- Tiny JSON body parser (only for move endpoint)
-- Parses {"from": "...", "to": "...", "overwrite": true/false}
-- No external cjson dependency.
-- ──────────────────────────────────────────────────────────
local function parse_move_body(body)
    -- Extract "from" value
    local from = body:match('"from"%s*:%s*"(.-[^\\])"')
                 or body:match('"from"%s*:%s*"()"')  -- empty string edge
    -- Extract "to" value
    local to   = body:match('"to"%s*:%s*"(.-[^\\])"')
                 or body:match('"to"%s*:%s*"()"')
    -- Extract optional "overwrite" boolean
    local ow_str = body:match('"overwrite"%s*:%s*(true|false)')
    local overwrite = (ow_str == "true")
    return from, to, overwrite
end

-- ──────────────────────────────────────────────────────────
-- Recursive directory removal (pure Lua, uses FFI readdir)
-- Returns true on success, or false + message on error.
-- ──────────────────────────────────────────────────────────
-- lstat_is_dir: use lstat (does NOT follow symlinks) to check if path is a directory.
-- Used as fallback when d_type == DT_UNKNOWN.
local function lstat_is_dir(full_path)
    local sb = ffi.new("struct stat_t")
    if C.lstat(full_path, sb) ~= 0 then return false end
    return bit.band(sb.st_mode, S_IFMT) == S_IFDIR
end

local function rmdir_recursive(path)
    local dp = C.opendir(path)
    if dp == nil then
        return false, "cannot open directory: " .. path
    end

    local entry = C.readdir(dp)
    local children = {}
    while entry ~= nil do
        local name = ffi.string(entry.d_name)
        if name ~= "." and name ~= ".." then
            local dtype  = entry.d_type
            local full   = path .. "/" .. name
            -- DT_LNK (10): symlink — always unlink, never recurse into it.
            -- DT_UNKNOWN (0): filesystem doesn't populate d_type (e.g. some NFS mounts,
            --   XFS with no dir_index) — fall back to lstat to determine the real type.
            local is_dir
            if dtype == DT_LNK then
                is_dir = false
            elseif dtype == DT_UNKNOWN then
                is_dir = lstat_is_dir(full)
            else
                is_dir = (dtype == DT_DIR)
            end
            children[#children+1] = { name = name, is_dir = is_dir }
        end
        entry = C.readdir(dp)
    end
    C.closedir(dp)

    for _, child in ipairs(children) do
        local full = path .. "/" .. child.name
        if child.is_dir then
            local ok, msg = rmdir_recursive(full)
            if not ok then return false, msg end
        else
            if C.unlink(full) ~= 0 then
                return false, "unlink failed: " .. full
            end
        end
    end

    if C.rmdir(path) ~= 0 then
        return false, "rmdir failed: " .. path
    end
    return true, nil
end

-- ──────────────────────────────────────────────────────────
-- mkdir -p  (creates all missing intermediate directories)
-- Returns true on success, or false + message on error.
-- ──────────────────────────────────────────────────────────
local function mkdir_p(path)
    -- Walk from root to target, creating missing segments
    local parts = {}
    for seg in path:gmatch("[^/]+") do
        parts[#parts+1] = seg
    end

    local current = ""
    for _, seg in ipairs(parts) do
        current = current .. "/" .. seg
        local attr = do_stat(current)
        if attr then
            if not attr.is_dir then
                return false, "path component is not a directory: " .. current
            end
            -- directory already exists — continue
        else
            -- 0755 in octal = 493 decimal
            if C.mkdir(current, 493) ~= 0 then
                return false, "mkdir failed: " .. current
            end
        end
    end
    return true, nil
end

-- ──────────────────────────────────────────────────────────
-- Handler: DELETE /api/rm/<path>
-- ──────────────────────────────────────────────────────────
function _M.handle_rm(webdav_root)
    webdav_root = (webdav_root or "/webdav"):gsub("/+$", "")

    if is_disabled() then
        return send_json(403, err("forbidden", "fileapi is disabled"))
    end

    -- Extract path from URI  /api/rm/<path>
    local uri      = ngx.var.uri
    local user_path = uri:match("^/api/rm(/?.*)$") or "/"
    if user_path == "" then user_path = "/" end

    local abs, e = resolve_path(webdav_root, user_path)
    if not abs then
        return send_json(400, e)
    end

    -- Must not delete webdav_root itself
    if abs == webdav_root then
        return send_json(403, err("forbidden", "cannot delete webdav root"))
    end

    local attr = do_stat(abs)
    if not attr then
        return send_json(404, err("not_found", "path not found"))
    end

    if attr.is_dir then
        local ok, msg = rmdir_recursive(abs)
        if not ok then
            return send_json(500, err("internal", msg or "delete failed"))
        end
    else
        if C.unlink(abs) ~= 0 then
            return send_json(500, err("internal", "unlink failed: " .. abs))
        end
    end

    return send_json(200, OK_JSON)
end

-- ──────────────────────────────────────────────────────────
-- Handler: POST /api/move
-- Body: {"from": "/src", "to": "/dst"}
-- ──────────────────────────────────────────────────────────
function _M.handle_move(webdav_root)
    webdav_root = (webdav_root or "/webdav"):gsub("/+$", "")

    if is_disabled() then
        return send_json(403, err("forbidden", "fileapi is disabled"))
    end

    -- Read body
    ngx.req.read_body()
    local body = ngx.req.get_body_data() or ""
    if body == "" then
        return send_json(400, err("bad_request", "request body is empty"))
    end

    local from_path, to_path, overwrite = parse_move_body(body)
    if not from_path or from_path == "" then
        return send_json(400, err("bad_request", "missing 'from' field"))
    end
    if not to_path or to_path == "" then
        return send_json(400, err("bad_request", "missing 'to' field"))
    end

    local abs_from, e1 = resolve_path(webdav_root, from_path)
    if not abs_from then
        return send_json(400, e1)
    end
    local abs_to, e2 = resolve_path(webdav_root, to_path)
    if not abs_to then
        return send_json(400, e2)
    end

    -- Source must exist
    if not do_stat(abs_from) then
        return send_json(404, err("not_found", "source path not found"))
    end

    -- Destination must not exist (unless overwrite=true)
    local dst_attr = do_stat(abs_to)
    if dst_attr and not overwrite then
        return send_json(409, err("conflict", "destination already exists; set overwrite:true to replace"))
    end

    -- Ensure parent directory of destination exists
    local dst_parent = abs_to:match("^(.*)/[^/]*$") or webdav_root
    if dst_parent == "" then dst_parent = "/" end
    local ok_p, msg_p = mkdir_p(dst_parent)
    if not ok_p then
        return send_json(500, err("internal", "cannot create destination parent: " .. (msg_p or "")))
    end

    -- rename() works across directories on the same filesystem
    if C.rename(abs_from, abs_to) ~= 0 then
        return send_json(500, err("internal", "rename failed"))
    end

    return send_json(200, OK_JSON)
end

-- ──────────────────────────────────────────────────────────
-- Handler: POST /api/mkdir/<path>
-- ──────────────────────────────────────────────────────────
function _M.handle_mkdir(webdav_root)
    webdav_root = (webdav_root or "/webdav"):gsub("/+$", "")

    if is_disabled() then
        return send_json(403, err("forbidden", "fileapi is disabled"))
    end

    local uri       = ngx.var.uri
    local user_path = uri:match("^/api/mkdir(/?.*)$") or "/"
    if user_path == "" then user_path = "/" end

    local abs, e = resolve_path(webdav_root, user_path)
    if not abs then
        return send_json(400, e)
    end

    if abs == webdav_root then
        return send_json(409, err("conflict", "webdav root already exists"))
    end

    -- Check if already exists
    local attr = do_stat(abs)
    if attr then
        if attr.is_dir then
            -- Already a directory — idempotent, return 200
            return send_json(200, OK_JSON)
        else
            return send_json(409, err("conflict", "path exists as a regular file"))
        end
    end

    local ok, msg = mkdir_p(abs)
    if not ok then
        return send_json(500, err("internal", msg or "mkdir failed"))
    end

    return send_json(200, OK_JSON)
end

-- ──────────────────────────────────────────────────────────
-- Handler: POST /api/upload/<path>
-- Body: raw file bytes
-- ──────────────────────────────────────────────────────────
function _M.handle_upload(webdav_root)
    webdav_root = (webdav_root or "/webdav"):gsub("/+$", "")

    if is_disabled() then
        return send_json(403, err("forbidden", "fileapi is disabled"))
    end

    local uri       = ngx.var.uri
    local user_path = uri:match("^/api/upload(/?.*)$") or "/"
    if user_path == "" then user_path = "/" end

    local abs, e = resolve_path(webdav_root, user_path)
    if not abs then
        return send_json(400, e)
    end

    -- Must not be a directory path (trailing slash means they want a dir)
    if user_path:sub(-1) == "/" then
        return send_json(400, err("bad_request", "upload path must not end with '/' (use /api/mkdir for directories)"))
    end

    -- Read request body (supports both buffered and file-backed bodies)
    ngx.req.read_body()
    local body = ngx.req.get_body_data()
    local body_file

    if not body then
        body_file = ngx.req.get_body_file()
    end

    -- Ensure parent directories exist
    local parent = abs:match("^(.*)/[^/]*$") or webdav_root
    if parent == "" then parent = "/" end
    local ok_p, msg_p = mkdir_p(parent)
    if not ok_p then
        return send_json(500, err("internal", "cannot create parent directory: " .. (msg_p or "")))
    end

    -- Write file
    local fh, ferr
    if body_file then
        -- Body was spooled to a temp file — copy it
        local src, serr = io.open(body_file, "rb")
        if not src then
            return send_json(500, err("internal", "cannot open body temp file: " .. (serr or "")))
        end
        fh, ferr = io.open(abs, "wb")
        if not fh then
            src:close()
            return send_json(500, err("internal", "cannot create file: " .. (ferr or abs)))
        end
        while true do
            local chunk = src:read(65536)
            if not chunk then break end
            fh:write(chunk)
        end
        src:close()
    else
        -- Body is in memory (may be nil for empty upload)
        fh, ferr = io.open(abs, "wb")
        if not fh then
            return send_json(500, err("internal", "cannot create file: " .. (ferr or abs)))
        end
        if body and #body > 0 then
            fh:write(body)
        end
    end

    fh:close()

    local written = do_stat(abs)
    local size    = written and written.size or 0
    return send_json(200, string.format('{"ok":true,"size":%d}', size))
end

return _M
