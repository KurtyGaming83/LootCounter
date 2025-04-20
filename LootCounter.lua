-- Coded by bnet : kurty#2232
-- v.0.9 (fixed count increment issue after 99)

-- Définir la base de données persistante
local db
local isFarmSessionActive = false
local farmStartTime = nil
local farmTimerFrame = CreateFrame("Frame")
local farmButton = nil
local lastMouseoverTarget = nil
local lastTarget = nil
local sessionStatsWindow = nil
local globalStatsWindow = nil
local currentLootSource = nil
local lastMiningTarget = nil
local lastMiningTime = nil
local lastEnemyKilled = nil
local lastEnemyKilledTime = nil
local currentMiningSource = nil -- Nouvelle variable pour stocker la source de minage

-- Gestion des événements
local addonName = "LootCounter"
local frame = CreateFrame("Frame")
frame:RegisterEvent("ADDON_LOADED")
frame:RegisterEvent("PLAYER_LOGIN")
frame:RegisterEvent("CHAT_MSG_LOOT")
frame:RegisterEvent("PLAYER_LOGOUT")
frame:RegisterEvent("COMBAT_LOG_EVENT_UNFILTERED")
frame:RegisterEvent("PLAYER_TARGET_CHANGED")
frame:RegisterEvent("LOOT_OPENED")

-- Fonction pour formater le temps écoulé en minutes et secondes
local function FormatTime(seconds)
    if not seconds or seconds < 0 then
        return "00:00:00"
    end
    local hours = math.floor(seconds / 3600)
    local minutes = math.floor((seconds % 3600) / 60)
    local secs = seconds % 60
    return string.format("%02d:%02d:%02d", hours, minutes, secs)
end

-- Liste des minerais (à ajuster selon les items de votre jeu)
local mineralItems = {
    [213508] = true,
    [213509] = true,
    [210931] = true,
    [210936] = true,
    [210938] = true,
    [210939] = true,
}

-- Liste des objets interactifs (comme "Tas de cire")
local interactiveObjects = {
    ["Magot du gardien"] = true, -- 444066
    ["Keeper's Stash"] = true,
    ["Schatz des Hüters"] = true,
    ["Тайник хранителя"] = true,
    ["Tas de cire"] = true, -- 419696
    ["Waxy Lump"] = true,
    ["Wachsstück"] = true,
    ["Восковой комок"] = true,
    ["Sol dérangé"] = true, -- 241838,422531
    ["Disturbed Earth"] = true,
    ["Aufgewühlte Erde"] = true,
    ["Потревоженная земля"] = true,
    ["Trésor de rivage"] = true,  -- 451673
    ["Shore Treasure"] = true,
    ["Uferschatz"] = true,
    ["Сокровище с берега"] = true,
    ["Bassin scintillant"] = true, -- 451669
    ["Glimmerpool"] = true,
    ["Glimmerbecken"] = true,
    ["Мерцающий омут"] = true,
    ["Clapotis de surface calme"] = true, -- 451670
    ["Calm Surfacing Ripple"] = true,
    ["Ruhige Oberflächenwellen"] = true,
    ["Тихая рябь"] = true,
    ["Nuée de mirétoiles"] = true, -- 451672
    ["Stargazer Swarm"] = true,
    ["Sternguckerschwarm"] = true,
    ["Косяк звездочета"] = true,
    ["Bassin de bars des rivières"] = true, -- 451674
    ["River Bass Pool"] = true,
    ["Flussbarschteich"] = true,
    ["Косяк речного окуня"] = true,
    ["Ruissellement de gentepression"] = true, -- 457157
    ["Steamwheedle Runoff"] = true,
    ["Dampfdruckabfluss"] = true,
    ["Сточные воды Хитрой Шестеренки"] = true,
    ["Torrent de cherchepêches"] = true, -- 451675
    ["Anglerseeker Torrent"] = true,
    ["Anglersucherstrom"] = true,
    ["Поток с ловцами удильщиков"] = true,
    ["Banc de mérous sombroeil"] = true, -- 414622
    ["Shadowblind Grouper School"] = true,
    ["Schwarm schattenblinder Barsche"] = true,
    ["Косяк окуня темной слепоты"] = true,
}

-- Fonction pour détecter la source du loot
local function GetLootSource(itemID, miningSource)
    local isMineral = mineralItems[itemID] or false
    if miningSource then
        return miningSource
    end
    if currentLootSource then
        return currentLootSource
    end
    if lastEnemyKilled then
        return lastEnemyKilled
    end
    if lastMouseoverTarget and interactiveObjects[lastMouseoverTarget] then
        return lastMouseoverTarget
    end
    return "Inconnu"
end

