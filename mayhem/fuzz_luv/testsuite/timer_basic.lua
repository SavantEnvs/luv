local t = uv.new_timer()
local n = 0
t:start(0, 1, function()
  n = n + 1
  if n >= 3 then t:stop() t:close() end
end)
uv.run()
