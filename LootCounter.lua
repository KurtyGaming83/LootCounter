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
	
}

-- Fonction pour détecter la source du loot
local function GetLootSource(itemID, miningSource)
    local isMineral = mineralItems[itemID] or false
    -- Priorité 1 : Minage récent (utiliser miningSource si disponible)
    if miningSource then
        -- print("Source (minage récent) : " .. miningSource)
        return miningSource
    end
    -- Priorité 2 : Source de la session de loot en cours (définie dans LOOT_OPENED)
    if currentLootSource then
        -- print("Source (session de loot) : " .. currentLootSource)
        return currentLootSource
    end
    -- Priorité 3 : Ennemi tué
    if lastEnemyKilled then
        -- print("Source (ennemi tué) : " .. lastEnemyKilled)
        return lastEnemyKilled
    end
    -- Priorité 4 : Objet interactif
    if lastMouseoverTarget and interactiveObjects[lastMouseoverTarget] then
        -- print("Source (objet interactif) : " .. lastMouseoverTarget)
        return lastMouseoverTarget
    end
    -- Dernier recours
    -- print("Aucune source détectée")
    return "Inconnu"
end

-- Fonction pour analyser les messages de loot
local function TrackLoot(self, event, message, ...)
    if event == "CHAT_MSG_LOOT" and message then
        -- Vérifier que le message concerne ton propre loot
        if not message:match("^Vous recevez") and not message:match("^You receive") then
            return -- Ignore les loots des autres joueurs
        end
		
        local itemLink = string.match(message, "|Hitem:.-|h.-|h")
        if itemLink then
            local itemID = string.match(itemLink, "item:(%d+)")
            if itemID then
                itemID = tonumber(itemID)
                local quantity = string.match(message, "x(%d+)") or 1
                quantity = tonumber(quantity)
                -- print("Debug avant GetLootSource - lastEnemyKilled: " .. (lastEnemyKilled or "nil") .. ", currentLootSource: " .. (currentLootSource or "nil"))
                local source = GetLootSource(itemID, currentMiningSource) -- Utiliser currentMiningSource
                -- print("Item ID " .. itemID .. " compté, source : " .. source .. ", quantity : " .. quantity)
                if not db.entries then
                    db.entries = {}
                end
                local found = false
                for _, entry in ipairs(db.entries) do
                    if entry.itemID == itemID and entry.source == source then
                        entry.count = entry.count + quantity
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
                            entry.count = entry.count + quantity
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
                else
                    -- print("Erreur : globalStatsWindow ou UpdateTable non défini")
                end
                if sessionStatsWindow and sessionStatsWindow.UpdateTable then
                    sessionStatsWindow.UpdateTable()
                else
                    -- print("Erreur : sessionStatsWindow ou UpdateTable non défini")
                end
            else
                -- print("Erreur : Impossible d'extraire l'item ID")
            end
        else
            -- print("Erreur : Aucun lien d'item trouvé dans le message")
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
                -- print("Ennemi tué : " .. lastEnemyKilled .. ", Timestamp: " .. lastEnemyKilledTime)
            end
        end
    elseif event == "LOOT_OPENED" then
        -- print("LOOT_OPENED déclenché - lastEnemyKilled: " .. (lastEnemyKilled or "nil") .. ", lastMouseoverTarget: " .. (lastMouseoverTarget or "nil") .. ", lastTarget: " .. (lastTarget or "nil"))
        local sourceName = lastMouseoverTarget or lastTarget
        -- Stocker la source de minage au moment de LOOT_OPENED
        local miningSource = nil
        if lastMiningTarget and lastMiningTime and (time() - lastMiningTime) <= 10 then
            miningSource = lastMiningTarget
            currentLootSource = lastMiningTarget
            -- print("Loot ouvert, source de minage détectée (via lastMiningTarget) : " .. lastMiningTarget)
        elseif sourceName and (sourceName:find("Gisement") or sourceName:find("Veine") or sourceName:find("Deposit") or sourceName:find("Riche") or sourceName:find("Mine-Trankil") or sourceName:find("Bismuth") or sourceName:find("Griffefer")) then
            lastMiningTarget = sourceName
            lastMiningTime = time()
            miningSource = sourceName
            currentLootSource = sourceName
            -- print("Loot ouvert, source de minage détectée : " .. lastMiningTarget)
        elseif sourceName and interactiveObjects[sourceName] then
            currentLootSource = sourceName
            -- print("Loot ouvert, objet interactif détecté : " .. sourceName)
        elseif sourceName then
            currentLootSource = sourceName
            -- print("Loot ouvert, source par défaut (lastMouseoverTarget ou lastTarget) : " .. sourceName)
        else
            if lastEnemyKilled then
                currentLootSource = lastEnemyKilled
                -- print("Loot ouvert, source ennemie détectée : " .. lastEnemyKilled)
            end
        end
        -- Stocker la source de minage pour les appels à GetLootSource
        currentMiningSource = miningSource
    end