-- Fonction pour analyser les messages de loot
local function TrackLoot(self, event, message, ...)
    if event == "CHAT_MSG_LOOT" and message then
        if not message:match("^Vous recevez") and not message:match("^You receive") and not message:match("^Sie erhalten") and not message:match("^Вы получили") then
            return
        end
        
        local itemLink = string.match(message, "|Hitem:.-|h.-|h")
        if itemLink then
            local itemID = string.match(itemLink, "item:(%d+)")
            if itemID then
                itemID = tonumber(itemID)
                local quantity = tonumber(string.match(message, "x(%d+)") or 1)
                local source = GetLootSource(itemID, currentMiningSource)
                if not db.entries then
                    db.entries = {}
                end
                local found = false
                for _, entry in ipairs(db.entries) do
                    if entry.itemID == itemID and entry.source == source then
                        entry.count = tonumber(entry.count or 0) + quantity
                        found = true
                        break
                    end
                end
                if not found then
                    table.insert(db.entries, { itemID = itemID, source = source, count = quantity })
                end
                if isFarmSessionActive then
                    if not db.farmSession then
                        db.farmSession = {}
                    end
                    if not db.farmSession.entries then
                        db.farmSession.entries = {}
                    end
                    local sessionFound = false
                    for _, entry in ipairs(db.farmSession.entries) do
                        if entry.itemID == itemID and entry.source == source then
                            entry.count = tonumber(entry.count or 0) + quantity
                            sessionFound = true
                            break
                        end
                    end
                    if not sessionFound then
                        table.insert(db.farmSession.entries, { itemID = itemID, source = source, count = quantity })
                    end
                end
                if globalStatsWindow and globalStatsWindow.UpdateTable then
                    globalStatsWindow.UpdateTable()
                end
                if sessionStatsWindow and sessionStatsWindow.UpdateTable then
                    sessionStatsWindow.UpdateTable()
                end
            end
        end
    elseif event == "COMBAT_LOG_EVENT_UNFILTERED" then
        local timestamp, subEvent, _, sourceGUID, sourceName, _, _, destGUID, destName = CombatLogGetCurrentEventInfo()
        if subEvent == "UNIT_DIED" then
            local isEnemy = false
            if destGUID then
                local unitType, _, _, _, _, _, _ = strsplit("-", destGUID)
                if unitType == "Creature" or unitType == "Vehicle" then
                    isEnemy = true
                end
            end
            if isEnemy and destName then
                lastEnemyKilled = destName
                lastEnemyKilledTime = time()
            end
        end
    elseif event == "LOOT_OPENED" then
        local sourceName = lastMouseoverTarget or lastTarget
        local miningSource = nil
        if lastMiningTarget and lastMiningTime and (time() - lastMiningTime) <= 10 then
            miningSource = lastMiningTarget
            currentLootSource = lastMiningTarget
        elseif sourceName and (sourceName:find("Gisement") or sourceName:find("Veine") or sourceName:find("Deposit") or sourceName:find("Riche") or sourceName:find("Mine-Trankil") or sourceName:find("Bismuth") or sourceName:find("Griffefer")) then
            lastMiningTarget = sourceName
            lastMiningTime = time()
            miningSource = sourceName
            currentLootSource = sourceName
        elseif sourceName and interactiveObjects[sourceName] then
            currentLootSource = sourceName
        elseif sourceName then
            currentLootSource = sourceName
        else
            if lastEnemyKilled then
                currentLootSource = lastEnemyKilled
            end
        end
        currentMiningSource = miningSource
    end
end

-- Fonction pour modifier le tooltip
local function UpdateTooltip(tooltip)
    if not tooltip then return end
    if not TooltipUtil or not TooltipUtil.GetDisplayedItem then return end
    local _, itemLink, itemID = TooltipUtil.GetDisplayedItem(tooltip)
    if not itemLink or not itemID then return end
    itemID = tonumber(itemLink:match("item:(%d+)"))
    if itemID then
        local totalCount = 0
        local sessionCount = 0
        if db.entries then
            for _, entry in ipairs(db.entries) do
                if entry.itemID == itemID then
                    totalCount = totalCount + tonumber(entry.count or 0)
                end
            end
        end
        if isFarmSessionActive and db.farmSession and db.farmSession.entries then
            for _, entry in ipairs(db.farmSession.entries) do
                if entry.itemID == itemID then
                    sessionCount = sessionCount + tonumber(entry.count or 0)
                end
            end
        end
        if totalCount > 0 then
            tooltip:AddLine("Looté : " .. totalCount .. " unités au total", 1, 1, 0)
            if isFarmSessionActive and sessionCount > 0 then
                tooltip:AddLine("Session de farm : " .. sessionCount .. " unités", 0, 1, 0)
            end
        end
    end
