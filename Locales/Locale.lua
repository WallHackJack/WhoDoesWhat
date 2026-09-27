local _, ns = ...

--------------------------------------------------------------------------------
-- WhoDoesWhat's languages.
--
-- Not AceLocale: that keeps exactly one translation, the game client's, and
-- discards every other language file as it loads. WDW needs two at once -- the
-- player's own Language for everything on screen, and another player's for a
-- whisper to them -- and lets the player pick a Language the client is not in.
--
-- Each language file fills a table of its own through Register, one line per
-- string in the CurseForge "lua_additive_table" format:
--     L["GENERAL_MINIMAP_BUTTON"] = "Show minimap button"
-- so the project page's translation tool can import and export them as they
-- are. A key a translation lacks falls through to English.
--
-- `ns.L` is the interface's strings: it reads whichever Language is primary.
-- That is only settled in OnInitialize, once saved variables have loaded --
-- which the client does after every file has already run. So read L inside
-- functions, never at file scope: a string read while a file loads is fixed
-- in the game's language before the player's choice is known. Developer
-- copies list any such read in chat after login.
--------------------------------------------------------------------------------

local Locale = {}
ns.Locale = Locale

local DEFAULT = "enUS"

local languages = {} -- code -> its strings
local names = {}     -- code -> the language's name for itself
local codes = {}     -- codes, in the order their files loaded
local primary        -- the strings ns.L reads, once settled

--@do-not-package@
local earlyReads, missing = {}, {}
--@end-do-not-package@

-- The strings table for `code`, created on first call. `name` is what the
-- Language dropdowns call it, in the language itself ("Deutsch").
function Locale:Register(code, name)
    local strings = languages[code]
    if strings then return strings end
    strings = {}
    if code == DEFAULT then
        -- The end of every fallback chain: an unknown key reads as itself, so
        -- a typo shows on screen instead of breaking the frame that asked.
        setmetatable(strings, { __index = function(_, key)
            --@do-not-package@
            if not missing[key] then
                missing[key] = true
                print("|cffff5555WhoDoesWhat: no English string for " .. tostring(key) .. "|r")
            end
            --@end-do-not-package@
            return key
        end })
    else
        setmetatable(strings, { __index = languages[DEFAULT] })
    end
    languages[code] = strings
    names[code] = name
    codes[#codes + 1] = code
    return strings
end

-- The game client's own language, whether or not WDW has it: the language
-- every name the client hands back (spells, classes) comes in. British
-- clients report enGB, which reads the American strings.
function Locale:ClientLanguage()
    local code = GetLocale()
    return code == "enGB" and DEFAULT or code
end

-- The game client's language, if WDW has it; English otherwise.
function Locale:GameLanguage()
    local code = self:ClientLanguage()
    return languages[code] and code or DEFAULT
end

-- Whether `strings` (ns.L, or a table from Get) is in the client's language,
-- so a name the client supplies can stand in for WDW's own.
function Locale:IsClientLanguage(strings)
    local code = strings == ns.L and self.primary or nil
    if not code then
        for c, s in pairs(languages) do
            if s == strings then code = c break end
        end
    end
    return code ~= nil and code == self:ClientLanguage()
end

-- A saved choice as a language WDW has: "auto" (or nothing) is the game's,
-- and a language this copy lacks -- a peer on a newer build -- is English.
function Locale:Resolve(code)
    if code == nil or code == "auto" then return self:GameLanguage() end
    return languages[code] and code or DEFAULT
end

function Locale:Get(code)
    return languages[self:Resolve(code)]
end

function Locale:Has(code)
    return languages[code] ~= nil
end

function Locale:Name(code)
    return names[code]
end

function Locale:Codes()
    return codes
end

-- Fix the Language ns.L reads. Called once, from OnInitialize.
function Locale:SetPrimary(code)
    self.primary = self:Resolve(code)
    primary = languages[self.primary]
end

--@do-not-package@
-- The keys read before SetPrimary, then forgotten: a developer check, run
-- once after login.
function Locale:TakeEarlyReads()
    local keys = {}
    for key in pairs(earlyReads) do keys[#keys + 1] = key end
    table.sort(keys)
    wipe(earlyReads)
    return keys
end
--@end-do-not-package@

ns.L = setmetatable({}, { __index = function(_, key)
    if primary then return primary[key] end
    --@do-not-package@
    earlyReads[key] = true
    --@end-do-not-package@
    return Locale:Get("auto")[key]
end })

-- A string with named placeholders, filled in:
--     Fill(L.ROLE_CHANGED_BY, { name = "Anna", role = "Holy", changer = "Bob" })
-- turns "{name} was changed to {role} by {changer}." into a sentence. Every
-- string with two or more inputs uses these rather than %s: Lua 5.1's format
-- has no positional arguments, so %s would pin a translation to English word
-- order. Values go in as they are (numbers through tostring) and are never
-- themselves searched for placeholders. One with no value is left as written,
-- so a typo shows on screen instead of vanishing.
function ns.Fill(template, values)
    return (template:gsub("{(%w+)}", function(key)
        local value = values[key]
        if value ~= nil then return tostring(value) end
    end))
end