end

-- Fonction pour modifier le tooltip (déplacée avant le gestionnaire d'événements)
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
                    totalCount = totalCount + entry.count
                end
            end
        end
        if isFarmSessionActive and db.farmSession and db.farmSession.entries then
            for _, entry in ipairs(db.farmSession.entries) do
                if entry.itemID == itemID then
                    sessionCount = sessionCount + entry.count
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

	-- Bouton Farm (toggle pour ouvrir/fermer la fenêtre de session)
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
        else
            -- print("La fenêtre de session n'est pas encore prête.")
        end
    end)

    -- Boutons de tri (placés directement dans la frame principale, au-dessus du ScrollFrame)
    local sortByNameButton = CreateFrame("Button", "LootCounterGlobalSortByNameButton", frame, "UIPanelButtonTemplate")
    sortByNameButton:SetPoint("TOPLEFT", 10, -30)
    sortByNameButton:SetSize(80, 20)
    sortByNameButton:SetText("Item Name")
    sortByNameButton:SetScript("OnClick", function()
        frame.sortMode = "name"
        frame.UpdateTable()
    end)

    local sortBySourceButton = CreateFrame("Button", "LootCounterGlobalSortBySourceButton", frame, "UIPanelButtonTemplate")
    sortBySourceButton:SetPoint("TOPLEFT", 260, -30) -- Aligné avec la colonne Source
    sortBySourceButton:SetSize(80, 20)
    sortBySourceButton:SetText("Source")
    sortBySourceButton:SetScript("OnClick", function()
        frame.sortMode = "source"
        frame.UpdateTable()
    end)

    local sortByCountButton = CreateFrame("Button", "LootCounterGlobalSortByCountButton", frame, "UIPanelButtonTemplate")
    sortByCountButton:SetPoint("TOPLEFT", 460, -30) -- Aligné avec la colonne Quantité
    sortByCountButton:SetSize(80, 20)
    sortByCountButton:SetText("Quantity")
    sortByCountButton:SetScript("OnClick", function()
        frame.sortMode = "count"
        frame.UpdateTable()
    end)

    frame.sortMode = "name"

    -- ScrollFrame pour le tableau (commence plus bas pour laisser de la place aux boutons)
    local scrollFrame = CreateFrame("ScrollFrame", "LootCounterGlobalStatsScrollFrame", frame, "UIPanelScrollFrameTemplate")
    scrollFrame:SetPoint("TOPLEFT", 10, -60) -- Décalé vers le bas pour laisser de la place aux boutons
    scrollFrame:SetPoint("BOTTOMRIGHT", -30, 10)

    local content = CreateFrame("Frame", "LootCounterGlobalStatsContent", scrollFrame)
    content:SetSize(500, 200)
    scrollFrame:SetScrollChild(content)

    -- Fonction pour mettre à jour le tableau
    local function UpdateTable()
        if content.rows then
            for _, row in ipairs(content.rows) do
                row:Hide()
            end
        end
        content.rows = {}

        local sortedEntries = {}
        for _, entry in ipairs(db.entries) do
            local itemName = GetItemInfo(entry.itemID)
            if itemName then
                table.insert(sortedEntries, { itemName = itemName, itemID = entry.itemID, source = entry.source, count = entry.count })
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

        local yOffset = -10 -- Plus besoin d'espace pour les en-têtes
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
                col1:SetWidth(250) -- Augmenter la largeur de la colonne Nom
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
                col2:SetWidth(200) -- Augmenter la largeur de la colonne Source
                col2:SetJustifyH("LEFT")
                col2:SetText(entry.source)

                local col3 = row:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
                col3:SetPoint("LEFT", 450, 0)
                col3:SetWidth(100) -- Réduire la largeur de la colonne Quantité
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
    frame:SetSize(550, 350)
    frame:SetPoint("CENTER", 200, 0)
    frame:SetMovable(true)
    frame:EnableMouse(true)
    frame:RegisterForDrag("LeftButton")
    frame:SetScript("OnDragStart", frame.StartMoving)
    frame:SetScript("OnDragStop", frame.StopMovingOrSizing)

    -- Stocker la référence à la fenêtre
    sessionStatsWindow = frame

    -- Titre
    frame.title = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    frame.title:SetPoint("TOP", 0, -5)
    frame.title:SetText("Loot Counter - Session de Farm")

    -- Onglets pour basculer entre "Session Actuelle" et "Historique"
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
        -- Afficher les boutons de tri
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
        -- Masquer les boutons de tri
        frame.sortButtons.name:Hide()
        frame.sortButtons.source:Hide()
        frame.sortButtons.count:Hide()
    end)

    -- Vue par défaut
    frame.currentView = "current"

    -- Texte pour le chronomètre
    frame.timerText = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    frame.timerText:SetPoint("TOPLEFT", 10, -60)
    frame.timerText:SetText("Farm Session : None")

    -- Texte pour la dernière session terminée
    frame.lastSessionText = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    frame.lastSessionText:SetPoint("TOPRIGHT", -10, -60)
    frame.lastSessionText:SetText("")

    -- Boutons de tri pour la vue "Session Actuelle"
    frame.sortButtons = {} -- Créer une table pour stocker les boutons
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

    -- Mode de tri par défaut
    frame.sortMode = "name"

    -- ScrollFrame pour la vue "Session Actuelle"
    frame.scrollFrame = CreateFrame("ScrollFrame", "LootCounterSessionStatsScrollFrame", frame, "UIPanelScrollFrameTemplate")
    frame.scrollFrame:SetPoint("TOPLEFT", 10, -110)
    frame.scrollFrame:SetPoint("BOTTOMRIGHT", -30, 50)

    local content = CreateFrame("Frame", "LootCounterSessionStatsContent", frame.scrollFrame)
    content:SetSize(500, 200)
    frame.scrollFrame:SetScrollChild(content)


    -- ScrollFrame pour la vue "Historique"
    frame.historyScrollFrame = CreateFrame("ScrollFrame", "LootCounterSessionHistoryScrollFrame", frame, "UIPanelScrollFrameTemplate")
    frame.historyScrollFrame:SetPoint("TOPLEFT", 10, -30)
    frame.historyScrollFrame:SetPoint("BOTTOMRIGHT", -30, 10)
    frame.historyScrollFrame:Hide()

    local historyContent = CreateFrame("Frame", "LootCounterSessionHistoryContent", frame.historyScrollFrame)
    historyContent:SetSize(500, 200)
    frame.historyScrollFrame:SetScrollChild(historyContent)

    -- Bouton Start/Stop pour la session de farm
    farmButton = CreateFrame("Button", "LootCounterFarmButton", frame, "UIPanelButtonTemplate")
    farmButton:SetPoint("BOTTOMLEFT", 10, 10)
    farmButton:SetSize(100, 30)
    farmButton:SetText(isFarmSessionActive and "Stop Farm" or "Start Farm")
    farmButton:SetScript("OnClick", function()
        if isFarmSessionActive then
            isFarmSessionActive = false
            farmButton:SetText("Start Farm")
            farmTimerFrame:SetScript("OnUpdate", nil) -- Arrêter le timer
            local elapsedTime = time() - farmStartTime
            -- Sauvegarder la session dans l'historique avec les items lootés
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
                    table.insert(sessionData.entries, { itemID = entry.itemID, source = entry.source, count = entry.count })
                end
            end
            table.insert(db.farmSessionHistory, sessionData)
            frame.timerText:SetText("Farm Session : None")
            frame.lastSessionText:SetText("Last session : " .. FormatTime(elapsedTime))
            -- print("Session de farm terminée, durée : " .. FormatTime(elapsedTime))
        else
            isFarmSessionActive = true
            farmButton:SetText("Stop Farm")
            db.farmSession = {} -- Réinitialiser la session de farm
            db.farmSession.entries = {} -- Réinitialiser les entrées de la session
            farmStartTime = time() -- Enregistrer le temps de départ
            db.farmSession.startTime = farmStartTime -- Sauvegarder dans la DB
            -- Mettre à jour le timer toutes les secondes
            farmTimerFrame:SetScript("OnUpdate", function(self, elapsed)
                self.timeSinceLastUpdate = (self.timeSinceLastUpdate or 0) + elapsed
                if self.timeSinceLastUpdate >= 1 then
                    local elapsedTime = time() - farmStartTime
                    frame.timerText:SetText("Current Farm Session : " .. FormatTime(elapsedTime))
                    self.timeSinceLastUpdate = 0
                end
            end)
            -- print("Session de farm démarrée")
        end
        -- Rafraîchir le tableau après avoir modifié l'état
        local updateTableFunc = frame.UpdateTable
        if updateTableFunc then
            updateTableFunc()
        end
    end)

    -- Bouton pour réinitialiser les données de farm
    frame.resetButton = CreateFrame("Button", "LootCounterResetFarmButton", frame, "UIPanelButtonTemplate")
    frame.resetButton:SetPoint("BOTTOM", 0, 10)
    frame.resetButton:SetSize(100, 30)
    frame.resetButton:SetText("Reinit")
    frame.resetButton:SetScript("OnClick", function()
        if isFarmSessionActive then
            -- print("Arrêtez la session de farm avant de réinitialiser.")
            return
        end
        db.farmSession = {}
        db.farmSession.entries = {}
        frame.timerText:SetText("Session de farm : Aucune")
        local updateTableFunc = frame.UpdateTable
        if updateTableFunc then
            updateTableFunc()
        end
        -- print("Données de farm réinitialisées")
    end)

    -- Fonction pour mettre à jour le tableau (Session Actuelle)
    local function UpdateTable()
        if frame.currentView ~= "current" then return end

        -- Supprimer les anciennes lignes
        if content.rows then
            for _, row in ipairs(content.rows) do
                row:Hide()
            end
        end
        content.rows = {}

        -- Créer une table temporaire pour trier les entrées
        local sortedEntries = {}
        if db.farmSession and db.farmSession.entries then
            for _, entry in ipairs(db.farmSession.entries) do
                local itemName = GetItemInfo(entry.itemID)
                if itemName then
                    table.insert(sortedEntries, { itemName = itemName, itemID = entry.itemID, source = entry.source, count = entry.count })
                end
            end
        end

        -- Trier les entrées selon le mode de tri
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

        -- Ajouter les nouvelles lignes
        local yOffset = -30
        local rowIndex = 1
        for _, entry in ipairs(sortedEntries) do
            local itemName, itemLink = GetItemInfo(entry.itemID)
            if itemName then
                local row = CreateFrame("Frame", nil, content)
                row:SetPoint("TOPLEFT", 10, yOffset)
                row:SetSize(500, 20)

                -- Nom de l'item (cliquable avec tooltip)
                local col1 = row:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
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

                -- Source
                local col2 = row:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
                col2:SetPoint("LEFT", 200, 0)
                col2:SetWidth(200)
                col2:SetJustifyH("LEFT")
                col2:SetText(entry.source)

                -- Quantité
                local col3 = row:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
                col3:SetPoint("LEFT", 400, 0)
                col3:SetText(entry.count)

                table.insert(content.rows, row)
                yOffset = yOffset - 20
                rowIndex = rowIndex + 1
            end
        end
        content:SetHeight(rowIndex * 20)
    end

    -- Fonction pour mettre à jour le tableau (Historique)
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
		-- print("Debug - db.farmSessionHistory : " .. tostring(db.farmSessionHistory))
		if db.farmSessionHistory and type(db.farmSessionHistory) == "table" then
			for i, session in ipairs(db.farmSessionHistory) do
				local sessionHeader = historyContent:CreateFontString(nil, "OVERLAY", "GameFontNormal")
				sessionHeader:SetPoint("TOPLEFT", 10, yOffset)
				sessionHeader:SetText("Session " .. i .. " (" .. date("%Y-%m-%d %H:%M:%S", session.endTime) .. ", Last For: " .. FormatTime(session.duration) .. ")")
				table.insert(historyContent.rows, sessionHeader)
				yOffset = yOffset - 20

				-- Vérifier que session.entries est une table avant d'itérer
				if session.entries and type(session.entries) == "table" then
					for _, entry in ipairs(session.entries) do
						local itemName, itemLink = GetItemInfo(entry.itemID)
						if itemName then
							local row = CreateFrame("Frame", nil, historyContent)
							row:SetPoint("TOPLEFT", 10, yOffset)
							row:SetSize(500, 20)

							local col1 = row:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
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

							local col2 = row:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
							col2:SetPoint("LEFT", 200, 0)
							col2:SetWidth(200)
							col2:SetJustifyH("LEFT")
							col2:SetText(entry.source)

							local col3 = row:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
							col3:SetPoint("LEFT", 400, 0)
							col3:SetText(entry.count)

							table.insert(historyContent.rows, row)
							yOffset = yOffset - 20
							rowIndex = rowIndex + 1
						end
					end
				else
					-- print("Debug - session.entries manquant ou invalide pour la session " .. i)
				end
				yOffset = yOffset - 10
			end
		else
			local noHistoryText = historyContent:CreateFontString(nil, "OVERLAY", "GameFontNormal")
			noHistoryText:SetPoint("TOPLEFT", 10, yOffset)
			noHistoryText:SetText("Aucune session dans l'historique.")
			table.insert(historyContent.rows, noHistoryText)
			rowIndex = rowIndex + 1
		end
		historyContent:SetHeight(rowIndex * 20)
	end

    -- Stocker les fonctions UpdateTable et UpdateHistoryTable dans le frame
    frame.UpdateTable = UpdateTable
    frame.UpdateHistoryTable = UpdateHistoryTable

    -- Mettre à jour le tableau au démarrage
    UpdateTable()

    -- Afficher la durée de la dernière session terminée
    if db.farmSessionHistory and #db.farmSessionHistory > 0 then
        local lastSession = db.farmSessionHistory[#db.farmSessionHistory]
        frame.lastSessionText:SetText("Last session : " .. FormatTime(lastSession.duration))
    end

    -- Restaurer le chronomètre si une session est en cours
    if isFarmSessionActive and db.farmSession and db.farmSession.startTime then
        farmStartTime = db.farmSession.startTime
        farmButton:SetText("Stop Farm")
        farmTimerFrame:SetScript("OnUpdate", function(self, elapsed)
            self.timeSinceLastUpdate = (self.timeSinceLastUpdate or 0) + elapsed
            if self.timeSinceLastUpdate >= 1 then
                local elapsedTime = time() - farmStartTime
                frame.timerText:SetText("Session de farm en cours : " .. FormatTime(elapsedTime))
                self.timeSinceLastUpdate = 0
            end
        end)
    end
	
	-- Masquer la fenêtre par défaut
    frame:Hide()

    return frame
end

-- Gestionnaire d'événements (doit être défini après toutes les fonctions qu'il utilise)
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
            -- print("Initialisation de db.farmSessionHistory")
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
        -- print("Loot Counter chargé !")
        db = LootCounterDB or {}
        LootCounterDB = db

        if db[1] or db.testValue then
            local oldData = db
            db = {}
            db.entries = {}
            for itemID, data in pairs(oldData) do
                if type(itemID) == "number" and data.sources then
                    for source, count in pairs(data.sources) do
                        table.insert(db.entries, { itemID = itemID, source = source, count = count })
                    end
                end
            end
            if oldData.farmSession and oldData.farmSession[1] then
                db.farmSession = {}
                db.farmSession.entries = {}
                for itemID, data in pairs(oldData.farmSession) do
                    if type(itemID) == "number" and data.sources then
                        for source, count in pairs(data.sources) do
                            table.insert(db.farmSession.entries, { itemID = itemID, source = source, count = count })
                        end
                    end
                end
                if oldData.farmSession.startTime then
                    db.farmSession.startTime = oldData.farmSession.startTime
                end
            end
            -- Toujours initialiser db.farmSessionHistory, même si oldData.farmSessionHistory n'existe pas
            db.farmSessionHistory = oldData.farmSessionHistory or {}
        end

        -- S'assurer que les structures nécessaires existent
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

        -- print("Contenu de LootCounterDB au démarrage :")
        for key, value in pairs(db) do
            if key == "farmSession" then
                -- print("Session de farm :")
                if value.entries then
                    for _, entry in ipairs(value.entries) do
                        -- print("Item ID " .. entry.itemID .. " : { source = " .. entry.source .. ", count = " .. entry.count .. " }")
                    end
                end
            elseif key == "farmSessionHistory" then
                -- print("Historique des sessions de farm :")
                for i, session in ipairs(value) do
                    -- print("Session " .. i .. " : durée = " .. FormatTime(session.duration) .. ", terminée à " .. date("%Y-%m-%d %H:%M:%S", session.endTime))
                    if session.entries then
                        for _, entry in ipairs(session.entries) do
                            -- print("  Item ID " .. entry.itemID .. " : { source = " .. entry.source .. ", count = " .. entry.count .. " }")
                        end
                    end
                end
            elseif key == "entries" then
                -- print("Entrées globales :")
                for _, entry in ipairs(value) do
                    -- print("Item ID " .. entry.itemID .. " : { source = " .. entry.source .. ", count = " .. entry.count .. " }")
                end
            end
        end

        if db.farmSession and db.farmSession.startTime then
            isFarmSessionActive = true
            farmStartTime = db.farmSession.startTime
        end

        if TooltipDataProcessor and TooltipDataProcessor.AddTooltipPostCall then
            TooltipDataProcessor.AddTooltipPostCall(Enum.TooltipDataType.Item, function(tooltip)
                UpdateTooltip(tooltip)
            end)
            -- print("Hook TooltipDataProcessor configuré")
        else
            -- print("TooltipDataProcessor non disponible")
        end
    elseif event == "CHAT_MSG_LOOT" or event == "COMBAT_LOG_EVENT_UNFILTERED" or event == "PLAYER_TARGET_CHANGED" or event == "LOOT_OPENED" then
        TrackLoot(self, event, arg1, ...)
	    if event == "CHAT_MSG_LOOT" then
            currentMiningSource = nil
        end	
    elseif event == "PLAYER_LOGOUT" then
        -- print("Sauvegarde de LootCounterDB avant déconnexion :")
        for key, value in pairs(db) do
            if key == "farmSession" then
                -- print("Session de farm :")
                if value.entries then
                    for _, entry in ipairs(value.entries) do
                        -- print("Item ID " .. entry.itemID .. " : { source = " .. entry.source .. ", count = " .. entry.count .. " }")
                    end
                end
            elseif key == "farmSessionHistory" then
                -- print("Historique des sessions de farm :")
                for i, session in ipairs(value) do
                    -- print("Session " .. i .. " : durée = " .. FormatTime(session.duration) .. ", terminée à " .. date("%Y-%m-%d %H:%M:%S", session.endTime))
                    if session.entries then
                        for _, entry in ipairs(session.entries) do
                            -- print("  Item ID " .. entry.itemID .. " : { source = " .. entry.source .. ", count = " .. entry.count .. " }")
                        end
                    end
                end
            elseif key == "entries" then
                -- print("Entrées globales :")
                for _, entry in ipairs(value) do
                    -- print("Item ID " .. entry.itemID .. " : { source = " .. entry.source .. ", count = " .. entry.count .. " }")
                end
            end
        end
        LootCounterDB = db
    end
