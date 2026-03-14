local ffi = require('ffi')
ffi.cdef[[
typedef void DIR;
typedef struct {
  unsigned long  d_ino; long d_off; unsigned short d_reclen;
  unsigned char  d_type; char d_name[256];
} dirent_t;
DIR* opendir(const char*); dirent_t* readdir(DIR*); int closedir(DIR*);
struct stat_t {
  unsigned long st_dev; unsigned long st_ino; unsigned long st_nlink;
  unsigned int st_mode; unsigned int st_uid; unsigned int st_gid;
  unsigned int __pad0;  unsigned long st_rdev; long st_size;
  long st_blksize; long st_blocks;
  long st_atime; long st_atime_ns;
  long st_mtime; long st_mtime_ns;
  long st_ctime; long st_ctime_ns;
  long __unused[3];
};
int stat(const char*, struct stat_t*);
]]
local C = ffi.C
local S_IFMT  = 0xF000
local S_IFDIR = 0x4000
-- test /webdav dir
local st = ffi.new('struct stat_t')
local r = C.stat('/webdav', st)
print('stat /webdav r=', r)
print('mode octal =', string.format('%o', tonumber(st.st_mode)))
print('is_dir =', bit.band(tonumber(st.st_mode), S_IFMT) == S_IFDIR)
print('size =', tonumber(st.st_size))
print('mtime =', tonumber(st.st_mtime))
print('ctime =', tonumber(st.st_ctime))
-- test opendir
local dp = C.opendir('/webdav')
print('opendir dp=', dp ~= nil)
local e = C.readdir(dp)
while e ~= nil do
  local name = ffi.string(e.d_name)
  if name ~= '.' and name ~= '..' then
    local st2 = ffi.new('struct stat_t')
    C.stat('/webdav/'..name, st2)
    print(' entry:', name, 'dtype:', tonumber(e.d_type),
          'mode:', string.format('%o', tonumber(st2.st_mode)),
          'is_dir:', bit.band(tonumber(st2.st_mode), S_IFMT) == S_IFDIR,
          'size:', tonumber(st2.st_size))
  end
  e = C.readdir(dp)
end
C.closedir(dp)
print('done')
