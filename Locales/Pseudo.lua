local Locale = select(2, ...).Locale

-- Developer copies only: never packaged (.pkgmeta) and fenced out of the
-- shipped .toc. A made-up language that is English wrapped in [[ ]], for
-- checking the language plumbing with nothing translated yet:
--   - as your Language, any text on screen without brackets was missed;
--   - as your Message language, party and raid chat should come out
--     bracketed, while a whisper to someone with WhoDoesWhat follows theirs.
local english = Locale:Get("enUS")
setmetatable(Locale:Register("xxXX", "[[Pseudo]]"), { __index = function(_, key)
    return "[[" .. english[key] .. "]]"
end })
