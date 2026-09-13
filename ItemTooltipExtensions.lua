local WhoDoesWhat = LibStub("AceAddon-3.0"):GetAddon("WhoDoesWhat")

-- Points a healthstone tooltip at the warlocks who can conjure that exact
-- stone. Aimed at the action-bar button that has run dry: the line only
-- appears while you carry none (GetItemCount is the client's own count, no
-- bag scan), and only when the group has a warlock to name.
--
-- Improved Healthstone rank decides which item a warlock makes, so a stone
-- is matched against each warlock's known rank. Warlocks whose rank we
-- haven't learned yet are listed after, marked "?".

local A = WhoDoesWhat.Assign

local function AddHealthstoneLine(tooltip, itemId)
    local healthstone = WhoDoesWhat.WarlockHealthstone
    local wantRank = itemId and healthstone.talentRankByItemId[itemId]
    if not wantRank or GetItemCount(itemId) > 0 then return end

    local names = {}
    local unknown = {}
    for _, name in ipairs(A.MembersOfClass("Warlock")) do
        local rank = WhoDoesWhat:GetWarlockHealthstoneTalent(name)
        if rank == wantRank then
            names[#names + 1] = A.PlayerText(name)
        elseif rank == nil then
            unknown[#unknown + 1] = A.PlayerText(name) .. "|cff909090?|r"
        end
    end
    for _, text in ipairs(unknown) do names[#names + 1] = text end
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
