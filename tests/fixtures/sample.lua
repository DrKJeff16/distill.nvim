local function run(x)
  log.info("start") -- @log
  logger:debug( -- @log
    "multi",
    x
  )
  print("print") -- @print
  vim.notify("hi") -- @print
  local y = math.log(x)
  return y
end