end)

-- Hook pour détecter les gisements ou objets interactifs survolés via le tooltip
GameTooltip:HookScript("OnShow", function(self)
    local tooltipText = GameTooltipTextLeft1:GetText()
    if tooltipText then
        -- print("Tooltip détecté : " .. tooltipText)
        lastMouseoverTarget = tooltipText
        if tooltipText:find("Gisement") or tooltipText:find("Veine") or tooltipText:find("Deposit") or tooltipText:find("Riche") or tooltipText:find("Mine-Trankil") or tooltipText:find("Bismuth") or tooltipText:find("Griffefer") then
            lastMiningTarget = tooltipText
            lastMiningTime = time()
            -- print("Objet survolé détecté via tooltip (minage) : " .. lastMouseoverTarget)
        elseif interactiveObjects[tooltipText] then
            -- print("Objet survolé détecté via tooltip (interactif) : " .. lastMouseoverTarget)
        end
    end
end)

-- Commandes pour afficher les fenêtres
SLASH_LOOTCOUNTER1 = "/lootcounter"
SlashCmdList["LOOTCOUNTER"] = function(msg)
    if msg == "show" then
        if globalStatsWindow then
            globalStatsWindow:Show()
        else
            -- print("La fenêtre globale n'est pas encore prête.")
        end
    elseif msg == "hide" then
        if globalStatsWindow then
            globalStatsWindow:Hide()
        else
            -- print("La fenêtre globale n'est pas encore prête.")
        end
    elseif msg == "showsession" then
        if sessionStatsWindow then
            sessionStatsWindow:Show()
        else
            -- print("La fenêtre de session n'est pas encore prête.")
        end
    elseif msg == "hidesession" then
        if sessionStatsWindow then
            sessionStatsWindow:Hide()
        else
            -- print("La fenêtre de session n'est pas encore prête.")
        end
    end
end