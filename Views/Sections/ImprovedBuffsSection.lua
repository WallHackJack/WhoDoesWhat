local WhoDoesWhat = LibStub("AceAddon-3.0"):GetAddon("WhoDoesWhat")

-- Compact summary of raid buffs whose strength depends on the caster's
-- talents. The full grid owns the per-target detail; this section shows the
-- best known provider and max-rank coverage at a glance.

local A = WhoDoesWhat.Assign
local K = WhoDoesWhat.SectionKit

local ROW_H = 28
local READY_ICON = "Interface\\RaidFrame\\ReadyCheck-Ready"

local function RankColor(rank, maxRank)
    if rank == nil then return 0.55, 0.55, 0.55 end
    if rank >= maxRank then return 0.25, 1, 0.25 end
    if rank > 0 then return 1, 0.82, 0 end
    return 1, 0.4, 0.4
end

local function ProviderText(data)
    local provider = data.providers[1]
    if not provider then return "No " .. data.className .. "s" end
    local rank = provider.rank
    return provider.name .. "  " .. (rank == nil and "?" or rank)
        .. "/" .. data.talent.maxRank
end

local function CreateRow(state, index)
    local row = CreateFrame("Frame", nil, state.box)
    row:SetFrameLevel(state.box:GetFrameLevel() + 1)
    row:SetSize(state.box:GetWidth() - K.BOX_PAD * 2, ROW_H)
    row:SetPoint("TOPLEFT", K.BOX_PAD,
        -(K.BOX_PAD + K.SECTION_TITLE_H + (index - 1) * ROW_H))

    local icon = row:CreateTexture(nil, "ARTWORK")
    icon:SetSize(20, 20)
    icon:SetPoint("LEFT", 4, 0)
    row.icon = icon

    local name = row:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    name:SetPoint("LEFT", icon, "RIGHT", 6, 0)
    name:SetWidth(92)
    name:SetJustifyH("LEFT")
    row.name = name

    local provider = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    provider:SetPoint("LEFT", name, "RIGHT", 2, 0)
    provider:SetWidth(142)
    provider:SetJustifyH("LEFT")
    row.provider = provider

    local coverage = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    coverage:SetPoint("RIGHT", -2, 0)
    row.coverage = coverage

    local status = row:CreateTexture(nil, "OVERLAY")
    status:SetSize(16, 16)
    status:SetPoint("RIGHT", coverage, "LEFT", -4, 0)
    row.status = status

    row:EnableMouse(true)
    row:SetScript("OnEnter", function(self)
        local data = self.data
        if not data then return end
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetText(data.talent.name, 1, 1, 1)
        if #data.providers == 0 then
            GameTooltip:AddLine("No " .. data.className .. " providers in the group.",
                0.6, 0.6, 0.6, true)
        else
            for _, p in ipairs(data.providers) do
                local rank = p.rank == nil and "?" or p.rank
                GameTooltip:AddLine(p.name .. ": " .. rank .. "/"
                    .. data.talent.maxRank, RankColor(p.rank, data.talent.maxRank))
            end
        end
        GameTooltip:AddLine(data.correct .. " of " .. data.total
            .. " raiders have the max-ranked version.", 0.8, 0.8, 0.8, true)
        GameTooltip:Show()
    end)
    row:SetScript("OnLeave", function() GameTooltip:Hide() end)

    state.rows[index] = row
    return row
end

local function Refresh(f)
    local state = f.improvedBuffsSection
    local coverage = A.ComputeImprovedBuffCoverage()
    for i, data in ipairs(coverage) do
        local row = state.rows[i] or CreateRow(state, i)
        row.data = data
        row.icon:SetTexture(data.icon)
        row.name:SetText(data.name)
        row.provider:SetText(ProviderText(data))
        local best = data.providers[1]
        row.provider:SetTextColor(RankColor(best and best.rank, data.talent.maxRank))
        row.coverage:SetText(data.correct .. " / " .. data.total)
        local complete = data.total > 0 and data.correct == data.total
        row.coverage:SetTextColor(complete and 0.3 or 1,
            complete and 1 or 0.55, complete and 0.3 or 0.55)
        row.status:SetTexture(complete and READY_ICON or WhoDoesWhat.WARNING_ICON)
        row:Show()
    end
    for i = #coverage + 1, #state.rows do state.rows[i]:Hide() end

    state.box:SetHeight(K.BOX_PAD + K.SECTION_TITLE_H
        + math.max(#coverage, 1) * ROW_H + K.BOX_PAD)
    K.LayoutHeaderChain(state.headerChain)
    K.UpdateContentHeight(f)
end

local function Build(f, content)
    local chrome = K.CreateSectionChrome(f, content, {
        title = "Improved Buffs",
        column = K.COL_LEFT,
    })
    local gridBtn = K.AddHeaderTextButton(chrome.box, chrome.box.title,
        "Full Grid", "Raid Buff Grid",
        "Show every raider as a row with Mark, Fortitude, Intellect, and Food columns.",
        function() WhoDoesWhat:OpenImprovedBuffGridView() end)
    K.ChainHeaderButton(chrome, gridBtn)

    f.improvedBuffsSection = {
        box = chrome.box,
        headerChain = chrome.headerChain,
        rows = {},
    }
end

WhoDoesWhat.SectionViews.ImprovedBuffs = { Build = Build, Refresh = Refresh }
