local WhoDoesWhat = LibStub("AceAddon-3.0"):GetAddon("WhoDoesWhat")

-- Points a healthstone tooltip at the warlocks who can conjure that exact
-- stone. Aimed at the action-bar button that has run dry: the line only
-- appears while you carry none (GetItemCount is the client's own count, no
-- bag scan), and only when the group has a warlock to name.
--
-- Improved Healthstone rank decides which item a warlock makes, so a stone
-- is matched against each warlock's known rank. Warlocks whose rank we
-- haven't learned yet are left out.

local A = WhoDoesWhat.Assign

local function AddHealthstoneLine(tooltip, itemId)
    local healthstone = WhoDoesWhat.WarlockHealthstone
    local wantRank = itemId and healthstone and healthstone.talentRankByItemId[itemId]
    if not wantRank or GetItemCount(itemId) > 0 then return end

    local names = {}
    for _, name in ipairs(A.MembersOfClass("Warlock")) do
        if WhoDoesWhat:GetWarlockHealthstoneTalent(name) == wantRank then
            names[#names + 1] = A.PlayerText(name)
        end
    end
    if #names == 0 then return end

    tooltip:AddLine("|cffffd100Provided by:|r " .. table.concat(names, ", "), 1, 1, 1, true)
    tooltip:Show()
end

-- The id line itself: dev garnish for filling in the data tables, off unless
-- WhoDoesWhat:ShowTooltipIds() says otherwise (on by default on Forever).
-- Anything on the tooltip already has its id in hand by the time we are
-- called, so this only ever formats what the caller found.
local function AddIdLine(tooltip, label, id)
    if not (id and WhoDoesWhat:ShowTooltipIds()) then return end
    tooltip:AddLine("|cff888888" .. label .. " " .. id .. "|r")
    tooltip:Show()
end

if GameTooltip:HasScript("OnTooltipSetItem") then
    GameTooltip:HookScript("OnTooltipSetItem", function(tooltip)
        local _, link = tooltip:GetItem()
        local itemId = link and tonumber(link:match("item:(%d+)"))
        AddHealthstoneLine(tooltip, itemId)
        AddIdLine(tooltip, "Item", itemId)
    end)
    -- Aura tooltips are spell tooltips on this client, so one hook covers both
    -- a buff on a unit frame and a spell in the book.
    if GameTooltip:HasScript("OnTooltipSetSpell") then
        GameTooltip:HookScript("OnTooltipSetSpell", function(tooltip)
            local _, spellId = tooltip:GetSpell()
            AddIdLine(tooltip, "Spell", spellId)
        end)
    end
elseif TooltipDataProcessor then
    TooltipDataProcessor.AddTooltipPostCall(Enum.TooltipDataType.Item, function(tooltip, data)
        if tooltip == GameTooltip then
            AddHealthstoneLine(tooltip, data and data.id)
            AddIdLine(tooltip, "Item", data and data.id)
        end
    end)
    -- Two separate types here: a spell tooltip carries the spell's own id,
    -- while an aura's carries the aura's -- which for a buff off a consumable
    -- is the id the data tables want.
    TooltipDataProcessor.AddTooltipPostCall(Enum.TooltipDataType.Spell, function(tooltip, data)
        if tooltip == GameTooltip then
            AddIdLine(tooltip, "Spell", data and data.id)
        end
    end)
    TooltipDataProcessor.AddTooltipPostCall(Enum.TooltipDataType.UnitAura, function(tooltip, data)
        if tooltip == GameTooltip then
            AddIdLine(tooltip, "Aura", data and (data.spellID or data.id))
        end
    end)
end
