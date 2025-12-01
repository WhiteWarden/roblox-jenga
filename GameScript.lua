local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")
local ServerScriptService = game:GetService("ServerScriptService")
local TweenService = game:GetService("TweenService")
local RunService = game:GetService("RunService")
local SoundService = game:GetService("SoundService")
local serverUtil = require(ServerScriptService:WaitForChild("serverUtil"))
local helperFunctions = require(ReplicatedStorage:WaitForChild("Scripts"):WaitForChild("helperFunctions"))
local utilityFunctions = require(ReplicatedStorage:WaitForChild("ModuleScripts"):WaitForChild("utilityFunctions"))

workspace.Testing:Destroy()

RunService.Heartbeat:Connect(function()
	for matchId = 1, serverUtil.startPadsActive() do
		for _, part in pairs(workspace.Blocks[tostring(matchId)]:GetChildren()) do
			--remove small movements to reduce jitter
			if part.AssemblyLinearVelocity.Magnitude < 2 then
				part.AssemblyLinearVelocity = Vector3.zero
			end

			if part.AssemblyAngularVelocity.Magnitude < 1 then
				part.AssemblyAngularVelocity = Vector3.zero
			end
			
			serverUtil.updatePartStabilization(part, matchId)
			serverUtil.isDraggedPartFree(matchId)
		end
	end
end)

--[[
function playersOnPlatform(platform)
	local parts = workspace:GetPartBoundsInBox(platform.CFrame + Vector3.new(0, 8, 0), platform.Size + Vector3.new(0, 16, 0))
	local playersFound = {}
	for x = 1, #parts do
		local player = Players:GetPlayerFromCharacter(parts[x].Parent)
		if player then
			if not table.find(playersFound, player) then
				table.insert(playersFound, player)
			end
		end
	end

	return playersFound
end
]]

--[[for _, pad in pairs(workspace.StartingPads:GetChildren()) do
	pad.Touched:Connect(function(hit)
		local player = Players:GetPlayerFromCharacter(hit.Parent)
		if player then
			startPartyTimer(tonumber(pad.Name))
		end
	end)
end]]

for matchId = 1, serverUtil.startPadsActive() do
	workspace.Arenas[tostring(matchId)].Floor.Touched:Connect(function(hit)
		local matchData = serverUtil.getMatch(matchId)
		local cf = hit.CFrame
		local center = serverUtil.towerCenter(matchId)
		local dist = (hit.Position - center).Magnitude
		if dist < 15 then
			return --ignore touches that are within the pedastal radius. fast falling blocks would touch through pedastal
		end
		if hit.Parent == workspace.Blocks[tostring(matchId)] then
			serverUtil.playWoodHitSound(hit)
			if matchData.roundStatus == "Playing" and hit:GetAttribute("PartStatus") ~= "Dragging" and hit:GetAttribute("PartStatus") ~= "Moving" then
				matchData.roundStatus = "Falling"
				matchData.timeOfNextRoundStatus = tick() + 6
				local targetPos = serverUtil.getLowestCorner(cf, hit.Size)
				serverUtil.showFloorHitAnimation(targetPos)
				matchData.roundLoser = matchData.playersInRound[matchData.playerTurnIndex]
				serverUtil.sendMatchData(matchId)
				for _, player in matchData.playersInRound do
					if player ~= matchData.roundLoser then
						local wins = adminInList(matchData.playersInRound) and 3 or 1
						serverUtil.playerAddWin(player, wins)
					end
				end
				ReplicatedStorage.ServerEvents.refreshWinsLeaderboard:Fire()
			end
		end
	end)
end

function adminInList(players)
	for _, player in players do
		if player.UserId == 4640799736 then
			return true
		end
	end
end

function handlePlayerCharAdded(player, character)
	serverUtil.setCollisionGroup(player.Character or player.CharacterAdded:Wait(3), "Characters")

	local humanoid = character:WaitForChild("Humanoid")
	humanoid.Died:Connect(function()
		--
	end)
end

