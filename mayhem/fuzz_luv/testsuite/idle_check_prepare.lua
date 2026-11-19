local order = {}
local p = uv.new_prepare()
local c = uv.new_check()
local i = uv.new_idle()
p:start(function() order[#order + 1] = "prepare" p:stop() p:close() end)
i:start(function() order[#order + 1] = "idle" i:stop() i:close() end)
c:start(function() order[#order + 1] = "check" c:stop() c:close() end)
uv.run()
uv.run()
