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

function M.truncate(str, max_width)
  if type(str) ~= "string" then
    return ""
  end
  if vim.fn.strdisplaywidth(str) <= max_width then
    return str
  end
  -- strdisplaywidth(strcharpart(str, 0, n) .. "…") is monotonic
  -- non-decreasing in n, so binary-search the longest prefix that still fits
  -- instead of growing the result one character (and one string
  -- concatenation) at a time.
  local lo, hi = 0, vim.fn.strchars(str)
  while lo < hi do
    local mid = math.ceil((lo + hi) / 2)
    if vim.fn.strdisplaywidth(vim.fn.strcharpart(str, 0, mid) .. "…") > max_width then
      hi = mid - 1
    else
      lo = mid
    end
  end
  return vim.fn.strcharpart(str, 0, lo) .. "…"
end

function M.pad_right(str, target_width)
  local dw = vim.fn.strdisplaywidth(str)
  local pad = math.max(0, target_width - dw)
  return str .. string.rep(" ", pad)
end

function M.pad_left(str, target_width)
  local dw = vim.fn.strdisplaywidth(str)
  local pad = math.max(0, target_width - dw)
  return string.rep(" ", pad) .. str
end

function M.format_creators_compact(creators)
  if not creators or #creators == 0 then
    return ""
  end
  local first = creators[1]
  local name
  if first.fieldMode == 0 then
    name = first.lastName or first.firstName or ""
  else
    name = first.lastName or ""
  end
  if #creators > 1 then
    name = name .. " et al."
  end
  return name
end

function M.escape_sql(str)
  if not str then
    return ""
  end
  return str:gsub("'", "''")
end

return M
