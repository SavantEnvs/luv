uv.fs_opendir(".", function(err, dir)
  if dir then
    dir:readdir(function(e, ents)
      dir:closedir(function() end)
    end)
  end
end, 8)
uv.fs_scandir(".", function(err, req) end)
uv.run()
uv.run()
