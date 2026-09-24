local parse = require("zotero.search_query").parse

-- Compact view of a parse: each AND-group as a list of "[-][scope:]text",
-- with phrases in quotes and a term's several values as {a|b}.
local function show(query)
  local out = {}
  for _, group in ipairs(parse(query)) do
    local alts = {}
    for _, t in ipairs(group) do
      local values = {}
      for _, v in ipairs(t.values) do
        values[#values + 1] = v.phrase and ('"' .. v.text .. '"') or v.text
      end
      local text = #values > 1 and ("{" .. table.concat(values, "|") .. "}") or values[1]
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
    assert.same({ { '"huey OR kearney"' } }, show('"huey OR kearney"')) -- no prefix: a literal phrase
  end)

  it("leaves other colons and unbalanced quotes alone", function()
    assert.same({ { "https://doi.org/x" } }, show("https://doi.org/x"))
    assert.same({ { "note:" } }, show("note:"))
    assert.same({ { '"open' }, { "end" } }, show('"open end'))
  end)
end)
