for i = 1, 20 do
  local t = uv.new_timer()
  t:start(i, i, function() end)
  local a = uv.new_async(function() end)
  a:send()
end
collectgarbage("collect")
uv.run()
collectgarbage("collect")
