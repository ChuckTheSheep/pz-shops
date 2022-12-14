require "client/XpSystem/ISUI/ISCharacterInfo"
require "shop-globalModDataClient"
require "ISUI/ISInventoryPaneContextMenu"
require "ISUI/ISTextBox"
require "luautils"

local function modifyScript()
    for _,type in pairs(_internal.getMoneyTypes()) do
        ---@type Item
        local script = getScriptManager():getItem(type)
        local weight = SandboxVars.ShopsAndTraders.MoneyWeight
        if script then
            script:setActualWeight(weight)
            script:DoParam("DisplayCategory = Money")
        end
    end
end
Events.OnGameBoot.Add(modifyScript)


---@param playerObj IsoPlayer|IsoGameCharacter|IsoMovingObject|IsoObject
function getOrSetWalletID(playerObj)
    playerObj = playerObj or getPlayer()
    if not playerObj then return end
    local playerModData = playerObj:getModData()
    if not playerModData then print("WARN: Player created without modData - can't append wallet.") return end
    if not playerModData.wallet_UUID then playerModData.wallet_UUID = getRandomUUID() end

    local playerWallet = CLIENT_WALLETS[playerModData.wallet_UUID]
    local forceMoneyOut = (SandboxVars.ShopsAndTraders.PlayerWallets==false and playerWallet and playerWallet.amount>0)

    if not playerWallet or (playerWallet and (not playerWallet.playerUsername or forceMoneyOut)) then
        sendClientCommand(playerObj, "shop", "getOrSetWallet", {playerID=playerModData.wallet_UUID, steamID=playerObj:getSteamID(), playerUsername=playerObj:getUsername()})
    end

    return playerModData.wallet_UUID
end

local function safelyRemoveMoney(moneyItem)
    local worldItem = moneyItem:getWorldItem()
    if worldItem then
        ---@type IsoGridSquare
        local sq = worldItem:getSquare()
        if sq then
            sq:transmitRemoveItemFromSquare(worldItem)
            sq:removeWorldObject(worldItem)
            moneyItem:setWorldItem(nil)
        end
    end

    local container = moneyItem:getContainer()
    container:Remove(moneyItem)
    container:setDrawDirty(true)
end


local valuedMoney = {}
---@param item InventoryItem
function generateMoneyValue(item, value, force)
    if item ~= nil and _internal.isMoneyType(item:getFullType()) and (not valuedMoney[item] or force) then
        if (not item:getModData().value) or force then

            local min = (SandboxVars.ShopsAndTraders.MoneySpawnMin or 1.5)*100
            local max = (SandboxVars.ShopsAndTraders.MoneySpawnMax or 25)*100

            value = value or ((ZombRand(min,max)/100)*100)/100
            item:getModData().value = value
            item:setName(_internal.numToCurrency(value))
        end
        item:setActualWeight(SandboxVars.ShopsAndTraders.MoneyWeight*item:getModData().value)
    end
    valuedMoney[item] = true
end


