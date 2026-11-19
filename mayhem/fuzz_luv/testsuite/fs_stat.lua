local st = uv.fs_stat("/etc/passwd")
if st then assert(st.type == "file") end
assert(uv.fs_stat("/nonexistent/path") == nil)
local fd = uv.fs_open("/etc/hostname", "r", 438)
if fd then
  local data = uv.fs_read(fd, 64, 0)
  local st2 = uv.fs_fstat(fd)
  uv.fs_close(fd)
end
print(uv.fs_realpath("."), uv.fs_access(".", "R"), uv.fs_readlink("/proc/self/exe"))
uv.fs_stat(".", function(err, stat) end)
uv.fs_lstat(".", function(err, stat) end)
uv.fs_statfs(".", function(err, stat) end)
uv.run()