end

-- Créer une fenêtre pour afficher les statistiques globales
local function CreateGlobalStatsWindow()
    local frame = CreateFrame("Frame", "LootCounterGlobalStatsWindow", UIParent, "BasicFrameTemplateWithInset")
    if not frame then return nil end
    frame:SetSize(550, 350)
    frame:SetPoint("CENTER")
    frame:SetMovable(true)
    frame:EnableMouse(true)
    frame:RegisterForDrag("LeftButton")
    frame:SetScript("OnDragStart", frame.StartMoving)
    frame:SetScript("OnDragStop", frame.StopMovingOrSizing)
    frame:RegisterEvent("LOOT_CLOSED")

    globalStatsWindow = frame

    frame.title = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    frame.title:SetPoint("TOP", 0, -5)
    frame.title:SetText("Loot Counter - Global Stats")

    local farmButton = CreateFrame("Button", "LootCounterOpenFarmButton", frame, "UIPanelButtonTemplate")
    farmButton:SetPoint("TOPRIGHT", -30, 0)
    farmButton:SetSize(100, 20)
    farmButton:SetText("Farm Mode")
    farmButton:SetScript("OnClick", function()
        if sessionStatsWindow then
            if sessionStatsWindow:IsShown() then
                sessionStatsWindow:Hide()
            else
                sessionStatsWindow:Show()
            end
        end
    end)

    local itemFilterLabel = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    itemFilterLabel:SetPoint("TOPLEFT", 10, -30)
    itemFilterLabel:SetText("Filtre Item :")

    local itemFilterEditBox = CreateFrame("EditBox", "LootCounterGlobalItemFilterEditBox", frame, "InputBoxTemplate")
    itemFilterEditBox:SetPoint("TOPLEFT", 10, -50)
    itemFilterEditBox:SetSize(150, 20)
    itemFilterEditBox:SetAutoFocus(false)
    itemFilterEditBox:SetFontObject("GameFontHighlight")
    itemFilterEditBox:SetTextInsets(5, 5, 0, 0)
    itemFilterEditBox:SetScript("OnTextChanged", function(self)
        frame.itemFilterText = self:GetText():lower()
        frame.UpdateTable()
    end)
    itemFilterEditBox:SetScript("OnEnterPressed", function(self)
        self:ClearFocus()
    end)
    itemFilterEditBox:SetScript("OnEscapePressed", function(self)
        self:SetText("")
        frame.itemFilterText = ""
        frame.UpdateTable()
        self:ClearFocus()
    end)

    local sourceFilterLabel = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    sourceFilterLabel:SetPoint("TOPLEFT", 180, -30)
    sourceFilterLabel:SetText("Filtre Source :")

    local sourceFilterEditBox = CreateFrame("EditBox", "LootCounterGlobalSourceFilterEditBox", frame, "InputBoxTemplate")
    sourceFilterEditBox:SetPoint("TOPLEFT", 180, -50)
    sourceFilterEditBox:SetSize(150, 20)
    sourceFilterEditBox:SetAutoFocus(false)
    sourceFilterEditBox:SetFontObject("GameFontHighlight")
    sourceFilterEditBox:SetTextInsets(5, 5, 0, 0)
    sourceFilterEditBox:SetScript("OnTextChanged", function(self)
        frame.sourceFilterText = self:GetText():lower()
        frame.UpdateTable()
    end)
    sourceFilterEditBox:SetScript("OnEnterPressed", function(self)
        self:ClearFocus()
    end)
    sourceFilterEditBox:SetScript("OnEscapePressed", function(self)
        self:SetText("")
        frame.sourceFilterText = ""
        frame.UpdateTable()
        self:ClearFocus()
    end)

    local sortByNameButton = CreateFrame("Button", "LootCounterGlobalSortByNameButton", frame, "UIPanelButtonTemplate")
    sortByNameButton:SetPoint("TOPLEFT", 10, -80)
    sortByNameButton:SetSize(80, 20)
    sortByNameButton:SetText("Item Name")
    sortByNameButton:SetScript("OnClick", function()
        frame.sortMode = "name"
        frame.UpdateTable()
    end)

    local sortBySourceButton = CreateFrame("Button", "LootCounterGlobalSortBySourceButton", frame, "UIPanelButtonTemplate")
    sortBySourceButton:SetPoint("TOPLEFT", 260, -80)
    sortBySourceButton:SetSize(80, 20)
    sortBySourceButton:SetText("Source")
    sortBySourceButton:SetScript("OnClick", function()
        frame.sortMode = "source"
        frame.UpdateTable()
    end)

    local sortByCountButton = CreateFrame("Button", "LootCounterGlobalSortByCountButton", frame, "UIPanelButtonTemplate")
    sortByCountButton:SetPoint("TOPLEFT", 460, -80)
    sortByCountButton:SetSize(80, 20)
    sortByCountButton:SetText("Quantity")
    sortByCountButton:SetScript("OnClick", function()
        frame.sortMode = "count"
        frame.UpdateTable()
    end)

    frame.sortMode = "name"
    frame.itemFilterText = ""
    frame.sourceFilterText = ""

    local scrollFrame = CreateFrame("ScrollFrame", "LootCounterGlobalStatsScrollFrame", frame, "UIPanelScrollFrameTemplate")
    scrollFrame:SetPoint("TOPLEFT", 10, -110)
    scrollFrame:SetPoint("BOTTOMRIGHT", -30, 10)

    local content = CreateFrame("Frame", "LootCounterGlobalStatsContent", scrollFrame)
    content:SetSize(500, 200)
    scrollFrame:SetScrollChild(content)

    local function UpdateTable()
        if content.rows then
            for _, row in ipairs(content.rows) do
                row:Hide()
            end
        end
        content.rows = {}

        local sortedEntries = {}
        for _, entry in ipairs(db.entries or {}) do
            local itemName = GetItemInfo(entry.itemID)
            if itemName then
                local itemFilterText = frame.itemFilterText or ""
                local sourceFilterText = frame.sourceFilterText or ""
                local itemNameLower = itemName:lower()
                local sourceLower = entry.source:lower()
                local itemMatch = itemFilterText == "" or itemNameLower:find(itemFilterText)
                local sourceMatch = sourceFilterText == "" or sourceLower:find(sourceFilterText)
                if itemMatch and sourceMatch then
                    table.insert(sortedEntries, { itemName = itemName, itemID = entry.itemID, source = entry.source, count = tonumber(entry.count or 0) })
                end
            end
        end

        if frame.sortMode == "name" then
            table.sort(sortedEntries, function(a, b)
                return a.itemName < b.itemName
            end)
        elseif frame.sortMode == "source" then
            table.sort(sortedEntries, function(a, b)
                return a.source < b.source
            end)
        elseif frame.sortMode == "count" then
            table.sort(sortedEntries, function(a, b)
                return a.count > b.count
            end)
        end

        local yOffset = -10
        local rowIndex = 1
        for _, entry in ipairs(sortedEntries) do
            local itemName, itemLink = GetItemInfo(entry.itemID)
            if itemName then
                local row = CreateFrame("Frame", nil, content)
                row:SetPoint("TOPLEFT", 10, yOffset)
                row:SetSize(500, 20)

                local col1 = row:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
                col1:SetPoint("LEFT", 0, 0)
                col1:SetText(itemLink or itemName)
                col1:SetWidth(250)
                col1:SetJustifyH("LEFT")

                local col1HitBox = CreateFrame("Frame", nil, row)
                col1HitBox:SetPoint("TOPLEFT", col1, "TOPLEFT", -5, 5)
                col1HitBox:SetPoint("BOTTOMRIGHT", col1, "BOTTOMRIGHT", 5, -5)
                col1HitBox:EnableMouse(true)
                col1HitBox:SetScript("OnEnter", function()
                    GameTooltip:SetOwner(col1HitBox, "ANCHOR_RIGHT")
                    GameTooltip:SetHyperlink("item:" .. entry.itemID)
                    GameTooltip:Show()
                end)
                col1HitBox:SetScript("OnLeave", function()
                    GameTooltip:Hide()
                end)

                local col2 = row:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
                col2:SetPoint("LEFT", 250, 0)
                col2:SetWidth(200)
                col2:SetJustifyH("LEFT")
                col2:SetText(entry.source)

                local col3 = row:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
                col3:SetPoint("LEFT", 450, 0)
                col3:SetWidth(100)
                col3:SetJustifyH("LEFT")
                col3:SetText(entry.count)

                table.insert(content.rows, row)
                yOffset = yOffset - 20
                rowIndex = rowIndex + 1
            end
        end
        content:SetHeight(rowIndex * 20)
    end

    frame.UpdateTable = UpdateTable
    UpdateTable()

    frame:Hide()
    return frame
