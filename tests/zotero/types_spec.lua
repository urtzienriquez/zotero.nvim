local types = require("zotero.types")

describe("types.truncate", function()
  it("returns the string unchanged when it fits", function()
    assert.equals("Hello", types.truncate("Hello", 10))
  end)

  it("truncates with an ellipsis when too long", function()
    assert.equals("Hell…", types.truncate("Hello World", 5))
  end)

  it("returns just the ellipsis when width is 0", function()
    assert.equals("…", types.truncate("Hello", 0))
  end)

  it("handles empty strings", function()
    assert.equals("", types.truncate("", 5))
  end)

  it("handles non-string input", function()
    assert.equals("", types.truncate(nil, 5))
    assert.equals("", types.truncate(42, 5))
  end)

  it("truncates multi-byte (wide) characters correctly", function()
    local result = types.truncate("日本語のタイトルテスト", 8)
    assert.is_true(vim.fn.strdisplaywidth(result) <= 8)
    assert.equals("…", result:sub(-3)) -- ellipsis is 3 bytes in utf-8
  end)

  it("matches a linear reference scan across many random widths", function()
    -- The original O(n) implementation, kept only to compare against.
    local function reference_truncate(str, max_width)
      if vim.fn.strdisplaywidth(str) <= max_width then
        return str
      end
      local result = ""
      for i = 1, vim.fn.strchars(str) do
        local c = vim.fn.strcharpart(str, i - 1, 1)
        if vim.fn.strdisplaywidth(result .. c .. "…") > max_width then
          return result .. "…"
        end
        result = result .. c
      end
      return result .. "…"
    end

    local samples = {
      "Hello World", "café résumé naïve", "日本語のタイトルテスト",
      "Иванов Пётр Сергеевич", string.rep("x", 120), "a", "",
    }
    for _, s in ipairs(samples) do
      for w = 0, 40 do
        assert.equals(reference_truncate(s, w), types.truncate(s, w), ("mismatch for %q width=%d"):format(s, w))
      end
    end
  end)
end)

describe("types.pad_right / pad_left", function()
  it("pads to the target width", function()
    assert.equals("ab  ", types.pad_right("ab", 4))
    assert.equals("  ab", types.pad_left("ab", 4))
  end)

  it("does not truncate when already at/over width", function()
    assert.equals("abcd", types.pad_right("abcd", 2))
  end)
end)

describe("types.format_creators", function()
  it("formats single-field names as First Last", function()
    local out = types.format_creators({ { fieldMode = 0, firstName = "Jane", lastName = "Smith" } })
    assert.equals("Jane Smith", out)
  end)

  it("formats fieldMode=1 (single-field) names as-is", function()
    local out = types.format_creators({ { fieldMode = 1, lastName = "Acme Corp" } })
    assert.equals("Acme Corp", out)
  end)

  it("joins multiple creators with semicolons", function()
    local out = types.format_creators({
      { fieldMode = 0, firstName = "A", lastName = "One" },
      { fieldMode = 0, firstName = "B", lastName = "Two" },
    })
    assert.equals("A One; B Two", out)
  end)

  it("returns empty string for nil/empty input", function()
    assert.equals("", types.format_creators(nil))
    assert.equals("", types.format_creators({}))
  end)
end)

describe("types.format_creators_compact", function()
  it("shows just the first creator's last name", function()
    local out = types.format_creators_compact({
      { fieldMode = 0, firstName = "A", lastName = "One" },
      { fieldMode = 0, firstName = "B", lastName = "Two" },
    })
    assert.equals("One et al.", out)
  end)

  it("omits 'et al.' for a single creator", function()
    local out = types.format_creators_compact({ { fieldMode = 0, lastName = "Solo" } })
    assert.equals("Solo", out)
  end)
end)

describe("types.extract_year", function()
  it("extracts a 4-digit leading year", function()
    assert.equals("2019", types.extract_year("2019-05-20"))
  end)

  it("returns empty string when there is no leading year", function()
    assert.equals("", types.extract_year("no date here"))
  end)

  it("returns empty string for non-string input", function()
    assert.equals("", types.extract_year(nil))
  end)
end)

describe("types.escape_sql", function()
  it("doubles single quotes", function()
    assert.equals("O''Brien", types.escape_sql("O'Brien"))
  end)

  it("returns empty string for nil", function()
    assert.equals("", types.escape_sql(nil))
  end)

  it("leaves strings without quotes unchanged", function()
    assert.equals("plain text", types.escape_sql("plain text"))
  end)
end)
