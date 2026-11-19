local d = uv.fs_opendir(".", nil, 4)
if d then
  local ents = d:readdir()
  d:closedir()
  d:readdir()
  d:closedir()
end
local req = uv.fs_scandir(".")
if req then
  local name, kind = uv.fs_scandir_next(req)
  while name do name, kind = uv.fs_scandir_next(req) end
end
