local a
a = uv.new_async(function(x, y)
  a:close()
end)
a:send(1, "two")
uv.run()
uv.run()
