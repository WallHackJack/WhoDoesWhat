-- WoW Forever dropped the Era spell, item and talent globals in favour of the
-- C_Spell / C_Item namespaces. This file puts the old names back, forwarding to
-- the modern calls, so the ~90 call sites across this addon -- and the shipped
-- libraries that call them too (LibClassicInspector, AceGUI) -- keep working on
-- every client.
--
-- Globals rather than a private table on purpose: the libraries can't be
-- reached any other way without forking them, and a name this client does not
-- define is one nothing else can be relying on. Every definition is guarded
-- both ways, so a client that still has the global keeps its own, and one
-- without the modern replacement is left alone to fail loudly rather than
-- silently answering wrong.
--
-- Loaded first, before anything that calls them at file scope (Data.lua builds
-- its spell names as it loads).

local C_Spell, C_Item = C_Spell, C_Item

if not GetSpellInfo and C_Spell and C_Spell.GetSpellInfo then
    -- Era returns a flat list, the modern call a table. Rank (the old second
    -- return) has no equivalent and nothing here reads it. Takes a name or an
    -- id either way, which callers rely on to ask "does this client have this
    -- spell at all?".
    function GetSpellInfo(spell)
        local info = spell and C_Spell.GetSpellInfo(spell)
        if not info then return nil end
        return info.name, nil, info.iconID, info.castTime, info.minRange,
            info.maxRange, info.spellID
    end
end

if not GetSpellTexture and C_Spell and C_Spell.GetSpellTexture then
    GetSpellTexture = C_Spell.GetSpellTexture
end

if not GetItemInfo and C_Item and C_Item.GetItemInfo then
    GetItemInfo = C_Item.GetItemInfo
end

if not GetItemCount and C_Item and C_Item.GetItemCount then
    GetItemCount = C_Item.GetItemCount
end

if not GetItemSpell and C_Item and C_Item.GetItemSpell then
    GetItemSpell = C_Item.GetItemSpell
end

if not GetItemIcon and C_Item and C_Item.GetItemIconByID then
    GetItemIcon = C_Item.GetItemIconByID
end

-- Blizzard's own sprite-sheet animator, which LibCustomGlow's button glow drives
-- its marching ants with every frame. Gone on Forever, and the lib calls it
-- from an OnUpdate, so its absence is thousands of errors rather than one.
-- Reimplemented rather than forwarded: there is nothing to forward to. Fields
-- are prefixed so a client that brings the real one back keeps its own state.
if not AnimateTexCoords then
    function AnimateTexCoords(texture, textureWidth, textureHeight, frameWidth,
                              frameHeight, numFrames, elapsed, throttle)
        local rate = throttle and throttle > 0 and throttle or 0.05
        local waited = (texture.wdwElapsed or 0) + elapsed
        if waited < rate then
            texture.wdwElapsed = waited
            return
        end
        local advanced = math.floor(waited / rate)
        texture.wdwElapsed = waited - advanced * rate
        local columns = math.max(1, math.floor(textureWidth / frameWidth))
        local frame = ((texture.wdwFrame or 0) + advanced) % numFrames
        texture.wdwFrame = frame
        local left = (frame % columns) * frameWidth / textureWidth
        local top = math.floor(frame / columns) * frameHeight / textureHeight
        texture:SetTexCoord(left, left + frameWidth / textureWidth,
            top, top + frameHeight / textureHeight)
    end
end

-- The talent globals have no replacement: Forever removed the Era talent trees
-- outright, and whatever it does instead is not this API. Answering "no talent
-- tabs, no talents" is the truthful reply on such a client, and it is what
-- every caller here already handles -- the scanners walk an empty list and the
-- buff-talent features are off anyway (ClientFeatures.buffTalents).
if not GetNumTalentTabs then
    function GetNumTalentTabs() return 0 end
    function GetNumTalents() return 0 end
    function GetTalentInfo() return nil end
end
