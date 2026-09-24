local parse = require("zotero.search_query").parse

-- Compact view of a parse: each AND-group as a list of "[-][scope:]text",
-- with phrases in quotes and a term's own groups as {a|b & c}.
local function show(query)
  local out = {}
  for _, group in ipairs(parse(query)) do
    local alts = {}
    for _, t in ipairs(group) do
      local groups = {}
      for _, values in ipairs(t.groups) do
        local alts = {}
        for _, v in ipairs(values) do
          alts[#alts + 1] = v.phrase and ('"' .. v.text .. '"') or v.text
        end
        groups[#groups + 1] = table.concat(alts, "|")
      end
      local text = groups[1]
      if #groups > 1 or text:find("|", 1, true) then
        text = "{" .. table.concat(groups, " & ") .. "}"
      end
      local scope = t.scope ~= "meta" and (t.scope .. ":") or ""
      alts[#alts + 1] = (t.negate and "-" or "") .. scope .. text
    end
    out[#out + 1] = alts
  end
  return out
end

describe("search_query.parse", function()
  it("ANDs plain words", function()
    assert.same({ { "a" }, { "b" } }, show("a  b"))
    assert.same({}, show("   "))
  end)

  it("keeps quoted phrases together", function()
    assert.same({ { '"climate change"' }, { "x" } }, show('"climate change" x'))
  end)

  it("OR and | join neighbours, binding tighter than AND", function()
    assert.same({ { "x" }, { "a", "b" } }, show("x a OR b"))
    assert.same({ { "a", "b", "c" } }, show("a | b OR c"))
  end)

  it("AND and & between words are the same as a space", function()
    assert.same({ { "a" }, { "b" }, { "c" } }, show("a AND b & c"))
    assert.same({ { "a", "b" }, { "c" } }, show("a OR b AND c"))
    assert.same({ { "AND" }, { "a" } }, show("AND a"))
    assert.same({ { "a" }, { "&" } }, show("a &"))
    assert.same({ { "a" }, { "and" }, { "b" } }, show("a and b")) -- only upper-case AND
  end)

  it("treats a dangling or doubled OR as a word", function()
    assert.same({ { "OR" }, { "a" } }, show("OR a"))
    assert.same({ { "a" }, { "OR" } }, show("a OR"))
    assert.same({ { "a" }, { "or" }, { "b" } }, show("a or b")) -- only upper-case OR
  end)

  it("negates with a leading -", function()
    assert.same({ { "a" }, { "-b" }, { '-"c d"' } }, show('a -b -"c d"'))
    assert.same({ { "-" } }, show("-"))
  end)

  it("reads note: and ft: prefixes, combined with - and phrases", function()
    assert.same({ { "note:todo" }, { "-ft:review" }, { 'ft:"niche model"' } }, show('note:todo -ft:review ft:"niche model"'))
    assert.same({ { "ft:a", "note:b" } }, show("ft:a OR note:b"))
  end)

  it("reads the field prefixes", function()
    assert.same({ { "author:huey" }, { "title:niche" }, { "year:2010-2020" }, { "-tag:review" } },
      show("author:huey title:niche year:2010-2020 -tag:review"))
    assert.same({ { "pub:nature" }, { "abstract:heat" }, { "doi:10.1/x" }, { "citekey:huey2009" } },
      show("pub:nature abstract:heat doi:10.1/x citekey:huey2009"))
  end)

  it("splits a prefixed quote on OR / | into alternatives of one term", function()
    assert.same({ { "author:{huey|kearney}" } }, show('author:"huey OR kearney"'))
    assert.same({ { '-author:{"raymond huey"|kearney|porter}' } }, show('-author:"raymond huey | kearney OR porter"'))
    assert.same({ { 'ft:"climate change"' } }, show('ft:"climate change"')) -- no operator: one phrase
  end)

  it("combines AND / & and OR / | inside a prefixed quote, OR binding tighter", function()
    assert.same({ { "author:{enriquez & kaliontzopoulou}" } }, show('author:"enriquez AND kaliontzopoulou"'))
    assert.same({ { "author:{a|b & c}" } }, show('author:"a OR b & c"'))
    assert.same({ { '-ft:{"climate change" & "range shift"}' } }, show('-ft:"climate change AND range shift"'))
    assert.same({ { "x", "author:{a & b}" } }, show('x OR author:"a AND b"'))
    assert.same({ { '"a AND b"' } }, show('"a AND b"')) -- no prefix: a literal phrase
    assert.same({ { '"huey OR kearney"' } }, show('"huey OR kearney"')) -- no prefix: a literal phrase
  end)

  it("leaves other colons and unbalanced quotes alone", function()
    assert.same({ { "https://doi.org/x" } }, show("https://doi.org/x"))
    assert.same({ { "note:" } }, show("note:"))
    assert.same({ { '"open' }, { "end" } }, show('"open end'))
  end)
end)
