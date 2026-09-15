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

if GameTooltip:HasScript("OnTooltipSetItem") then
    GameTooltip:HookScript("OnTooltipSetItem", function(tooltip)
        local _, link = tooltip:GetItem()
        local itemId = link and tonumber(link:match("item:(%d+)"))
        AddHealthstoneLine(tooltip, itemId)
    end)
elseif TooltipDataProcessor then
    TooltipDataProcessor.AddTooltipPostCall(Enum.TooltipDataType.Item, function(tooltip, data)
        if tooltip == GameTooltip then
            AddHealthstoneLine(tooltip, data and data.id)
        end
    end)
end
