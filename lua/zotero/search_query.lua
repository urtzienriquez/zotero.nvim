-- Parser for the items-pane search (`ff`). Pure: no DB or UI access.
--
--   a b            both must match; `a AND b` and `a & b` say the same
--   "a phrase"     exact phrase
--   a OR b, a | b  either (binds tighter than AND:
--                  `x a OR b` is x AND (a OR b))
--   -a, -"a b"     exclude
--   note:a         search child notes and PDF annotations instead
--   ft:a           search the full text of indexed PDFs instead
--   author:a, title:a, year:a, tag:a, pub:a, abstract:a, doi:a, citekey:a
--                  search only that field
--   author:"a OR b c AND d"
--                  inside a prefixed quote, OR / | and AND / & combine
--                  words and phrases for that one field (here: ("a" or
--                  the phrase "b c") and "d"); with no operator it is a
--                  single phrase
--
-- Anything that doesn't parse as an operator (a lone OR/AND, a bare `-`,
-- an unbalanced quote, an empty `note:`) is searched for literally.
--
-- parse() returns a list of AND-groups, each a list of OR-alternatives
-- (terms). A term has a scope ("meta" when unprefixed), a negate flag, and
-- its own AND-of-ORs of values (one value unless it's a prefixed quote with
-- operators); `-` negates the whole term:
--   { { { scope = "author", negate = false,
--         groups = { { { text = "huey", phrase = false } } } }, ... }, ... }
local M = {}

local SCOPES = {}
for _, s in ipairs({ "note", "ft", "author", "title", "year", "tag", "pub", "abstract", "doi", "citekey" }) do
  SCOPES[s] = s
end

-- Splits the query into raw tokens, keeping quoted phrases (with any `-` or
-- scope prefix glued to them) in one piece.
local function tokenize(str)
  local tokens = {}
  local i, n = 1, #str
  while i <= n do
    local c = str:sub(i, i)
    if c:match("%s") then
      i = i + 1
    else
      local start = i
      -- Walk over a prefix (`-`, `scope:`) that may precede a quote.
      local j = i
      if str:sub(j, j) == "-" then
        j = j + 1
      end
      local scope = str:sub(j):match("^(%a+):")
      if scope and SCOPES[scope:lower()] then
        j = j + #scope + 1
      end
      if str:sub(j, j) == '"' then
        local close = str:find('"', j + 1, true)
        if close then
          tokens[#tokens + 1] = str:sub(start, close)
          i = close + 1
        else
          -- Unbalanced quote: take the rest of the word literally.
          local e = str:find("%s", j) or (n + 1)
          tokens[#tokens + 1] = str:sub(start, e - 1)
          i = e
        end
      else
        local e = str:find("%s", i) or (n + 1)
        tokens[#tokens + 1] = str:sub(start, e - 1)
        i = e
      end
    end
  end
  return tokens
end

local function is_or(tok)
  return tok == "OR" or tok == "|"
end

local function is_and(tok)
  return tok == "AND" or tok == "&"
end

local function is_op(tok)
  return is_or(tok) or is_and(tok)
end

-- The groups of a prefixed quote: OR / | separate alternatives, AND / &
-- separate groups that must all match, and the words in between form a
-- word or (several words) a phrase. With no operator in it, the whole quote
-- is one phrase, as without a prefix.
local function quoted_groups(inner)
  local groups, alts, words = {}, {}, {}
  local has_op = false
  local function flush_words()
    if #words > 0 then
      alts[#alts + 1] = { text = table.concat(words, " "), phrase = #words > 1 }
    end
    words = {}
  end
  local function flush_group()
    flush_words()
    if #alts > 0 then
      groups[#groups + 1] = alts
    end
    alts = {}
  end
  for w in inner:gmatch("%S+") do
    if is_or(w) then
      has_op = true
      flush_words()
    elseif is_and(w) then
      has_op = true
      flush_group()
    else
      words[#words + 1] = w
    end
  end
  flush_group()
  if not has_op or #groups == 0 then
    return { { { text = inner, phrase = true } } }
  end
  return groups
end

-- Turns one raw token into a term, or nil when nothing is left to search.
local function to_term(tok)
  local term = { negate = false, scope = "meta" }
  local rest = tok
  if #rest > 1 and rest:sub(1, 1) == "-" then
    term.negate = true
    rest = rest:sub(2)
  end
  local scope, after = rest:match("^(%a+):(.*)$")
  if scope and SCOPES[scope:lower()] and after ~= "" then
    term.scope = SCOPES[scope:lower()]
    rest = after
  end
  local inner = rest:match('^"(.*)"$')
  if inner and #rest >= 2 then
    inner = vim.trim(inner)
    if inner == "" then
      return nil
    end
    term.groups = term.scope == "meta" and { { { text = inner, phrase = true } } } or quoted_groups(inner)
  else
    term.groups = { { { text = rest, phrase = false } } }
  end
  return term
end

function M.parse(str)
  local tokens = tokenize(str or "")
  local groups = {}
  local pending_or = false
  for idx, tok in ipairs(tokens) do
    -- An operator only counts between two terms; otherwise it's a word.
    local between = #groups > 0 and not pending_or and tokens[idx + 1] and not is_op(tokens[idx + 1])
    if is_or(tok) and between then
      pending_or = true
    elseif is_and(tok) and between then
      -- The same as the space around it: nothing to do.
    else
      local term = to_term(tok)
      if term then
        if pending_or then
          table.insert(groups[#groups], term)
        else
          groups[#groups + 1] = { term }
        end
      end
      pending_or = false
    end
  end
  return groups
end

return M