---@param playerObj IsoPlayer|IsoGameCharacter|IsoMovingObject|IsoObject
local function onPlayerDeath(playerObj)
    if not SandboxVars.ShopsAndTraders.PlayerWallets then return end
    local playerModData = playerObj:getModData()
    if not playerModData then print("WARN: Player without modData.") return end
    if not playerModData.wallet_UUID then print("- No Player wallet_UUID.") return end

    local walletBalance = getWalletBalance(playerObj)
    local transferAmount = math.floor((walletBalance*(SandboxVars.ShopsAndTraders.PercentageDropOnDeath/100) * 100) / 100)

    if transferAmount > 0 then
        local moneyTypes = _internal.getMoneyTypes()
        local type = moneyTypes[ZombRand(#moneyTypes)+1]
        local money = InventoryItemFactory.CreateItem(type)
        if money then
            sendClientCommand("shop", "transferFunds", {giver=playerModData.wallet_UUID, give=transferAmount, receiver=nil, receive=nil})
            generateMoneyValue(money, transferAmount)
            playerObj:getInventory():AddItem(money)
        else print("ERROR: Split/Withdraw Wallet: No money object created. \<"..type.."\>") end
    end
    sendClientCommand("shop", "scrubWallet", {playerID=playerModData.wallet_UUID})
end
Events.OnPlayerDeath.Add(onPlayerDeath)


---@class ISSliderBox : ISTextBox
ISSliderBox = ISTextBox:derive("ISSliderBox")

function ISSliderBox:onValueChange(val)
    local title = "IGUI_SPLIT"
    if not self.item then title = "IGUI_WITHDRAW" end
    self.text = getText(title)..": ".._internal.numToCurrency(val)
end

function ISSliderBox:initialise()
    ISTextBox.initialise(self)

    local x,y,w,margin = 10,10,self.width-30,5
    local maxValue = 0
    if self.item then maxValue = self.item:getModData().value-0.01
    else maxValue = getWalletBalance(self.playerObj) end

    local halfMax = _internal.floorCurrency(maxValue/2)
    self.slider = ISSliderPanel:new(self.entry.x, self.entry.y, w-margin, 20, self, ISSliderBox.onValueChange)
    self.slider:setValues( 0.01, maxValue, 0.01, 0.5, true)
    self.slider:setCurrentValue(halfMax)
    self.slider:initialise()
    self.slider:instantiate()
    self:addChild(self.slider)
    self.slider:setVisible(true)
    self.entry:setVisible(false)
end



function ISSliderBox:new(x, y, width, height, text, onclick, playerObj, item)
    if ISSliderBox.instance and ISSliderBox.instance:isVisible() then
        ISSliderBox.instance:setVisible(false)
        ISSliderBox.instance:removeFromUIManager()
    end
    local o = {}
    o = ISTextBox:new(x, y, width, height, text, "", o, onclick, nil, playerObj, item)
    setmetatable(o, self)
    self.__index = self
    o.item = item
    o.playerObj = playerObj
    ISSliderBox.instance = o
    return o
end


function ISSliderBox:onClick(button, playerObj, item)
    if button.internal == "OK" then
        local transferValue = button.parent.slider:getCurrentValue()
        local moneyTypes = _internal.getMoneyTypes()
        local type = moneyTypes[ZombRand(#moneyTypes)+1]
        local money = InventoryItemFactory.CreateItem(type)

        if money then
            generateMoneyValue(money, transferValue)
            playerObj:getInventory():AddItem(money)

            if item and _internal.isMoneyType(item:getFullType()) and item:getModData() and item:getModData().value > 0 then
                local newValue = item:getModData().value-transferValue
                generateMoneyValue(item, newValue, true)
            end

            if not item then
                local playerModData = playerObj:getModData()
                sendClientCommand("shop", "transferFunds", {giver=playerModData.wallet_UUID, give=transferValue, receiver=nil, receive=nil})
            end

        else print("ERROR: Split/Withdraw Wallet: No money object created. \<"..type.."\>") end
    end
end


---@param item InventoryItem|Literature
local function onSplitStack(item, player, x, y)
    x = x or getMouseX()
    y = y or getMouseY()
    local slider = ISSliderBox:new(x, y, 280, 100, "", ISSliderBox.onClick, player, item)
    slider:initialise()
    slider:addToUIManager()
end

local _refreshContainer = ISInventoryPane.refreshContainer
function ISInventoryPane:refreshContainer()
    _refreshContainer(self)
    for _, entry in ipairs(self.itemslist) do
        for _,item in pairs(entry.items) do
            if item ~= nil and _internal.isMoneyType(item:getFullType()) then generateMoneyValue(item) end
        end
    end
end

--[[
local _refreshContainer = ISInventoryPane.refreshContainer
function ISInventoryPane:refreshContainer()
    _refreshContainer(self)

    local scrubThese = {}

    for _, entry in ipairs(self.itemslist) do
        for _,item in pairs(entry.items) do
            if item ~= nil and _moneyTypes[item:getType()] then
                print(" item:getType():"..item:getType())
                generateMoneyValue(item)
                scrubThese[item:getName()] = true
                local itemName = item:getScriptItem():getDisplayName()
                if self.itemindex[itemName] == nil then self.itemindex[itemName] = {items = {}, count = 0} end
                local ind = self.itemindex[itemName]
                ind.count = ind.count + 1
                ind.items[ind.count] = item
            end
        end
    end

    for k,entry in pairs(self.itemindex) do
        if entry ~= nil and scrubThese[k] then
            print("  -- k:"..entry.name)
            self.itemindex[k] = nil
        end
    end

    for k, v in pairs(self.itemindex) do
        if v ~= nil then
            table.insert(self.itemslist, v);
            local count = 1;
            local weight = 0;
            for k2, v2 in ipairs(v.items) do
                if v2 == nil then table.remove(v.items, k2);
                else
                    count = count + 1;
                    weight = weight + v2:getUnequippedWeight();
                end
            end
            v.count = count;
            v.invPanel = self;
            v.name = k -- v.items[1]:getName();
            v.cat = v.items[1]:getDisplayCategory() or v.items[1]:getCategory();
            v.weight = weight;
            if self.collapsed[v.name] == nil then self.collapsed[v.name] = true; end
        end
    end

    for k,entry in pairs(self.itemslist) do
        if entry ~= nil and scrubThese[entry.name] then
            print("  -- entry.name:"..entry.name)
            self.itemslist[k] = nil
        end
    end
end
--]]

local ISInventoryPane_onMouseUp = ISInventoryPane.onMouseUp
function ISInventoryPane:onMouseUp(x, y)
    if not self:getIsVisible() then return end

    local draggingOld = ISMouseDrag.dragging
    local draggingFocusOld = ISMouseDrag.draggingFocus
    local selectedOld = self.selected
    local busy = false
    self.previousMouseUp = self.mouseOverOption

    local noSpecialKeys = (not isShiftKeyDown() and not isCtrlKeyDown())

    if (noSpecialKeys and x >= self.column2 and  x == self.downX and y == self.downY) and self.mouseOverOption ~= 0 and self.items[self.mouseOverOption] ~= nil then
        busy = true
    end

    local result = ISInventoryPane_onMouseUp(self, x, y)
    if not result then
        --if getDebug() then print("ISInventoryPane_onMouseUp: no result") end
        return
    end
    if busy or (not noSpecialKeys) then
        --if getDebug() then print("ISInventoryPane_onMouseUp: busy|(not noSpecialKeys)") end
        return
    end
    self.selected = selectedOld

    if (draggingOld ~= nil) and (draggingFocusOld == self) and (draggingFocusOld ~= nil) then
        if self.player ~= 0 then return end
        local playerObj = getSpecificPlayer(self.player)
        local moneyFound = {}

        local doWalk = true
        local dragging = ISInventoryPane.getActualItems(draggingOld)
        for i,v in ipairs(dragging) do
            if _internal.isMoneyType(v:getFullType()) then
                local transfer = v:getContainer() and not self.inventory:isInside(v)
                if v:isFavorite() and not self.inventory:isInCharacterInventory(playerObj) then transfer = false end
                if transfer then
                    if doWalk then if not luautils.walkToContainer(self.inventory, self.player) then break end doWalk = false end
                    table.insert(moneyFound, v)
                end
            end
        end
        self.selected = {}
        getPlayerLoot(self.player).inventoryPane.selected = {}
        getPlayerInventory(self.player).inventoryPane.selected = {}

        local pushTo = self.items[self.mouseOverOption]
        if not pushTo then return end

        local pushToActual
        if instanceof(pushTo, "InventoryItem") then pushToActual = pushTo else pushToActual = pushTo.items[1] end

        for _,money in pairs(moneyFound) do if money==pushToActual then return end end

        if pushToActual and _internal.isMoneyType(pushToActual:getFullType()) then
            local ptValue = pushToActual:getModData().value
            local consolidatedValue = 0
            for _,money in pairs(moneyFound) do
                local valueFound = (money:getModData().value or 0)
                consolidatedValue = consolidatedValue+valueFound
                safelyRemoveMoney(money)
            end
            generateMoneyValue(pushToActual, ptValue+consolidatedValue, true)
        end
    end
end


local function addContext(playerID, context, items)
    local playerObj = getSpecificPlayer(playerID)
    for _, v in ipairs(items) do
        local item = v
        if not instanceof(v, "InventoryItem") then item = v.items[1] end
        if _internal.isMoneyType(item:getFullType()) then
            local itemValue = item:getModData().value
            if itemValue and itemValue>1 then context:addOption(getText("IGUI_SPLIT"), item, onSplitStack, playerObj) end
        end
    end
end
Events.OnPreFillInventoryObjectContextMenu.Add(addContext)


function ISCharacterScreen:withdraw(button)
    if not SandboxVars.ShopsAndTraders.PlayerWallets then return end
    if SandboxVars.ShopsAndTraders.CanWithdraw then
        local walletBalance = getWalletBalance(self.char)
        if walletBalance <= 0 then return end
        onSplitStack(nil, self.char, ISCharacterInfoWindow.instance.x+button.x+button.width+10, ISCharacterInfoWindow.instance.y+button.y+button.height+15)
    end
end


function ISCharacterScreen:moneyMouseOut(x, y)
    self.withdraw:setTitle(string.lower(getText("IGUI_WALLET")))
end
function ISCharacterScreen:moneyMouseOver(x, y)
    if not self.withdraw.mouseOver or not self.withdraw.onmouseover then return end

    if self.vscroll then self.vscroll.scrolling = false end
    local money = false
    if ISMouseDrag.dragging then
        for i,v in ipairs(ISMouseDrag.dragging) do
            if instanceof(v, "InventoryItem") and _internal.isMoneyType(v:getFullType()) then money = true break
            else if v.invPanel.collapsed[v.name] then for i2,v2 in ipairs(v.items) do if _internal.isMoneyType(v2:getFullType()) then money = true break end end end
            end
        end
        if money then self.withdraw:setTitle(string.lower(getText("IGUI_DEPOSIT"))) end
    else
        if SandboxVars.ShopsAndTraders.CanWithdraw then self.withdraw:setTitle(string.lower(getText("IGUI_WITHDRAW"))) end
    end
end


---@param moneyItem InventoryItem|IsoObject
function ISCharacterScreen:depositMoney(moneyItem)
    if not SandboxVars.ShopsAndTraders.PlayerWallets then return end
    local playerModData = self.char:getModData()
    local value = moneyItem:getModData().value
    sendClientCommand("shop", "transferFunds", {giver=nil, give=value, receiver=playerModData.wallet_UUID, receive=nil})
    safelyRemoveMoney(moneyItem)
    self.withdraw:setTitle(string.lower(getText("IGUI_WITHDRAW")))
end


function ISCharacterScreen:depositOnMouseUp(x, y)
    if not SandboxVars.ShopsAndTraders.PlayerWallets then return end
    if self.vscroll then self.vscroll.scrolling = false end
    local counta = 1
    if ISMouseDrag.dragging then
        for i,v in ipairs(ISMouseDrag.dragging) do
            counta = 1
            if instanceof(v, "InventoryItem") and _internal.isMoneyType(v:getFullType()) then self.parent:depositMoney(v)
            else
                if v.invPanel.collapsed[v.name] then
                    counta = 1
                    for i2,v2 in ipairs(v.items) do
                        if counta > 1 and _internal.isMoneyType(v2:getFullType()) then self.parent:depositMoney(v2) end
                        counta = counta + 1
                    end
                end
            end
        end
        self:setTitle(string.lower(getText("IGUI_WALLET")))
    else
        ISButton.onMouseUp(self, x, y)
    end
end


local ISCharacterScreen_initialise = ISCharacterScreen.initialise
function ISCharacterScreen:initialise()
    ISCharacterScreen_initialise(self)
    if SandboxVars.ShopsAndTraders.PlayerWallets then
        self.withdraw = ISButton:new(0, 0, 55, 20, string.lower(getText("IGUI_WALLET")), self, ISCharacterScreen.withdraw)
        self.withdraw.font = UIFont.NewSmall
        self.withdraw.textColor = { r = 1, g = 1, b = 1, a = 0.7 }
        self.withdraw.borderColor = { r = 1, g = 1, b = 1, a = 0.7 }
        self.withdraw.onMouseUp = self.depositOnMouseUp
        self.withdraw:setOnMouseOverFunction(self.moneyMouseOver)
        self.withdraw:setOnMouseOutFunction(self.moneyMouseOut)
        self.withdraw:initialise()
        self.withdraw:instantiate()
        self:addChild(self.withdraw)
    end
end


local playersChecked = {}
local function applyWallet(player)
    if not playersChecked[player] then
        getOrSetWalletID(player)
        playersChecked[player] = true
    end
end
local function applyWalletCreate(_,player) applyWallet(player) end


local ISCharacterScreen_render = ISCharacterScreen.render
function ISCharacterScreen:render()
    ISCharacterScreen_render(self)
    if SandboxVars.ShopsAndTraders.PlayerWallets then
        self.withdraw:setX(self.avatarX+self.avatarWidth+25)
        self.withdraw:setY(self.literatureButton.y+52)
        self.withdraw:setWidthToTitle(55)
        applyWallet(self.char)
        local walletBalance = getWalletBalance(self.char)
        self.withdraw.enable = (walletBalance > 0)
        local walletBalanceLine = getText("IGUI_WALLETBALANCE")..": ".._internal.numToCurrency(walletBalance)
        self:drawText(walletBalanceLine, self.withdraw.x, self.literatureButton.y+32, 1, 1, 1, 1, UIFont.Small)
    end
end
Events.OnCreatePlayer.Add(applyWalletCreate)
Events.OnPlayerMove.Add(applyWallet)