end

-- Créer une fenêtre pour afficher les statistiques de la session de farm
local function CreateSessionStatsWindow()
    local frame = CreateFrame("Frame", "LootCounterSessionStatsWindow", UIParent, "BasicFrameTemplateWithInset")
    if not frame then return nil end
    frame:SetSize(550, 350)
    frame:SetPoint("CENTER", 200, 0)
    frame:SetMovable(true)
    frame:EnableMouse(true)
    frame:RegisterForDrag("LeftButton")
    frame:SetScript("OnDragStart", frame.StartMoving)
    frame:SetScript("OnDragStop", frame.StopMovingOrSizing)

    sessionStatsWindow = frame

    frame.title = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    frame.title:SetPoint("TOP", 0, -5)
    frame.title:SetText("Loot Counter - Session de Farm")

    local currentTab = CreateFrame("Button", "LootCounterSessionCurrentTab", frame, "UIPanelButtonTemplate")
    currentTab:SetPoint("TOPLEFT", 10, -30)
    currentTab:SetSize(100, 20)
    currentTab:SetText("Current Session")
    currentTab:SetScript("OnClick", function()
        frame.currentView = "current"
        frame.UpdateTable()
        frame.scrollFrame:Show()
        frame.historyScrollFrame:Hide()
        frame.timerText:Show()
        frame.lastSessionText:Show()
        farmButton:Show()
        frame.resetButton:Show()
        frame.sortButtons.name:Show()
        frame.sortButtons.source:Show()
        frame.sortButtons.count:Show()
    end)

    local historyTab = CreateFrame("Button", "LootCounterSessionHistoryTab", frame, "UIPanelButtonTemplate")
    historyTab:SetPoint("LEFT", currentTab, "RIGHT", 5, 0)
    historyTab:SetSize(100, 20)
    historyTab:SetText("Historic")
    historyTab:SetScript("OnClick", function()
        frame.currentView = "history"
        frame.UpdateHistoryTable()
        frame.scrollFrame:Hide()
        frame.historyScrollFrame:Show()
        frame.timerText:Hide()
        frame.lastSessionText:Hide()
        farmButton:Hide()
        frame.resetButton:Hide()
        frame.sortButtons.name:Hide()
        frame.sortButtons.source:Hide()
        frame.sortButtons.count:Hide()
    end)

    frame.currentView = "current"

    frame.timerText = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    frame.timerText:SetPoint("TOPLEFT", 10, -60)
    frame.timerText:SetText("Farm Session : None")

    frame.lastSessionText = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    frame.lastSessionText:SetPoint("TOPRIGHT", -10, -60)
    frame.lastSessionText:SetText("")

    frame.sortButtons = {}
    frame.sortButtons.name = CreateFrame("Button", "LootCounterSessionSortByNameButton", frame, "UIPanelButtonTemplate")
    frame.sortButtons.name:SetPoint("TOPLEFT", 10, -80)
    frame.sortButtons.name:SetSize(80, 20)
    frame.sortButtons.name:SetText("Item Name")
    frame.sortButtons.name:SetScript("OnClick", function()
        frame.sortMode = "name"
        frame.UpdateTable()
    end)

    frame.sortButtons.source = CreateFrame("Button", "LootCounterSessionSortBySourceButton", frame, "UIPanelButtonTemplate")
    frame.sortButtons.source:SetPoint("LEFT", frame.sortButtons.name, "RIGHT", 5, 0)
    frame.sortButtons.source:SetSize(80, 20)
    frame.sortButtons.source:SetText("Source")
    frame.sortButtons.source:SetScript("OnClick", function()
        frame.sortMode = "source"
        frame.UpdateTable()
    end)

    frame.sortButtons.count = CreateFrame("Button", "LootCounterSessionSortByCountButton", frame, "UIPanelButtonTemplate")
    frame.sortButtons.count:SetPoint("LEFT", frame.sortButtons.source, "RIGHT", 5, 0)
    frame.sortButtons.count:SetSize(80, 20)
    frame.sortButtons.count:SetText("Quantity")
    frame.sortButtons.count:SetScript("OnClick", function()
        frame.sortMode = "count"
        frame.UpdateTable()
    end)

    frame.sortMode = "name"

    frame.scrollFrame = CreateFrame("ScrollFrame", "LootCounterSessionStatsScrollFrame", frame, "UIPanelScrollFrameTemplate")
    frame.scrollFrame:SetPoint("TOPLEFT", 10, -110)
    frame.scrollFrame:SetPoint("BOTTOMRIGHT", -30, 50)

    local content = CreateFrame("Frame", "LootCounterSessionStatsContent", frame.scrollFrame)
    content:SetSize(500, 200)
    frame.scrollFrame:SetScrollChild(content)

    frame.historyScrollFrame = CreateFrame("ScrollFrame", "LootCounterSessionHistoryScrollFrame", frame, "UIPanelScrollFrameTemplate")
    frame.historyScrollFrame:SetPoint("TOPLEFT", 10, -30)
    frame.historyScrollFrame:SetPoint("BOTTOMRIGHT", -30, 10)
    frame.historyScrollFrame:Hide()

    local historyContent = CreateFrame("Frame", "LootCounterSessionHistoryContent", frame.historyScrollFrame)
    historyContent:SetSize(500, 200)
    frame.historyScrollFrame:SetScrollChild(historyContent)

    farmButton = CreateFrame("Button", "LootCounterFarmButton", frame, "UIPanelButtonTemplate")
    farmButton:SetPoint("BOTTOMLEFT", 10, 10)
    farmButton:SetSize(100, 30)
    farmButton:SetText(isFarmSessionActive and "Stop Farm" or "Start Farm")
    farmButton:SetScript("OnClick", function()
        if isFarmSessionActive then
            isFarmSessionActive = false
            farmButton:SetText("Start Farm")
            farmTimerFrame:SetScript("OnUpdate", nil)
            local elapsedTime = time() - farmStartTime
            if not db.farmSessionHistory then
                db.farmSessionHistory = {}
            end
            local sessionData = {
                endTime = time(),
                duration = elapsedTime,
                entries = {}
            }
            if db.farmSession and db.farmSession.entries then
                for _, entry in ipairs(db.farmSession.entries) do
                    table.insert(sessionData.entries, { itemID = entry.itemID, source = entry.source, count = tonumber(entry.count or 0) })
                end
            end
            table.insert(db.farmSessionHistory, sessionData)
            frame.timerText:SetText("Farm Session : None")
            frame.lastSessionText:SetText("Last session : " .. FormatTime(elapsedTime))
        else
            isFarmSessionActive = true
            farmButton:SetText("Stop Farm")
            db.farmSession = {}
            db.farmSession.entries = {}
            farmStartTime = time()
            db.farmSession.startTime = farmStartTime
            farmTimerFrame:SetScript("OnUpdate", function(self, elapsed)
                self.timeSinceLastUpdate = (self.timeSinceLastUpdate or 0) + elapsed
                if self.timeSinceLastUpdate >= 1 then
                    local elapsedTime = time() - farmStartTime
                    frame.timerText:SetText("Current Farm Session : " .. FormatTime(elapsedTime))
                    self.timeSinceLastUpdate = 0
                end
            end)
        end
        local updateTableFunc = frame.UpdateTable
        if updateTableFunc then
            updateTableFunc()
        end
    end)

    frame.resetButton = CreateFrame("Button", "LootCounterResetFarmButton", frame, "UIPanelButtonTemplate")
    frame.resetButton:SetPoint("BOTTOM", 0, 10)
    frame.resetButton:SetSize(100, 30)
    frame.resetButton:SetText("Reinit")
    frame.resetButton:SetScript("OnClick", function()
        if isFarmSessionActive then
            return
        end
        db.farmSession = {}
        db.farmSession.entries = {}
        frame.timerText:SetText("Session de farm : Aucune")
        local updateTableFunc = frame.UpdateTable
        if updateTableFunc then
            updateTableFunc()
        end
    end)

    local function UpdateTable()
        if frame.currentView ~= "current" then return end

        if content.rows then
            for _, row in ipairs(content.rows) do
                row:Hide()
            end
        end
        content.rows = {}

        local sortedEntries = {}
        if db.farmSession and db.farmSession.entries then
            for _, entry in ipairs(db.farmSession.entries) do
                local itemName = GetItemInfo(entry.itemID)
                if itemName then
                    table.insert(sortedEntries, { itemName = itemName, itemID = entry.itemID, source = entry.source, count = tonumber(entry.count or 0) })
                end
            end
        end

        if frame.sortMode == "name" then
            table.sort(sortedEntries, function(a, b)
                return a.itemName < b.itemName
            end)
        elseif frame.sortMode == "source" then
            table.sort(sortedEntries, function(a, b)
                return a.source < b.source
            end)
        elseif frame.sortMode == "count" then
            table.sort(sortedEntries, function(a, b)
                return a.count > b.count
            end)
        end

        local yOffset = -30
        local rowIndex = 1
        for _, entry in ipairs(sortedEntries) do
            local itemName, itemLink = GetItemInfo(entry.itemID)
            if itemName then
                local row = CreateFrame("Frame", null, content)
                row:SetPoint("TOPLEFT", 10, yOffset)
                row:SetSize(500, 20)

                local col1 = row:CreateFontString(null, "OVERLAY", "GameFontHighlight")
                col1:SetPoint("LEFT", 0, 0)
                col1:SetText(itemLink or itemName)
                col1:SetWidth(190)
                col1:SetJustifyH("LEFT")
                row:EnableMouse(true)
                row:SetScript("OnEnter", function()
                    GameTooltip:SetOwner(row, "ANCHOR_RIGHT")
                    GameTooltip:SetHyperlink("item:" .. entry.itemID)
                    GameTooltip:Show()
                end)
                row:SetScript("OnLeave", function()
                    GameTooltip:Hide()
                end)

                local col2 = row:CreateFontString(null, "OVERLAY", "GameFontHighlight")
                col2:SetPoint("LEFT", 200, 0)
                col2:SetWidth(200)
                col2:SetJustifyH("LEFT")
                col2:SetText(entry.source)

                local col3 = row:CreateFontString(null, "OVERLAY", "GameFontHighlight")
                col3:SetPoint("LEFT", 400, 0)
                col3:SetText(entry.count)

                table.insert(content.rows, row)
                yOffset = yOffset - 20
                rowIndex = rowIndex + 1
            end
        end
        content:SetHeight(rowIndex * 20)
    end

    local function UpdateHistoryTable()
        if frame.currentView ~= "history" then return end

        if historyContent.rows then
            for _, row in ipairs(historyContent.rows) do
                row:Hide()
            end
        end
        historyContent.rows = {}

        local yOffset = -10
        local rowIndex = 1
        if db.farmSessionHistory and type(db.farmSessionHistory) == "table" then
            for i, session in ipairs(db.farmSessionHistory) do
                local sessionHeader = historyContent:CreateFontString(null, "OVERLAY", "GameFontNormal")
                sessionHeader:SetPoint("TOPLEFT", 10, yOffset)
                sessionHeader:SetText("Session " .. i .. " (" .. date("%Y-%m-%d %H:%M:%S", session.endTime) .. ", Last For: " .. FormatTime(session.duration) .. ")")
                table.insert(historyContent.rows, sessionHeader)
                yOffset = yOffset - 20

                if session.entries and type(session.entries) == "table" then
                    for _, entry in ipairs(session.entries) do
                        local itemName, itemLink = GetItemInfo(entry.itemID)
                        if itemName then
                            local row = CreateFrame("Frame", null, historyContent)
                            row:SetPoint("TOPLEFT", 10, yOffset)
                            row:SetSize(500, 20)

                            local col1 = row:CreateFontString(null, "OVERLAY", "GameFontHighlight")
                            col1:SetPoint("LEFT", 0, 0)
                            col1:SetText(itemLink or itemName)
                            col1:SetWidth(190)
                            col1:SetJustifyH("LEFT")
                            row:EnableMouse(true)
                            row:SetScript("OnEnter", function()
                                GameTooltip:SetOwner(row, "ANCHOR_RIGHT")
                                GameTooltip:SetHyperlink("item:" .. entry.itemID)
                                GameTooltip:Show()
                            end)
                            row:SetScript("OnLeave", function()
                                GameTooltip:Hide()
                            end)

                            local col2 = row:CreateFontString(null, "OVERLAY", "GameFontHighlight")
                            col2:SetPoint("LEFT", 200, 0)
                            col2:SetWidth(200)
                            col2:SetJustifyH("LEFT")
                            col2:SetText(entry.source)

                            local col3 = row:CreateFontString(null, "OVERLAY", "GameFontHighlight")
                            col3:SetPoint("LEFT", 400, 0)
                            col3:SetText(tonumber(entry.count or 0))

                            table.insert(historyContent.rows, row)
                            yOffset = yOffset - 20
                            rowIndex = rowIndex + 1
                        end
                    end
                end
                yOffset = yOffset - 10
            end
        else
            local noHistoryText = historyContent:CreateFontString(null, "OVERLAY", "GameFontNormal")
            noHistoryText:SetPoint("TOPLEFT", 10, yOffset)
            noHistoryText:SetText("Aucune session dans l'historique.")
            table.insert(historyContent.rows, noHistoryText)
            rowIndex = rowIndex + 1
        end
        historyContent:SetHeight(rowIndex * 20)
    end

    frame.UpdateTable = UpdateTable
    frame.UpdateHistoryTable = UpdateHistoryTable

    UpdateTable()

    if db.farmSessionHistory and #db.farmSessionHistory > 0 then
        local lastSession = db.farmSessionHistory[#db.farmSessionHistory]
        frame.lastSessionText:SetText("Last session : " .. FormatTime(lastSession.duration))
    end

    if isFarmSessionActive and db.farmSession and db.farmSession.startTime then
        farmStartTime = db.farmSession.startTime
        farmButton:SetText("Stop Farm")
        farmTimerFrame:SetScript("OnUpdate", function(self, elapsed)
            self.timeSinceLastUpdate = (self.timeSinceLastUpdate or 0) + elapsed
            if self.timeSinceLastUpdate >= 1 then
                local elapsedTime = time() - farmStartTime
                frame.timerText:SetText("Current Farm Session : " .. FormatTime(elapsedTime))
                self.timeSinceLastUpdate = 0
            end
        end)
    end
    
    frame:Hide()
    return frame
end

-- Gestionnaire d'événements
frame:SetScript("OnEvent", function(self, event, arg1, ...)
    if event == "ADDON_LOADED" and arg1 == addonName then
        if not LootCounterDB then
            LootCounterDB = {}
        end
        db = LootCounterDB

        if not db.entries then
            db.entries = {}
        end

        if not db.farmSessionHistory then
            db.farmSessionHistory = {}
        end
        if not db.farmSession then
            db.farmSession = {}
        end
        if not db.farmSession.entries then
            db.farmSession.entries = {}
        end

        globalStatsWindow = CreateGlobalStatsWindow()
        sessionStatsWindow = CreateSessionStatsWindow()
    elseif event == "PLAYER_LOGIN" then
        db = LootCounterDB or {}
        LootCounterDB = db

        -- Nettoyer les données pour s'assurer que count est un nombre
        if db.entries then
            for _, entry in ipairs(db.entries) do
                entry.count = tonumber(entry.count or 0)
            end
        end
        if db.farmSession and db.farmSession.entries then
            for _, entry in ipairs(db.farmSession.entries) do
                entry.count = tonumber(entry.count or 0)
            end
        end
        if db.farmSessionHistory then
            for _, session in ipairs(db.farmSessionHistory) do
                if session.entries then
                    for _, entry in ipairs(session.entries) do
                        entry.count = tonumber(entry.count or 0)
                    end
                end
            end
        end

        if db[1] or db.testValue then
            local oldData = db
            db = {}
            db.entries = {}
            for itemID, data in pairs(oldData) do
                if type(itemID) == "number" and data.sources then
                    for source, count in pairs(data.sources) do
                        table.insert(db.entries, { itemID = itemID, source = source, count = tonumber(count or 0) })
                    end
                end
            end
            if oldData.farmSession and oldData.farmSession[1] then
                db.farmSession = {}
                db.farmSession.entries = {}
                for itemID, data in pairs(oldData.farmSession) do
                    if type(itemID) == "number" and data.sources then
                        for source, count in pairs(data.sources) do
                            table.insert(db.farmSession.entries, { itemID = itemID, source = source, count = tonumber(count or 0) })
                        end
                    end
                end
                if oldData.farmSession.startTime then
                    db.farmSession.startTime = oldData.farmSession.startTime
                end
            end
            db.farmSessionHistory = oldData.farmSessionHistory or {}
        end

        if not db.entries then
            db.entries = {}
        end
        if not db.farmSession then
            db.farmSession = {}
        end
        if not db.farmSession.entries then
            db.farmSession.entries = {}
        end
        if not db.farmSessionHistory then
            db.farmSessionHistory = {}
        end

        if db.farmSession and db.farmSession.startTime then
            isFarmSessionActive = true
            farmStartTime = db.farmSession.startTime
        end

        if TooltipDataProcessor and TooltipDataProcessor.AddTooltipPostCall then
            TooltipDataProcessor.AddTooltipPostCall(Enum.TooltipDataType.Item, function(tooltip)
                UpdateTooltip(tooltip)
            end)
        end
    elseif event == "CHAT_MSG_LOOT" or event == "COMBAT_LOG_EVENT_UNFILTERED" or event == "PLAYER_TARGET_CHANGED" or event == "LOOT_OPENED" then
        TrackLoot(self, event, arg1, ...)
        if event == "CHAT_MSG_LOOT" then
            currentMiningSource = nil
        end    
    elseif event == "PLAYER_LOGOUT" then
        LootCounterDB = db
    end
end)

-- Hook pour détecter les gisements ou objets interactifs
GameTooltip:HookScript("OnShow", function(self)
    local tooltipText = GameTooltipTextLeft1:GetText()
    if tooltipText then
        lastMouseoverTarget = tooltipText
        if tooltipText:find("Gisement") or tooltipText:find("Veine") or tooltipText:find("Deposit") or tooltipText:find("Riche") or tooltipText:find("Mine-Trankil") or tooltipText:find("Bismuth") or tooltipText:find("Griffefer") then
            lastMiningTarget = tooltipText
            lastMiningTime = time()
        end
    end
end)

-- Commandes slash
SLASH_LOOTCOUNTER1 = "/lootcounter"
SlashCmdList["LOOTCOUNTER"] = function(msg)
    if msg == "show" then
        if globalStatsWindow then
            globalStatsWindow:Show()
        end
    elseif msg == "hide" then
        if globalStatsWindow then
            globalStatsWindow:Hide()
        end
    elseif msg == "showsession" then
        if sessionStatsWindow then
            sessionStatsWindow:Show()
        end
    elseif msg == "hidesession" then
        if sessionStatsWindow then
            sessionStatsWindow:Hide()
        end
    end
end