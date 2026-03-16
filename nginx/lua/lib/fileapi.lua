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
    int *__errno_location(void);
    char *strerror(int errnum);
]])

local C          = ffi.C
local S_IFMT     = 0xF000
local S_IFDIR    = 0x4000
local DT_UNKNOWN = 0
local DT_DIR     = 4
local DT_LNK     = 10

-- Read errno and return "N (description)" string, e.g. "13 (Permission denied)"
local function errmsg()
    local ok, s = pcall(function()
        local eno = C.__errno_location()[0]
        local desc = ffi.string(C.strerror(eno))
        return tostring(eno) .. " (" .. desc .. ")"
    end)
    return ok and s or "?"
end

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
    if C.lstat(full_path, sb) ~= 0 then
        ngx.log(ngx.WARN, "[fileapi] lstat failed for: ", full_path, " errno=", errmsg())
        return false
    end
    local mode = tonumber(sb.st_mode)
    local is_d = bit.band(mode, S_IFMT) == S_IFDIR
    ngx.log(ngx.DEBUG, "[fileapi] lstat fallback: ", full_path,
            " mode=0", string.format("%o", mode), " is_dir=", tostring(is_d))
    return is_d
end

local function rmdir_recursive(path)
    ngx.log(ngx.INFO, "[fileapi] rmdir_recursive enter: ", path)

    local dp = C.opendir(path)
    if dp == nil then
        local e = errmsg()
        ngx.log(ngx.ERR, "[fileapi] opendir failed: ", path, " errno=", e)
        return false, "cannot open directory: " .. path .. " errno=" .. e
    end

    local entry = C.readdir(dp)
    local children = {}
    while entry ~= nil do
        local name = ffi.string(entry.d_name)
        if name ~= "." and name ~= ".." then
            local dtype  = entry.d_type
            local full   = path .. "/" .. name
            local is_dir
            if dtype == DT_DIR then
                -- Fast path: kernel told us it's definitely a directory
                is_dir = true
                ngx.log(ngx.DEBUG, "[fileapi] entry dtype=DT_DIR: ", full)
            else
                -- For DT_LNK, DT_UNKNOWN, or any other value (overlayfs, etc.)
                -- always use lstat to get the ground truth.
                is_dir = lstat_is_dir(full)
                ngx.log(ngx.DEBUG, "[fileapi] entry dtype=", tostring(dtype),
                        " lstat is_dir=", tostring(is_dir), " path=", full)
            end
            children[#children+1] = { name = name, is_dir = is_dir }
        end
        entry = C.readdir(dp)
    end
    C.closedir(dp)

    ngx.log(ngx.INFO, "[fileapi] rmdir_recursive: ", path, " children=", #children)

    for _, child in ipairs(children) do
        local full = path .. "/" .. child.name
        if child.is_dir then
            local ok, msg = rmdir_recursive(full)
            if not ok then return false, msg end
        else
            ngx.log(ngx.DEBUG, "[fileapi] unlink: ", full)
            if C.unlink(full) ~= 0 then
                local e = errmsg()
                ngx.log(ngx.ERR, "[fileapi] unlink failed: ", full, " errno=", e)
                return false, "unlink failed: " .. full .. " errno=" .. e
            end
        end
    end

    ngx.log(ngx.DEBUG, "[fileapi] rmdir: ", path)
    if C.rmdir(path) ~= 0 then
        local e = errmsg()
        ngx.log(ngx.ERR, "[fileapi] rmdir failed: ", path, " errno=", e)
        return false, "rmdir failed: " .. path .. " errno=" .. e
    end

    ngx.log(ngx.INFO, "[fileapi] rmdir_recursive ok: ", path)
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

    ngx.log(ngx.INFO, "[fileapi] DELETE rm: uri=", uri, " user_path=", user_path, " root=", webdav_root)

    local abs, e = resolve_path(webdav_root, user_path)
    if not abs then
        ngx.log(ngx.WARN, "[fileapi] resolve_path failed: ", e)
        return send_json(400, e)
    end

    -- Must not delete webdav_root itself
    if abs == webdav_root then
        ngx.log(ngx.WARN, "[fileapi] attempt to delete webdav root: ", abs)
        return send_json(403, err("forbidden", "cannot delete webdav root"))
    end

    local attr = do_stat(abs)
    if not attr then
        ngx.log(ngx.WARN, "[fileapi] rm: path not found: ", abs)
        return send_json(404, err("not_found", "path not found"))
    end

    ngx.log(ngx.INFO, "[fileapi] rm: abs=", abs, " is_dir=", tostring(attr.is_dir),
            " mode=0", string.format("%o", attr.mode))

    if attr.is_dir then
        local ok, msg = rmdir_recursive(abs)
        if not ok then
            ngx.log(ngx.ERR, "[fileapi] rmdir_recursive failed: ", msg)
            return send_json(500, err("internal", msg or "delete failed"))
        end
    else
        ngx.log(ngx.DEBUG, "[fileapi] unlink file: ", abs)
        if C.unlink(abs) ~= 0 then
            local e2 = errmsg()
            ngx.log(ngx.ERR, "[fileapi] unlink failed: ", abs, " errno=", e2)
            return send_json(500, err("internal", "unlink failed: " .. abs .. " errno=" .. e2))
        end
    end

    ngx.log(ngx.INFO, "[fileapi] rm ok: ", abs)
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

    ngx.log(ngx.INFO, "[fileapi] move: from=", from_path, " to=", to_path, " overwrite=", tostring(overwrite))

    local abs_from, e1 = resolve_path(webdav_root, from_path)
    if not abs_from then
        ngx.log(ngx.WARN, "[fileapi] move: bad from path: ", e1)
        return send_json(400, e1)
    end
    local abs_to, e2 = resolve_path(webdav_root, to_path)
    if not abs_to then
        ngx.log(ngx.WARN, "[fileapi] move: bad to path: ", e2)
        return send_json(400, e2)
    end

    -- Source must exist
    if not do_stat(abs_from) then
        ngx.log(ngx.WARN, "[fileapi] move: source not found: ", abs_from)
        return send_json(404, err("not_found", "source path not found"))
    end

    -- Destination must not exist (unless overwrite=true)
    local dst_attr = do_stat(abs_to)
    if dst_attr and not overwrite then
        ngx.log(ngx.WARN, "[fileapi] move: destination exists and overwrite=false: ", abs_to)
        return send_json(409, err("conflict", "destination already exists; set overwrite:true to replace"))
    end

    -- Ensure parent directory of destination exists
    local dst_parent = abs_to:match("^(.*)/[^/]*$") or webdav_root
    if dst_parent == "" then dst_parent = "/" end
    local ok_p, msg_p = mkdir_p(dst_parent)
    if not ok_p then
        ngx.log(ngx.ERR, "[fileapi] move: mkdir_p failed for parent: ", dst_parent, " err=", msg_p)
        return send_json(500, err("internal", "cannot create destination parent: " .. (msg_p or "")))
    end

    -- rename() works across directories on the same filesystem
    if C.rename(abs_from, abs_to) ~= 0 then
        local e3 = errmsg()
        ngx.log(ngx.ERR, "[fileapi] rename failed: ", abs_from, " -> ", abs_to, " errno=", e3)
        return send_json(500, err("internal", "rename failed: errno=" .. e3))
    end

    ngx.log(ngx.INFO, "[fileapi] move ok: ", abs_from, " -> ", abs_to)
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

    ngx.log(ngx.INFO, "[fileapi] mkdir: user_path=", user_path)

    local abs, e = resolve_path(webdav_root, user_path)
    if not abs then
        ngx.log(ngx.WARN, "[fileapi] mkdir: resolve failed: ", e)
        return send_json(400, e)
    end

    if abs == webdav_root then
        return send_json(409, err("conflict", "webdav root already exists"))
    end

    -- Check if already exists
    local attr = do_stat(abs)
    if attr then
        if attr.is_dir then
            ngx.log(ngx.INFO, "[fileapi] mkdir: already exists (dir): ", abs)
            return send_json(200, OK_JSON)
        else
            ngx.log(ngx.WARN, "[fileapi] mkdir: path exists as file: ", abs)
            return send_json(409, err("conflict", "path exists as a regular file"))
        end
    end

    local ok, msg = mkdir_p(abs)
    if not ok then
        ngx.log(ngx.ERR, "[fileapi] mkdir_p failed: ", abs, " err=", msg)
        return send_json(500, err("internal", msg or "mkdir failed"))
    end

    ngx.log(ngx.INFO, "[fileapi] mkdir ok: ", abs)
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

    ngx.log(ngx.INFO, "[fileapi] upload: user_path=", user_path)

    local abs, e = resolve_path(webdav_root, user_path)
    if not abs then
        ngx.log(ngx.WARN, "[fileapi] upload: resolve failed: ", e)
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
        ngx.log(ngx.DEBUG, "[fileapi] upload: body spooled to file: ", tostring(body_file))
    end

    -- Ensure parent directories exist
    local parent = abs:match("^(.*)/[^/]*$") or webdav_root
    if parent == "" then parent = "/" end
    local ok_p, msg_p = mkdir_p(parent)
    if not ok_p then
        ngx.log(ngx.ERR, "[fileapi] upload: mkdir_p failed for parent: ", parent, " err=", msg_p)
        return send_json(500, err("internal", "cannot create parent directory: " .. (msg_p or "")))
    end

    -- Write file
    local fh, ferr
    if body_file then
        -- Body was spooled to a temp file — copy it
        local src, serr = io.open(body_file, "rb")
        if not src then
            ngx.log(ngx.ERR, "[fileapi] upload: cannot open body temp file: ", tostring(body_file), " err=", tostring(serr))
            return send_json(500, err("internal", "cannot open body temp file: " .. (serr or "")))
        end
        fh, ferr = io.open(abs, "wb")
        if not fh then
            src:close()
            ngx.log(ngx.ERR, "[fileapi] upload: cannot create file: ", abs, " err=", tostring(ferr))
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
            ngx.log(ngx.ERR, "[fileapi] upload: cannot create file: ", abs, " err=", tostring(ferr))
            return send_json(500, err("internal", "cannot create file: " .. (ferr or abs)))
        end
        if body and #body > 0 then
            fh:write(body)
        end
    end

    fh:close()

    local written = do_stat(abs)
    local size    = written and written.size or 0
    ngx.log(ngx.INFO, "[fileapi] upload ok: ", abs, " size=", size)
    return send_json(200, string.format('{"ok":true,"size":%d}', size))
end

return _M
