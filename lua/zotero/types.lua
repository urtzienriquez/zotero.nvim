local M = {}

function M.format_creators(creators)
  if not creators or #creators == 0 then
    return ""
  end
  local names = {}
  for _, c in ipairs(creators) do
    if c.fieldMode == 0 then
      table.insert(names, (c.firstName or "") .. " " .. (c.lastName or ""))
    else
      table.insert(names, c.lastName or "")
    end
  end
  return table.concat(names, "; ")
end

function M.extract_year(date_str)
  if type(date_str) ~= "string" then
    return ""
  end
  return date_str:match("^(%d%d%d%d)") or ""
end

function M.truncate(str, len)
  if type(str) ~= "string" then
    return ""
  end
  if #str <= len then
    return str
  end
  return str:sub(1, len - 1) .. "…"
end

function M.escape_sql(str)
  if not str then
    return ""
  end
  return str:gsub("'", "''")
end

return M
