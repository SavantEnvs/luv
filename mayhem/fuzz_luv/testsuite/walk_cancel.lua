local t = uv.new_timer()
t:start(1000, 0, function() end)
local n = 0
uv.walk(function(h) n = n + 1 h:close() end)
local req = uv.fs_stat(".", function() end)
if req then req:cancel() end
print(uv.loop_alive(), uv.now(), n)
uv.update_time()
uv.run()