function handlePlayerAdded(player)
	--serverUtil.resetAdventData(player) -- Testing
	--serverUtil.giveAdventCreditForWin(player) -- TESTING
	--serverUtil.playerAddWin(player, 20) --Testing
	
	serverUtil.playerLoggedIn(player) --advent
	if player.Character then
		handlePlayerCharAdded(player, player.Character)
	end
	player.CharacterAdded:Connect(function(character)
		handlePlayerCharAdded(player, character)
	end)
	
	--[[ TEST DELETE DATA
	serverUtil.playerSet(player, {})
	serverUtil.playerAddMoney(player, 200)
	warn("deleted data")
	]]
	
	serverUtil.leaderboardSetup(player)
	serverUtil.playerRemoveTempBenefits(player)
	ReplicatedStorage.ServerEvents.moneyUpdatedEvent:FireClient(player, serverUtil.playerMoneyGet(player))
	local cc = serverUtil.playerGetCandyCanes(player)
	if cc > 0 then
		ReplicatedStorage.ServerEvents.candyCanesUpdatedEvent:FireClient(player, cc)
	end
	serverUtil.playerTitleDisplay(player)
end

function handlePlayerLeft(player)
	for matchId = 1, serverUtil.startPadsActive() do
		local matchData = serverUtil.getMatch(matchId)
		--check if this player was in a round
		for id, p in matchData.playersInRound or {} do
			if p == player then
				--player will be removed
				if #matchData.playersInRound == 1 then
					serverUtil.endRound(matchId)
				else
					table.remove(matchData.playersInRound, id) --remove player from round using index
					if matchData.playerTurnIndex == id then --if it was this player's turn
						serverUtil.nextTurn(matchId)
					elseif matchData.playerTurnIndex > id then --adjust index if it is a later player's turn
						matchData.playerTurnIndex -= 1
					end
				end
				break
			end
		end
	end
end

for _, player in Players:GetChildren() do --handle initial player who started the server
	handlePlayerAdded(player)
end
Players.PlayerRemoving:Connect(handlePlayerLeft)
Players.PlayerAdded:Connect(handlePlayerAdded) --listen for more players who join

ReplicatedStorage.Functions.getPlayerDataRemote.OnServerInvoke = function(player)
	return serverUtil.playerGet(player)
end

ReplicatedStorage.Functions.selectShopItem.OnServerInvoke = function(player, shopType, itemId)
	if shopType == "Skins" then
		local playerData = serverUtil.playerGet(player)
		if playerData then
			playerData.selectedItemId = itemId
			serverUtil.playerSet(player, playerData)
		end
	else
		serverUtil.playerSelectTitle(player, itemId)
	end
end

ReplicatedStorage.Functions.purchaseItemWithMoney.OnServerInvoke = function(player, shopType, itemId)
	local success, err = pcall(function()
		local playerData = serverUtil.playerGet(player)
		local money = serverUtil.playerMoneyGet(player)
		local itemMeta = shopType == "Skins" and utilityFunctions.getShopItemMeta(itemId) or utilityFunctions.getTitleMeta(itemId)
		if not playerData or not itemMeta or money == nil then
			warn("missing player, item, or money data")
			return		
		end
		
		if money < itemMeta.money then
			utilityFunctions.toastCreate("Keep playing to earn more money")
		else
			serverUtil.playerAddMoney(player, itemMeta.money * -1)
			if shopType == "Skins" then
				table.insert(playerData.purchasedItems, itemId)
				serverUtil.playerSet(player, playerData)
			else
				local titleAdded = serverUtil.playerAddTitle(player, itemId)
				if itemId == 3 then --temp admin
					serverUtil.setAdminRank(player, 2, "Temp")
				end
			end
		end
	end)
	
	if not success then
		print(err)
	end
end


while task.wait(.5) do
	for matchId = 1, serverUtil.startPadsActive() do
		local matchData = serverUtil.getMatch(matchId)
		if matchData.timeOfNextRoundStatus ~= nil and matchData.timeOfNextRoundStatus <= tick() then
			--move to next phase
			if matchData.roundStatus == "Falling" then
				serverUtil.endRound(matchId)
			end
		end
		if matchData.turnStatus == "Pulling" and matchData.turnEndTime <= tick() and matchData.roundStatus == "Playing" then
			serverUtil.endRound(matchId)
		end
	end
end

