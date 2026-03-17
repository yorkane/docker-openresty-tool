-- lib/stat_ffi.lua
-- Shared FFI stat/lstat wrapper for OpenResty (musl libc, Linux).
--
-- Exports:
--   stat_ffi.new()          → arch-appropriate ffi struct (zeroed)
--   stat_ffi.stat(path, st) → int  (0=ok, -1=err)
--   stat_ffi.lstat(path,st) → int  (0=ok, -1=err)
--   stat_ffi.mode(st)       → number (st_mode)
--   stat_ffi.size(st)       → number (st_size)
--   stat_ffi.mtime(st)      → number (st_mtime)
--   stat_ffi.ctime(st)      → number (st_ctime)
--   stat_ffi.is_dir(st)     → bool
--
-- Arch detection is done once at module load time via ffi.arch.
-- All cdef guards use pcall to survive multiple requires in the same worker.

local ffi = require("ffi")
local C   = ffi.C

local _arch = ffi.arch  -- "x64" on x86_64, "arm64" on aarch64

-- ── dirent / opendir / closedir (shared, used by dirapi) ─────────────────
if not pcall(function() return ffi.sizeof("dirent_t") end) then
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

-- ── misc syscalls ─────────────────────────────────────────────────────────
pcall(ffi.cdef, [[
    int mkdir(const char *path, unsigned int mode);
    int rename(const char *oldpath, const char *newpath);
    int unlink(const char *path);
    int rmdir(const char *path);
    int *__errno_location(void);
    char *strerror(int errnum);
]])

-- ── arch-specific stat struct + stat/lstat declarations ──────────────────
local _new, _mode, _size, _mtime, _ctime

if _arch == "x64" then
    -- x86_64 kernel asm/stat.h layout:
    --   dev(8) ino(8) nlink(8) mode(4) uid(4) gid(4) pad0(4)
    --   rdev(8) size(8) blksize(8) blocks(8)
    --   atime(8) atime_ns(8) mtime(8) mtime_ns(8) ctime(8) ctime_ns(8) unused[3](24)
    if not pcall(function() return ffi.sizeof("struct stat_x64_t") end) then
        ffi.cdef[[
        struct stat_x64_t {
            unsigned long  st_dev;         /*   0 */
            unsigned long  st_ino;         /*   8 */
            unsigned long  st_nlink;       /*  16 */
            unsigned int   st_mode;        /*  24 */
            unsigned int   st_uid;         /*  28 */
            unsigned int   st_gid;         /*  32 */
            unsigned int   __pad0;         /*  36 */
            unsigned long  st_rdev;        /*  40 */
            long           st_size;        /*  48 */
            long           st_blksize;     /*  56 */
            long           st_blocks;      /*  64 */
            long           st_atime;       /*  72 */
            unsigned long  st_atime_nsec;  /*  80 */
            long           st_mtime;       /*  88 */
            unsigned long  st_mtime_nsec;  /*  96 */
            long           st_ctime;       /* 104 */
            unsigned long  st_ctime_nsec;  /* 112 */
            long           __unused[3];    /* 120 */
        };
        int stat (const char *path, struct stat_x64_t *buf);
        int lstat(const char *path, struct stat_x64_t *buf);
        ]]
    end
    _new   = function() return ffi.new("struct stat_x64_t") end
    _mode  = function(st) return tonumber(st.st_mode) end
    _size  = function(st) return tonumber(st.st_size) end
    _mtime = function(st) return tonumber(st.st_mtime) end
    _ctime = function(st) return tonumber(st.st_ctime) end

else
    -- aarch64 / asm-generic layout:
    --   dev(8) ino(8) mode(4) nlink(4) uid(4) gid(4) rdev(8) pad1(8)
    --   size(8) blksize(4) pad2(4) blocks(8)
    --   atime(8) atime_ns(8) mtime(8) mtime_ns(8) ctime(8) ctime_ns(8) unused[2](8)
    if not pcall(function() return ffi.sizeof("struct stat_arm64_t") end) then
        ffi.cdef[[
        struct stat_arm64_t {
            unsigned long  st_dev;         /*   0 */
            unsigned long  st_ino;         /*   8 */
            unsigned int   st_mode;        /*  16 */
            unsigned int   st_nlink;       /*  20 */
            unsigned int   st_uid;         /*  24 */
            unsigned int   st_gid;         /*  28 */
            unsigned long  st_rdev;        /*  32 */
            unsigned long  __pad1;         /*  40 */
            long           st_size;        /*  48 */
            int            st_blksize;     /*  56 */
            int            __pad2;         /*  60 */
            long           st_blocks;      /*  64 */
            long           st_atime;       /*  72 */
            unsigned long  st_atime_nsec;  /*  80 */
            long           st_mtime;       /*  88 */
            unsigned long  st_mtime_nsec;  /*  96 */
            long           st_ctime;       /* 104 */
            unsigned long  st_ctime_nsec;  /* 112 */
            unsigned int   __unused[2];    /* 120 */
        };
        int stat (const char *path, struct stat_arm64_t *buf);
        int lstat(const char *path, struct stat_arm64_t *buf);
        ]]
    end
    _new   = function() return ffi.new("struct stat_arm64_t") end
    _mode  = function(st) return tonumber(st.st_mode) end
    _size  = function(st) return tonumber(st.st_size) end
    _mtime = function(st) return tonumber(st.st_mtime) end
    _ctime = function(st) return tonumber(st.st_ctime) end
end

local S_IFMT  = 0xF000
local S_IFDIR = 0x4000

-- ── Public API ────────────────────────────────────────────────────────────
local M = {}

function M.new()          return _new() end
function M.stat(path, st) return C.stat(path, st) end
function M.lstat(path,st) return C.lstat(path, st) end
function M.mode(st)       return _mode(st) end
function M.size(st)       return _size(st) end
function M.mtime(st)      return _mtime(st) end
function M.ctime(st)      return _ctime(st) end
function M.is_dir(st)     return bit.band(_mode(st), S_IFMT) == S_IFDIR end

-- Convenience: stat a path and return a table, or nil on error
function M.stat_path(path)
    local st = _new()
    if C.stat(path, st) ~= 0 then return nil end
    local mode = _mode(st)
    return {
        mode   = mode,
        size   = _size(st),
        mtime  = _mtime(st),
        ctime  = _ctime(st),
        is_dir = bit.band(mode, S_IFMT) == S_IFDIR,
    }
end

return M
