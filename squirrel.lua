local ReplicatedStorage = game:GetService("ReplicatedStorage")
local StarterPlayer = game:GetService("StarterPlayer")
local Players = game:GetService("Players")
local StarterGui = game:GetService("StarterGui")
local Debris = game:GetService("Debris")
local TweenService = game:GetService("TweenService")
local SoundService = game:GetService("SoundService")
local GenerationService = game:GetService("GenerationService")
local SocialService = game:GetService("SocialService")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local ContextActionService = game:GetService("ContextActionService")
local CollectionService = game:GetService("CollectionService")
local MarketplaceService = game:GetService("MarketplaceService")
local helperFunctions = require(ReplicatedStorage:WaitForChild("Scripts"):WaitForChild("helperFunctions"))

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")
local speedBoostFrame = playerGui:WaitForChild("ScreenGui"):WaitForChild("SpeedBoostFrame")
local clientUtil = require(player:WaitForChild("PlayerScripts"):WaitForChild("clientUtil"))
--game.StarterGui:SetCoreGuiEnabled(Enum.CoreGuiType.PlayerList, false) --hide leaderstast board
--game.StarterGui:SetCoreGuiEnabled(Enum.CoreGuiType.Chat, false) --hide chat by default
local startingSpeed = 40 --40 default is around lobby walking speed. 200 is good for testing with
local speed = 0
local acceleration = 0
local char --= player.Character or player.CharacterAdded:Wait()
local hrp --= char:WaitForChild("HumanoidRootPart")
local humanoid --= char:WaitForChild("Humanoid")
local lane = 2
local previousLane = lane
local changingLanes = nil --"Right" or "Left"
local laneWidth = 8
local centerLaneX = 0 --x position of the center lane to match the prebuilt path
local laneChangeStartedCFrame
local nextObstacleAtZ = 50
local lastPathEndsAtZ = 0
local lastObstacleAdded = "" --used to chain certain obstacles together
local playerVerticalStatus = "Running" --Running, Ascending, Falling, Gliding, Sliding
local camera = workspace.CurrentCamera
player.CameraMinZoomDistance = 5 --prevent player from starting run in FPV
local cameraConnection = nil
local anims = {["Slide"] = "rbxassetid://105216966680706", 
	["Fly"] = "rbxassetid://128132967829000",
	["Jump"] = "rbxassetid://132851840983889",
	["Run"] = "rbxassetid://99989919204982",
	["FallOver"] = "rbxassetid://128885242471410"
}
--[[animation resources: https://www.youtube.com/watch?v=aen_BdMeymo
https://www.tiktok.com/@mlb/video/7541572677237067039
https://create.roblox.com/docs/animation/using#catalog-animations ]]
local animTracks = {}  -- preloaded cache: { [animId] = track }
local stamina = 0
local maxStamina = 100 --can be upgraded
local inAir = false
local onRamp = false
local crashed = false --prevents movement after crashing
local lastHrpHeights = {} --used to detect if player is ascending or falling
local lastHrpPosition = Vector3.zero --for collision detection
local tutorialMode = false --used to show instructions during the tutorial
local requiredControl = nil --used to limit allowed controls during tutorial
local tutorialCheckpoints = {{z = 253, instruction = "👆 Jump", requiredControl = "Jump"},
	{z = 332, instruction = "HOLD Down to Slide 👇", requiredControl = "Down", holdTillZ=352},
	{z = 407, instruction = "👈 Go Left", requiredControl = "Left"},
	{z = 515, instruction = "Go Right 👉", requiredControl = "Right"},
	{z = 702, instruction = "HOLD Jump to Glide 💨", requiredControl = "Jump", holdTillZ=765},
	{z = 832, instruction = "Done", requiredControl = nil},
}
local tutorialCheckpoint = 1
local windSound = SoundService.wind_loop
local jumpBeginHeight = 0
--local maxComfortableSpeed = 999
local runStartTime = 0
local materialChangedTime = tick()
local activeInputs = {} --track all active inputs
local inputQueue = {} --each entry should have {action = "", begin: boolean, z} actions are Up, Down, Left, Right
local inputActionLength = {["Up"] = 30, ["Down"] = 10, ["Left"] = 40, ["Right"] = 40} --how many studs it lasts. For example, I press jump half way up a 40-stud ramp, it can wait and jump at the end.
local lastSongPlayed = 1
local fastFalling = false --makes you fall faster while holding Down
local leavesCollected = 0 --task counter
local slidUnderTrees = 0 --task counter
local playerScripts = player:WaitForChild("PlayerScripts")
local score = 0
local thumbstickDirection = nil
local biome = "Forest"
local lastBiome = ""
local addingBiomes = false
local raceMetadata = nil
local gameMode = "Endless" --Endless, Race
local coins --player's coins which can be fetched from the server, updated with events, or temporarily set for quick response
local waitForReviveDecisionStartedTime = nil
local revivePurchasePromptTime = nil
local revivedTime = nil
local reviveInvincibilityDuration = 3
local crashedObjectName = "" --set right before calling crash()
local revivesUsed = 0 --used to limit revives per run
local enforcingHeldControlForTutorial = false
local highScore = ReplicatedStorage.Functions.getHighscore:InvokeServer()
local speedBoostsUsed = 0
--local playerModule = require(playerScripts:WaitForChild("PlayerModule"))

function beginRun(restarting: boolean)
	crashed = false --required before game pause
	if not clientUtil.getGamePaused() then
		togglePause(false) --anchors player
	else
		warn("beginRun with pause")
	end
	
	clientUtil.setInLobby(false)
	local direction = CFrame.Angles(0, math.rad(180), 0)
	hrp:PivotTo(CFrame.new(Vector3.new(centerLaneX, 5, restarting and 15 or 0)) * direction)
	hrp.LinearVelocityZ.Enabled = true --gameMode ~= "Treadmill"
	hrp.AlignOrientation.Enabled = true
	hrp.AlignPositionX.Enabled = true
	inputQueue = {}
	
	--keep trying until server acknowledges start of new round
	clientUtil.setPlayerData(nil)
	while not clientUtil.PlayerData() do
		local newData = ReplicatedStorage.Functions.beginRun:InvokeServer() --get immediate playerData
		if newData then
			setPlayerData(newData)
		end
		task.wait(.1)
	end
	--maxComfortableSpeed = calcMaxComfortableSpeed()
	if clientUtil.PlayerData().highscore then
		playerGui:WaitForChild("ScreenGui"):WaitForChild("PausedFrame"):WaitForChild("HighScoreLabel").Text = "High Score " .. helperFunctions.formatNumber(clientUtil.PlayerData().highscore)
	end
	
	--cleanup previous run
	workspace.PathParts:ClearAllChildren()
	workspace.Scenery:ClearAllChildren()
	
	local speedBoost = table.find((clientUtil.PlayerData() or {}).purchasedItems, 4) and 20 or 0  --higher starting speed
	setSpeed(startingSpeed + speedBoost)
	biome = "Forest"
	lane = 2
	score = 0
	speedBoostsUsed = 0
	inAir = false
	changingLanes = nil
	if table.find((clientUtil.PlayerData() or {}).purchasedItems or {}, 10) then
		maxStamina = 120 --More stamina capacity
	end
	stamina = maxStamina
	fastFalling = false
	humanoid.WalkSpeed = 0
	--humanoid.JumpPower = 0.001 --jumps use custom physics instead
	humanoid.JumpHeight = 0.001 --disables mobile jump button without hiding it
	humanoid:SetStateEnabled(Enum.HumanoidStateType.FallingDown, false)
	humanoid:SetStateEnabled(Enum.HumanoidStateType.Ragdoll, false)
	humanoid:SetStateEnabled(Enum.HumanoidStateType.Climbing, false)
	humanoid:SetStateEnabled(Enum.HumanoidStateType.Swimming, false)
	humanoid.AutoRotate = false
	char:WaitForChild("Animate").Enabled = false --disable default animations
	camera.CameraType = Enum.CameraType.Scriptable
	toggleCameraConnection(true)
	nextObstacleAtZ = 250 --determines when the first obstacle will appear
	lastPathEndsAtZ = 300 --determines when the next path part will appear
	--[[if gameMode == "Treadmill" then
		lastPathEndsAtZ = 0
	end]]
	runStartTime = (raceMetadata or {}).raceStartTime or tick()
	leavesCollected = 0
	alignPlayerToLane()
	
	--show countdown to race start
	if raceMetadata and raceMetadata.raceStartTime then
		local frame = playerGui:WaitForChild("ScreenGui"):WaitForChild("RaceStartCountdown")
		local textLabel = frame:WaitForChild("TextLabel")
		local previousSeconds = 4
		while workspace:GetServerTimeNow() < raceMetadata.raceStartTime do
			local secondsLeft = math.ceil(raceMetadata.raceStartTime - workspace:GetServerTimeNow())
			if secondsLeft >= 1 and secondsLeft <= 3 then
				if secondsLeft < previousSeconds then
					SoundService.CountdownBeep:Play()
					previousSeconds = secondsLeft
				end
				textLabel.Text = secondsLeft >= 1 and tostring(secondsLeft) or ""
				frame.Visible = true
			end
			task.wait()
		end
		textLabel.Text = "GO!"
		SoundService.Spin_Start:Play()
		task.delay(.5, function()
			frame.Visible = false
		end)
	end
	
	togglePause(false)
	setPlayerVerticalStatus("Running")
	
	--start tutorial if first time playing
	if clientUtil.PlayerData().completedTutorial or raceMetadata then
		toggleRunUIs()
	else
		beginTutorial()
	end
end

function maxSpeedBoosts()
	return math.floor(highScore / 25000) - 1
end

function setSpeedBoostFrameVisibility()
	local maxScore = maxSpeedBoosts() * 25000 --hide once your score is too high
	speedBoostFrame.Visible = speedBoostsUsed < maxSpeedBoosts() and score < maxScore and not clientUtil.getInLobby() and not raceMetadata and not tutorialMode and not crashed
end

function toggleRunUIs() --should be called after setInLobby
	if not clientUtil.PlayerData() or not clientUtil.PlayerData().completedTutorial then return end
	playerGui:WaitForChild("ScreenGui"):WaitForChild("Stamina2").Visible = not clientUtil.getInLobby()
	local menuFrame = playerGui:WaitForChild("MenuButtonsGui"):WaitForChild("TopBarFrame"):WaitForChild("MenuFrame")
	menuFrame:WaitForChild("ShopButtonFrame").Visible = clientUtil.getInLobby() --only in lobby
	--menuFrame:WaitForChild("RacingFrame").Visible = clientUtil.getInLobby() --only in lobby
	playerGui:WaitForChild("ScreenGui"):WaitForChild("PlayAndPartyFrame").Visible = clientUtil.getInLobby() --only in lobby
	menuFrame:WaitForChild("PauseButton").Visible = not clientUtil.getInLobby() and not raceMetadata
	menuFrame:WaitForChild("RestartButton").Visible = not clientUtil.getInLobby()
	playerGui:WaitForChild("ScreenGui"):WaitForChild("ScoreFrame").Visible = not clientUtil.getInLobby()
	setSpeedBoostFrameVisibility()
end

function endRun(endReason: string, startAnotherRun: boolean)
	crashed = true
	inputQueue = {}
	clientUtil.toggleVignette(nil)
	cancelSoundEffects()
	--setPlayerVerticalStatus("Running")
	score = math.round(score)
	ReplicatedStorage.Events.playerCrashed:FireServer(speed, score, endReason) --let server know run ended
	highScore = math.max(highScore, score)
	playerGui:WaitForChild("ScreenGui"):WaitForChild("ReviveFrame").Visible = false --hide revive frame if player reset before making a selection
	waitForReviveDecisionStartedTime = nil
	revivePurchasePromptTime = nil
	revivedTime = nil
	revivesUsed = 0
	enforcingHeldControlForTutorial = false
	
	if startAnotherRun then
		closeEyes(false) --wait for eyes to close
		task.wait(1) --dramatic pause between rounds
		task.spawn(function() --don't block eyes from opening if tutorial is restarting
			beginRun(true)
		end)

		task.wait(.2) --slight delay for path spawn
		openEyes()
	else
		returnToLobby()
	end
end

function returnToLobby()
	clientUtil.setInLobby(true)
	while not hrp or not humanoid do
		task.wait()
	end
	local spawnCFrame = workspace.SpawnLocation.CFrame
	hrp:PivotTo(CFrame.new(spawnCFrame.Position + Vector3.new(0, 4, 0)) * spawnCFrame.Rotation)
	hrp.LinearVelocityZ.Enabled = false
	hrp.LinearVelocityY.Enabled = false
	hrp.AlignOrientation.Enabled = false
	hrp.AlignPositionX.Enabled = false
	hrp.AlignPositionZ.Enabled = false
	humanoid.WalkSpeed = 32
	--humanoid.JumpPower = 50
	humanoid.JumpHeight = 18
	humanoid:SetStateEnabled(Enum.HumanoidStateType.FallingDown, true)
	humanoid:SetStateEnabled(Enum.HumanoidStateType.Ragdoll, true)
	humanoid:SetStateEnabled(Enum.HumanoidStateType.Climbing, true)
	humanoid:SetStateEnabled(Enum.HumanoidStateType.Swimming, true)
	humanoid.AutoRotate = true
	char:WaitForChild("Animate").Enabled = true
	toggleCameraConnection(false)
	camera.CameraType = Enum.CameraType.Custom
	camera.CameraSubject = humanoid
	crashed = false
	tutorialMode = false
	if clientUtil.getGamePaused() then
		togglePause(true)
	end
	toggleRunUIs()
end

--[[function calcMaxComfortableSpeed()
	--check top speeds to determine when to ease off speed ramping
	if playerData and playerData.runTopSpeeds and #playerData.runTopSpeeds > 1 then
		--sort to get top speeds
		table.sort(playerData.runTopSpeeds, function(a, b)
			return a > b --descending
		end)
		
		local speedSum = 0
		local speedsToAdd = math.min(6, #playerData.runTopSpeeds) --include up to this many runs
		for x=  1, speedsToAdd do
			speedSum += playerData.runTopSpeeds[x]
		end
		
		return speedSum / speedsToAdd --average
	else 
		return 999
	end
end]]

--[[function addPath()
	if not hrp then warn("no hrp in addPath") return end
	
	local o = ReplicatedStorage.Runways[biome]:Clone()
	o.Parent = workspace.PathParts
	local part = o:IsA("Model") and o.PrimaryPart or o
	local x = centerLaneX
	local y = 1 - part.Size.Y / 2
	local z = lastPathEndsAtZ + part.Size.Z / 2
	o:PivotTo(CFrame.new(Vector3.new(x, y, z)))
	lastPathEndsAtZ = part.Position.Z + part.Size.Z / 2
	local pathBeginZ = part.Position.Z - part.Size.Z / 2
	local pathEndZ = part.Position.Z + part.Size.Z / 2

	--update decor for each biome
	if biome == "Forest" then
		for _, tree in o:GetDescendants() do
			if tree:IsA("Model") and tree.Name == "Tree" then
				if math.random(1, 7) == 1 then
					tree:Destroy()
				end
			end
		end
	elseif biome == "Water" and clientUtil.getSceneryEnabled() then
		for z = math.round(pathBeginZ), math.round(pathEndZ), 3 do
			local foliage = math.random(1, 8) == 1 and "Reed" or "Grass"
			local maxScale = foliage == "Grass" and 2.3 or 1.4
			local grass = ReplicatedStorage.Decor[foliage]:Clone()
			grass.Parent = workspace.Scenery
			local pos = helperFunctions.randomPointOnShoulderNearZ(z, 1, Vector3.one)
			local angle = CFrame.Angles(math.rad(math.random(-5, 5)), math.rad(math.random(0, 359)), math.rad(math.random(-5, 5)))
			grass:ScaleTo(math.random(100, maxScale * 100) / 100)
			grass:PivotTo(CFrame.new(pos) * angle)
		end
	elseif biome == "Desert" and clientUtil.getSceneryEnabled() then
		helperFunctions.addCactus(pathBeginZ, pathEndZ)
	end
	
	helperFunctions.addRocks(pathBeginZ, pathEndZ)
	
	--determine if new parts need to be added
	if not tutorialMode 
		and not hrp.Anchored --don't spawn while round is beginning
		and biome ~= "Desert" --desert obstacles are chained in advance
	then
		while nextObstacleAtZ < pathEndZ do
			if biome == "Forest" and ((nextObstacleAtZ < 2000 and math.random(1, 4) == 1)
				or (nextObstacleAtZ < 5000 and math.random(1, 12) == 1)
				or (nextObstacleAtZ > 5000 and math.random(1, 25) == 1))
			then
				nextObstacleAtZ = helperFunctions.addLeafBoost(centerLaneX, nextObstacleAtZ) --near beginning of run, you can get these instead of an obstacle
			else
				nextObstacleAtZ, lastObstacleAdded = helperFunctions.addObstacle(biome, nextObstacleAtZ, runStartTime, lastObstacleAdded)
			end
			
		end
	end
end]]

--[[function densityRating()
	--ramps from 0 to 1 over x seconds, then drops to 0 again
	local duration = tick() - runStartTime
	local distBetweenDrops = 30
	return math.fmod(duration / distBetweenDrops, 1)
end]]

function cleanupPastParts() --delete parts that are too far behind player
	if crashed or not hrp then return end
	for _, object in pairs(workspace.PathParts:GetChildren()) do
		local part = object:IsA("Model") and object.PrimaryPart or object  
		if part.Position.Z + part.Size.Z / 2 < hrp.Position.Z - 50 then
			object:Destroy()
		end
	end
	for _, object in pairs(workspace.Scenery:GetChildren()) do
		local part = object:IsA("Model") and object.PrimaryPart or object  
		if part.Position.Z + part.Size.Z / 2 < hrp.Position.Z - 50 then
			object:Destroy()
		end
	end
end

--[[function addFlowerPatch(startAtZ, length)
	if not sceneryEnabled then return end

	--amount of flowers should follow sine wave with gaps between
	local flowerChunckSize = 10 --flowers will be placed in this sized area
	local color = flowerColors[math.random(1, #flowerColors)]
	local maxFlowers = 10 -- max density at peak

	local nextFlowerPatchAtZ = startAtZ + math.random(10, 40) --start after first gap

	while true do
		local lengthOfPatch = math.random(5, 40) --number of patch chunks
		local coeficient = 2 * math.pi / lengthOfPatch --determines distance between peaks
		if nextFlowerPatchAtZ + lengthOfPatch > startAtZ + length then
			break --stop if next patch won't fit
		end
		
		for x = 0, lengthOfPatch do
			local flowers = math.sin(coeficient * x - math.pi / 2) * (maxFlowers / 2) + (maxFlowers / 2)
			for i = 1, math.round(flowers) do
				local flower = ReplicatedStorage.Decor.Flower:Clone()
				for _, petal in flower:GetChildren() do
					if petal.Name == "Petal" then
						petal.Color = Color3.fromHex(color)
					end
				end
				flower.Parent = biome ~= "Desert" and workspace.Scenery or nil --no flowers in desert, but I want rocks
				local pos = helperFunctions.randomPointOnShoulderNearZ(nextFlowerPatchAtZ + x * flowerChunckSize, flowerChunckSize, Vector3.one)
				local pos = pos + Vector3.new(0, math.random(-10, 10) / 20, 0) --up or down by .5
				local angle = CFrame.Angles(math.rad(math.random(-5, 5)), math.rad(math.random(0, 89)), math.rad(math.random(-5, 5)))
				flower:PivotTo(CFrame.new(pos) * angle)
			end
		end

		nextFlowerPatchAtZ += lengthOfPatch * flowerChunckSize + math.random(50, 200)
	end
end]]

function setSpeed(newAmount)
	local med = 160
	local fast = 250
	if speed == startingSpeed then
		clientUtil.setMusicSpeedLevel("Slow")
	elseif speed < med and newAmount >= med then
		clientUtil.setMusicSpeedLevel("Med")
	elseif speed < fast and newAmount >= fast then
		clientUtil.setMusicSpeedLevel("Fast")
	end
	speed = newAmount
	hrp.LinearVelocityZ.LineVelocity = speed
	hrp.AlignPositionX.Responsiveness = speed
	setSpeedBoostFrameVisibility()
end

--[[function addLeafBoost()
	local leaves = ReplicatedStorage.LeafPile:Clone()
	leaves.Parent = workspace.Scenery
	local offsetX = math.random(-1, 1) * laneWidth
	leaves:PivotTo(CFrame.new(Vector3.new(centerLaneX + offsetX, 3.55, nextObstacleAtZ)))
	
	local connection
	connection = leaves.Part.Touched:Connect(function(hit)
		if hit == hrp then
			connection:Disconnect()
			local speedBoost = 200 / speed -- +4 at 50 down to +1 at 200
			local bonus = helperFunctions.sumAtoAPlusB(speed, speedBoost) / 2
			setSpeed(speed + speedBoost)
			score += bonus
			
			SoundService.Boost:Play()
			leavesCollected += 1
			if leavesCollected == 10 then
				updateTaskProgress(7, leavesCollected)
			end
		end
	end)
	nextObstacleAtZ += 30
end]]

--[[function addRocks(startZ, endZ)
	for z = math.round(startZ), math.round(endZ) do
		if math.random(1, 40) == 1 then
			local r = ReplicatedStorage.Decor.Rock:Clone()
			r.Parent = workspace.Scenery
			r.Size = Vector3.new(math.random(3, 6), math.random(3, 6), math.random(3, 6))
			local colorScale = math.random(80, 200) --grayness
			r.Color = Color3.fromRGB(colorScale, colorScale, colorScale)
			local pos = helperFunctions.randomPointOnShoulderNearZ(z, 1, r.Size)
			r:PivotTo(CFrame.new(pos) * CFrame.Angles(math.rad(math.random(0,359)), math.rad(math.random(0,359)), math.rad(math.random(0,359))))
		end
	end
end]]

--[[function addObstacle()
	local obstacleFrequency = {}
	if biome == "Forest" then
		obstacleFrequency = {["Arch"] = 3, ["Bush"] = 14, ["LogRamp"] = 5, ["Rock"] = 3, ["Stump"] = 6, 
			["Tree"] = 10, ["TreePlatform"] = 2}
	else
		obstacleFrequency = {["LogRamp"] = 2, ["Rock"] = 1, ["LongLilypad"] = 10, ["FlatLog"] = 10}
	end
	
	--use frequency to select the next obstacle
	local totalFrequencies = 0
	for obstacle, frequency in obstacleFrequency do
		totalFrequencies += frequency
	end
	
	local obstacleLane = math.random(1, 3)
	local rollFrequency = math.random(1, totalFrequencies)
	local currentFrequency = 0
	local o --the obstacle object to be selected
	for obstacle, frequency in obstacleFrequency do
		currentFrequency += frequency or 1
		if rollFrequency <= currentFrequency then
			o = ReplicatedStorage.Obstacles[obstacle]:Clone()
			--o = ReplicatedStorage.Obstacles.LogRamp:Clone() --for testing one obstacle only
			break
		end
	end
	
	--place the chosen obstacle
	o.Parent = workspace.PathParts
	helperFunctions.setCollisionGroup(o, o.Name == "Arch" and "SlidingObstacle" or "Obstacle")
	local part = o:IsA("Model") and o.PrimaryPart or o
	local x = (obstacleLane - 2) * laneWidth
	local y = part.Size.Y / 2 + .5 --add floor height
	local z = nextObstacleAtZ + part.Size.Z / 2
	local angleY = 0
	--rotate some obstacles
	if table.find({"Arch", "Tree", "Stump", "Bush", "Rock","LongLilypad", "FlatLog"}, o.Name) and math.random(1, 2) == 1 then --Arch tree can be flipped
		angleY = 180
	end
	local angle = CFrame.Angles(0, math.rad(angleY), 0)
	o:PivotTo(CFrame.new(Vector3.new(x, y, z)) * angle)
	local distToNextObstacle = 30 + 40 * (1 - densityRating()) --with min of 20, you'd hit bushes behind trees
	
	--chain some obstacles
	if biome == "Water" 
		and table.find({"LongLilypad", "FlatLog"}, o.Name)
		and table.find({"LongLilypad", "FlatLog"}, lastObstacleAdded) then
		distToNextObstacle = 10 --size of the wedges since parts are spaced on the primary part
	end
	nextObstacleAtZ += part.Size.Z + distToNextObstacle

	--put acorns on some obstacles
	if (o.Name == "Arch" and math.random(1, 2) == 1)
		or (o.Name == "LongLilypad" and math.random(1, 4) <= 3)
	then
		nextObstacleAtZ = helperFunctions.addAcorn(o.TopTouchArea.Position, nextObstacleAtZ)
	end
	
	--put acorn next to some obstacles
	if biome == "Forest" and math.random(1, 6) == 1 then
		local leftMostOption = math.random(1, 2) == 1
		local x = part.Position.X + laneWidth * (obstacleLane == 1 and (leftMostOption and 1 or 2) or obstacleLane == 2 and (leftMostOption and -1 or 1) or (leftMostOption and -2 or -1))
		nextObstacleAtZ = helperFunctions.addAcorn(Vector3.new(x, 2.8, part.Position.Z), nextObstacleAtZ)
	end


	--task touch part listeners
	if o.Name == "Arch" then
		o.BranchTouchArea.Touched:Connect(function(hit)
			if hit == hrp and not part:GetAttribute("Touched") then
				part:SetAttribute("Touched", true)
				updateTaskProgress(6, 1)
				if o:FindFirstChild("BranchTouchArea") then
					o.BranchTouchArea:Destroy()
				end
			end
		end)
		o.SlideTouchArea.Touched:Connect(function(hit)
			if hit == hrp and not part:GetAttribute("Touched") then
				part:SetAttribute("Touched", true)
				slidUnderTrees += 1
				if o:FindFirstChild("SlideTouchArea") then
					o.SlideTouchArea:Destroy()
				end
				if slidUnderTrees == 2 then
					updateTaskProgress(3, 2)
				end
			end
		end)
	elseif o.Name == "Bush" then
		o.TopTouchArea.Touched:Connect(function(hit)
			if hit == hrp and not part:GetAttribute("Touched") then
				part:SetAttribute("Touched", true)
				updateTaskProgress(4, 1)
				if o:FindFirstChild("TopTouchArea") then
					o.TopTouchArea:Destroy()
				end
			end
		end)
	elseif o.Name == "Tree" or o.Name == "TreePlatform" then
		o.TopTouchArea.Touched:Connect(function(hit)
			if hit == hrp and not part:GetAttribute("Touched") then
				part:SetAttribute("Touched", true)
				updateTaskProgress(5, 1)
				if o:FindFirstChild("TopTouchArea") then
					o.TopTouchArea:Destroy()
				end
			end
		end)
	end
	
	lastObstacleAdded = o.Name
end]]

--[[function addAcorn(position: Vector3?) --optional position
	local acornLane = math.random(1, 3)
	local a = ReplicatedStorage.Acorn:Clone()
	a.Parent = workspace.Scenery
	local x = (acornLane - 2) * laneWidth
	a.Position = position or Vector3.new(x, 4, nextObstacleAtZ)
	a.Touched:Connect(function(hit)
		if hit == hrp then
			SoundService.Crunch2:Play()
			addStamina(15)
			a:Destroy()
			ReplicatedStorage.Events.playerEarnedCoins:FireServer(clientUtil.addBonusToCoins(10))
		end
	end)
	nextObstacleAtZ += position and 0 or 10 --don't extend if this was placed on an obstacle
end]]

function handleCollectibleTouched(collectible: Model, partName: string?)
	if collectible.Name == "Acorn" then
		SoundService.Crunch2:Play()
		local staminaToAdd = 15
		if table.find((clientUtil.PlayerData() or {}).purchasedItems or {}, 7) then
			staminaToAdd += 5
		end
		addStamina(staminaToAdd)
		collectible:Destroy()
		local coinsEarned = clientUtil.addBonusToCoins(10)
		coins += coinsEarned --temp client update for quick response
		showCoins()
		ReplicatedStorage.Events.playerEarnedCoins:FireServer(coinsEarned)
	elseif collectible.Name == "LeafPile" then
		local bonus = score * .01
		local newSpeed = helperFunctions.findTargetSpeedForPoints(speed, bonus)
		setSpeed(newSpeed)
		score += bonus

		SoundService.Boost:Play()
		leavesCollected += 1
		if leavesCollected == 10 then
			updateTaskProgress(7, leavesCollected)
		end
	elseif collectible.Name == "Arch" then
		if partName == "SlideTouchArea" then
			slidUnderTrees += 1
			if slidUnderTrees == 2 then
				updateTaskProgress(3, 2)
			end
		end
	elseif collectible.Name == "Bush" then
		if partName == "TopTouchArea" then
			updateTaskProgress(4, 1)
		end
	elseif collectible.Name =="Tree" or collectible.Name == "TreePlatform" then
		if partName == "TopTouchArea" then
			updateTaskProgress(5, 1)
		end
	end
end

ReplicatedStorage.Events.collectibleTouchedRemote.OnClientEvent:Connect(handleCollectibleTouched)
ReplicatedStorage.Events.collectibleTouched.Event:Connect(handleCollectibleTouched)

function updatePlayerCollisionGroup() --should be called when you start/stop sliding/changing lanes
	if playerVerticalStatus == "Sliding" and changingLanes then
		setPlayerCollisionGroup("PlayerSlidingAndChangingLanes")
	elseif changingLanes then
		setPlayerCollisionGroup("PlayerChangingLanes")
	elseif playerVerticalStatus == "Sliding" then
		setPlayerCollisionGroup("PlayerSliding")
	else
		setPlayerCollisionGroup("Player")
	end
end

function setPlayerCollisionGroup(group) --only change collision group if necessary
	if hrp.CollisionGroup ~= group then
		helperFunctions.setCollisionGroup(char, group)
	end
end

function currentLaneX()
	return centerLaneX + (2 - lane) * laneWidth
end

function togglePlayerFrozen(freeze)
	if freeze then
		hrp.Anchored = true
		hrp.Velocity = Vector3.zero --cancel momentum
	else
		hrp.Anchored = false
	end
end

function addStamina(addAmount)
	if addAmount < 0 and table.find((clientUtil.PlayerData() or {}).purchasedItems or {}, 5) then
		addAmount *= .8 --lower stamina drain
	end
	
	local previousStamina = stamina
	stamina = math.clamp(stamina + addAmount, 0, maxStamina)
	
	local yellowThreshold = .4 * maxStamina
	local redThreshold = .2 * maxStamina
	
	if stamina > previousStamina then
		clientUtil.toggleVignette(nil)
	elseif stamina < redThreshold then
		clientUtil.toggleVignette(Color3.fromHex("#dc4512"))
	elseif stamina < yellowThreshold then
		clientUtil.toggleVignette(Color3.fromHex("#f1f132"))
	else
		clientUtil.toggleVignette(nil)
	end
end

RunService.Heartbeat:Connect(function(delta) --heartbeat is good for physics-based movement, raycasts, impulses
	--record delta before processing other calculations
	
	if clientUtil.getInLobby() or not hrp then return end
		
	--drain or regen stamina
	if not crashed and not clientUtil.getGamePaused() then
		checkIfPlayerCrashed(delta)
		
		if playerVerticalStatus == "Gliding" then
			addStamina(-delta * 10) --scale is about what you use per second
			if stamina == 0 then
				setPlayerVerticalStatus("Falling")
			end
		elseif playerVerticalStatus == "Sliding" then
			addStamina(-delta * 5)
			if stamina == 0 then
				setPlayerVerticalStatus("Running")
			end
		else
			addStamina(delta * 1.5) --default scale would regen about 1 per second
		end
		playerGui:WaitForChild("ScreenGui"):WaitForChild("Stamina2").Percentage.Value = stamina / maxStamina * 100
	end


	if not crashed and hrp and hrp.Parent then
		if not clientUtil.getGamePaused() then
			score += speed * delta
		end
		
		--[[Left/Right if key is held
		--this was causing weird issues when you hold both Left and Right and then quickly release one
		local leftAction = actionInputBeingHeld("Left")
		local rightAction = actionInputBeingHeld("Right")
		if not (leftAction and rightAction) then --don't allow both to be held at once
			if leftAction and tick() - leftAction.start > .5 then
				addInputToQueue("Left", true)
				activeInputs[leftAction] = nil
			end
			
			if rightAction and tick() - rightAction.start > .5 then
				addInputToQueue("Right", true)
				activeInputs[rightAction] = nil
			end
		end]]
		
		--check if jump apex has been reached
		if playerVerticalStatus == "Ascending"
			and #lastHrpHeights == 3
			and lastHrpHeights[1] < lastHrpHeights[2]
			and lastHrpHeights[2] < lastHrpHeights[3]
			and lastHrpHeights[3] > hrp.Position.Y 
			and hrp.Position.Y - jumpBeginHeight > 3 --make sure player rose enough since jumping to be a real apex
		then
			setPlayerVerticalStatus("Falling")
			if actionInputBeingHeld("Up") then
				setPlayerVerticalStatus("Gliding")
			end
		end
		
		--track previous heights
		table.insert(lastHrpHeights, hrp.Position.Y)
		if #lastHrpHeights > 3 then
			table.remove(lastHrpHeights, 1)
		end
				
		--move player
		local differenceSideways = currentLaneX() - hrp.Position.X --dist from target position
		if math.abs(differenceSideways) > .1 then
			changingLanes = differenceSideways < 0 and "Right" or "Left"
		else
			changingLanes = nil
		end
		updatePlayerCollisionGroup()
		
		--local sidewaysSign = differenceSideways < 0.1 and -1 or 1
		local directionY = math.pi --180 degrees
		local directionZ = 0
		
		if math.abs(differenceSideways) > .1 and laneChangeStartedCFrame then
			--local pctCopmlete = math.clamp((hrp.Position.Z - laneChangeStartedCFrame.Position.Z) / laneWidth, 0, 1) --change denominator to adjust duration of lane change
			local totalX = math.abs(currentLaneX() - laneChangeStartedCFrame.Position.X)
			local alpha = math.clamp((currentLaneX() - hrp.Position.X) / totalX, -1, 1)
			
			--adjust facing angle while changing lanes
			if playerVerticalStatus == "Gliding" then
				directionZ += math.rad(math.sin(alpha * math.pi) * 30) --roll while flying
			else
				directionY += math.rad(math.sin(alpha * math.pi) * 30) --interpolate with sine wave up to max angle
			end
		end
		
		--update AlignOrientation. Tried only changing if needed using ToEulerAnglesXYZ, but the angles were coming out reversed and it didn't help efficiency.
		hrp.AlignOrientation.Attachment1.CFrame = CFrame.Angles(0, directionY, directionZ)
		--replaced 1/25 hrp:PivotTo(CFrame.new(Vector3.new(newX, hrp.Position.Y, hrp.Position.Z)) * direction)
		
		
		--show score
		local scoreFrame = playerGui.ScreenGui.ScoreFrame
		scoreFrame.ScoreLabel.Text = helperFunctions.formatNumber(math.round(score)) --.. ' - ' .. helperFunctions.formatNumber(math.round(speed))
		
		lastHrpPosition = hrp.Position
	
		--load content ahead of player
		local horizon = hrp.Position.Z + speed * 15

		if not addingBiomes then
			addingBiomes = true
			task.spawn(function() --don't block heartbeat while these generate
				nextObstacleAtZ, lastObstacleAdded, lastPathEndsAtZ, lastBiome = helperFunctions.AddMorePathsIfNeeded(horizon, lastPathEndsAtZ, nextObstacleAtZ, centerLaneX, lastObstacleAdded, biome, speed, clientUtil.getSceneryEnabled(), lastBiome, runStartTime, tutorialMode, gameMode)
				addingBiomes = false
			end)
		end
		--[[if horizon > lastPathEndsAtZ and not addingBiomes then
			addingBiomes = true
			biome = "Forest" --default biome is Forest
			local biomeSections = math.random(2, 4)
			
			--alternate biomes
			if speed > 100 and lastBiome == "Forest" and math.random(1, 4) == 1 then
				biome = "Water"
				biomeSections = math.random(1, 4)
			elseif speed > 150 and lastBiome == "Forest" and math.random(1, 4) <= 1 then
				biome = "Desert"
				local endingZ = helperFunctions.generateDesertObstacles(nextObstacleAtZ)
				biomeSections = math.ceil((endingZ - nextObstacleAtZ) / 300)
				nextObstacleAtZ += biomeSections * 300 + 50
			end
			
			if biome == "Forest" then
				helperFunctions.addFlowerPatch(biome, lastPathEndsAtZ, biomeSections * 300, clientUtil.getSceneryEnabled())
			end
			
			task.spawn(function() --don't block heartbeat while these generate
				--generate entire biomes at once to control duration
				for x = 1, biomeSections do
					nextObstacleAtZ, lastObstacleAdded, lastPathEndsAtZ = helperFunctions.addPath(biome, centerLaneX, lastPathEndsAtZ, nextObstacleAtZ, lastObstacleAdded, runStartTime, clientUtil.getSceneryEnabled(), tutorialMode)
					task.wait()
				end
				addingBiomes = false
			end)

			lastBiome = biome
		end]]
	end

	makePassedPartsInvisible()
end)

function actionInputBeingHeld(action)
	for _, i in activeInputs do
		if i.action == action then
			return i
		end
	end
end

function clearOppositeActiveInputs(action)
	local opp = getActionOpposite(action)
	for i, input in activeInputs do
		if input.action == opp then
			activeInputs[i] = nil
		end
	end
end

function clearActionInputType(action) --used to remove any overlapping up actions
	for i, input in inputQueue do
		if input.action == action then
			table.remove(inputQueue, i)
		end
	end
end

RunService.RenderStepped:Connect(function() --RenderStepped good for handling user input
	if hrp and not clientUtil.getInLobby() then
		local z = hrp.Position.Z
		
		for i, entry in inputQueue do
			--entry time makes input expire when player is not moving for tutorial instructions
			if z > entry.z + inputActionLength[entry.action] or tick() - entry.time > 1 then
				table.remove(inputQueue, i)
			elseif entry.action == "Up" then
				if entry.begin then
					if handleJumpKeyPressed() then
						table.remove(inputQueue, i)
					end
				else
					if handleJumpKeyReleased() then
						table.remove(inputQueue, i)
						clearActionInputType("Up")
					end
				end
			elseif entry.action == "Down" then
				if entry.begin then
					if downKeyPressed() then
						table.remove(inputQueue, i)
					end
				else
					if downKeyReleased() then
						table.remove(inputQueue, i)
						clearActionInputType("Down")
					end
				end
			elseif entry.action == "Left" then
				if entry.begin then
					if lane == 1 then --ignore left movement in left lane
						table.remove(inputQueue, i)
					elseif isDiagonalClear(false) then
						changeLane(false)
						table.remove(inputQueue, i)
					else
						--print("turn blocked")
					end
				else
					table.remove(inputQueue, i)
				end
			elseif entry.action == "Right" then
				if entry.begin then
					if lane == 3 then --ignore right movement in right lane
						table.remove(inputQueue, i)
					elseif isDiagonalClear(true) then
						changeLane(true)
						table.remove(inputQueue, i)
					else
						--print("turn blocked")
					end
				else
					table.remove(inputQueue, i)
				end
			end
		end
	end
	
	if hrp and hrp:FindFirstChild("Speedlines") then --facing the camera
		local minSpeed = 200
		local maxSpeed = 300
		hrp.Speedlines.ParticleEmitter.Enabled = speed > minSpeed and not crashed and not clientUtil.getInLobby() and not clientUtil.getGamePaused()
		local offset = speed > maxSpeed and 8 or math.map(speed, minSpeed, maxSpeed, 3, 8) --can go from about 3 to 8
		hrp.Speedlines:PivotTo(CFrame.new(camera.CFrame.Position + camera.CFrame.LookVector * offset) * camera.CFrame.Rotation)
	end
end)

function makePassedPartsInvisible() --make some obstacles semitransparent as you approach them
	if not hrp then return end
	for _, model in workspace.PathParts:GetChildren() do
		if model:IsA("Model") and not model:GetAttribute("madeTransparentAfterPassing")
			and table.find(helperFunctions.obstacleNames(), model.Name) and (model.Name ~= "LogRamp")
			and hrp.Position.Z + 3 > model.PrimaryPart.Position.Z --won't disappear if you run into it
			and hrp.Position.Z - 25 < model.PrimaryPart.Position.Z --ignore parts already behind player
		then
			model:SetAttribute("madeTransparentAfterPassing", true) --debounce to save work
			helperFunctions.setModelTransparency(model, .8)
		end
	end
end

function toggleCameraConnection(enabled)
	if enabled then
		cameraConnection = RunService:BindToRenderStep("FollowCamera", Enum.RenderPriority.Camera.Value, function()
			if not hrp or clientUtil.getInLobby() then return end

			local camPos = hrp.Position + Vector3.new(0, 11, -20)
			camera.CFrame = CFrame.lookAt(camPos, hrp.Position)
		end)
	elseif cameraConnection then
		cameraConnection:Disconnect()
		cameraConnection = nil
	end
end

function getLaneOfPosition(pos: Vector3)
	local dist1 = math.abs(pos.X - (centerLaneX + laneWidth))
	local dist2 = math.abs(pos.X - centerLaneX)
	local dist3 = math.abs(pos.X - (centerLaneX - laneWidth))
	if dist1 < dist2 and dist1 < dist3 then
		return 1
	elseif dist2 < dist1 and dist2 < dist3 then
		return 2
	else
		return 3
	end
end

function reviveApply()
	if not waitForReviveDecisionStartedTime or clientUtil.getInLobby() then return end
	revivePurchasePromptTime = nil
	
	--if player has revives, consume one
	if table.find((clientUtil.PlayerData() or {}).purchasedItems or {}, 12) then
		waitForReviveDecisionStartedTime = nil

		local consumed = ReplicatedStorage.Functions.consumeItem:InvokeServer(12)
		if consumed then
			revivedTime = tick()
			crashed = false
			revivesUsed += 1
			
			local reviveFrame = playerGui:WaitForChild("ScreenGui"):WaitForChild("ReviveFrame")
			reviveFrame.Visible = false
			
			hrp.LinearVelocityZ.Enabled = true
			hrp.LinearVelocityY.Enabled = true
			hrp.AlignOrientation.Enabled = true
			hrp.AlignPositionX.Enabled = true
			hrp.AlignPositionZ.Enabled = true
			playAnimation("Run")
			local shield = Instance.new("ForceField", char)
			Debris:AddItem(shield, reviveInvincibilityDuration)
			
			if crashedObjectName == "Water" then
				setPlayerVerticalStatus("Ascending") --jump out of the water
			end
			
			task.delay(reviveInvincibilityDuration, function()
				revivedTime = nil
			end)
		else
			reviveDecline() --last resort fail if couldn't consume item
		end
	else
		revivePurchasePromptTime = tick()
		MarketplaceService:PromptProductPurchase(player, 3538063996)		
	end
end

function reviveDecline()
	if not waitForReviveDecisionStartedTime then return end
	
	local reviveFrame = playerGui:WaitForChild("ScreenGui"):WaitForChild("ReviveFrame")
	waitForReviveDecisionStartedTime = nil
	reviveFrame.Visible = false
	
	if not clientUtil.getInLobby() then
		endRun(crashedObjectName, true)
	end
end

function crash() --set crashedObjectName before calling
	if crashed then return end
	crashed = true
	hrp.LinearVelocityZ.Enabled = false
	hrp.LinearVelocityY.Enabled = false
	hrp.AlignOrientation.Enabled = false
	hrp.AlignPositionX.Enabled = false
	hrp.AlignPositionZ.Enabled = false
	shakeCamera(math.round(speed / 25))
	playAnimation("FallOver")
	cancelSoundEffects()
	setSpeedBoostFrameVisibility()

	--check if revive should be offered
	if tutorialMode then
		endRun(crashedObjectName, true)
	elseif raceMetadata then
		endRun(crashedObjectName, false)
	elseif revivesUsed >= 5 then
		endRun(crashedObjectName, true)
	else
		local reviveDesisionTime = 3
		waitForReviveDecisionStartedTime = tick()
		local reviveFrame = playerGui:WaitForChild("ScreenGui"):WaitForChild("ReviveFrame")
		local progress: Frame = reviveFrame:WaitForChild("ProgressBar")
		reviveFrame.Visible = true
		progress.Size = UDim2.new(0.9, 0, 0, 3)
		progress:TweenSize(UDim2.new(0, 0, 0, 3), Enum.EasingDirection.Out, Enum.EasingStyle.Linear, reviveDesisionTime)

		task.delay(reviveDesisionTime, function()
			if not revivePurchasePromptTime then
				reviveDecline() --decline if player didn't make a choice
			end
		end)
	end
end

function checkIfPlayerCrashed(delta)
	if crashed then return end
	
	local overlapParams = OverlapParams.new()
	local instances = {}
	--[[for _, obstacle in workspace.PathParts:GetChildren() do 
		if obstacle.Name ~= "LogRamp" then
			table.insert(instances, obstacle) 
		end
	end]]
	--list of collidable base parts (no meshes used). Ignore parts with noCrash tag like ramps unless I stop.
	for _, obstaclePart in workspace.PathParts:GetDescendants() do 
		if obstaclePart:IsA("BasePart") and
			not (hrp.Velocity.Z > 10 and CollectionService:HasTag(obstaclePart, "noCrash")) then
			table.insert(instances, obstaclePart)
		end
	end
	overlapParams.FilterDescendantsInstances = instances
	overlapParams.FilterType = Enum.RaycastFilterType.Include
	overlapParams.RespectCanCollide = true
	overlapParams.CollisionGroup = hrp.CollisionGroup
	
	local distance = speed * delta + 2 --buffer. 1 was too small for the tutorial bush
	local boxSize = Vector3.new(2, 2, distance)
	local boxCFrame = CFrame.new(hrp.Position + Vector3.new(0, 0, boxSize.Z / 2))
	local parts = workspace:GetPartBoundsInBox(
		boxCFrame,
		boxSize,
		overlapParams
	)
	
	if #parts > 0 then
		if parts[1].Parent.Name == "Bush" and playerVerticalStatus == "Ascending" then
			parts[1].CanCollide = false
			return
		end
		
		--check for held lane changes
		local diverting = false
		--[[ turned off diverting feature because it can be abused by holding one direction and toggling the other
		local leftAction = actionInputBeingHeld("Left")
		local rightAction = actionInputBeingHeld("Right")
		if not (leftAction and rightAction) then --don't allow both to be held at once
			if leftAction and lane > 1 then
				addInputToQueue("Left", true)
				activeInputs[leftAction] = nil
				diverting = true
			elseif rightAction and lane < 3 then
				addInputToQueue("Right", true)
				activeInputs[rightAction] = nil
				diverting = true
			end	
		end]]
		
		if (diverting and not tutorialMode) or (revivedTime and tick() - revivedTime < reviveInvincibilityDuration) then --no diverting during tutorial
			for _, part in parts do
				if not CollectionService:HasTag(part, "noCrash") then --ramps remain collidable or you would fall through them
					part.CanCollide = false --allow player to go through this obstacle in subsequent frame while input is being processed
				end
			end
		else
			--Chance to survive hitting an obstacle
			if table.find((clientUtil.PlayerData() or {}).purchasedItems or {}, 11) and math.random(1, 100) == 1 then
				part.CanCollide = false
				clientUtil.toastCreate("Survived!")
			else
				crashedObjectName = tutorialMode and "Tutorial" or parts[1].Parent.Name
				crash()
			end
		end
	end
end

function isPartObstacle(part)
	while part.Parent do
		if part.Parent == workspace.PathParts then
			return true
		end
		part = part.Parent
	end
end

function isDiagonalClear(right: boolean)
	--check if destination is clear.
	if not hrp then return end
	if crashed or (tutorialMode and requiredControl == nil) then return end
	
	if playerVerticalStatus == "Sliding" and isPlayerInsidePart("ArchCenterWall") then
		return false
	end	
	
	local overlapParams = OverlapParams.new()
	local instances = {}
	for _, value in workspace.PathParts:GetChildren() do table.insert(instances, value) end
	overlapParams.FilterDescendantsInstances = instances
	overlapParams.FilterType = Enum.RaycastFilterType.Include
	overlapParams.RespectCanCollide = true
	overlapParams.CollisionGroup = hrp.CollisionGroup
	overlapParams.MaxParts = 1
	local x = (right and -1 or 1) * laneWidth
	local z = (laneWidth / 2 + 1) / 2 --center 2.5 studs ahead with 5 stud length
	local diagOffset = Vector3.new(x, 0, z)
	local cf = CFrame.new(hrp.Position + diagOffset) --rotation doesn't matter
	local size = Vector3.new(laneWidth - 2, 2, laneWidth / 2 + 1) --if you look ahead to prevent hitting a bush right after changing lanes, you also can't get onto low ramps
	local parts = workspace:GetPartBoundsInBox(cf, size, overlapParams)
	return #parts == 0
end

function changeLane(right: boolean)
	--check if there is a required control
	if requiredControl and requiredControl.requiredControl == "Right" and right then
		requiredControl = nil
		tutorialCheckpoint += 1
		togglePlayerFrozen(false)
	elseif requiredControl and requiredControl.requiredControl == "Left" and not right then
		requiredControl = nil
		tutorialCheckpoint += 1
		togglePlayerFrozen(false)
	elseif tutorialMode then
		return
	end
	
	previousLane = lane
	if lane < 3 and right then
		lane += 1
		laneChangeStartedCFrame = hrp.CFrame
		alignPlayerToLane()
	elseif lane > 1 and not right then
		lane -= 1
		laneChangeStartedCFrame = hrp.CFrame
		alignPlayerToLane()
	end
end

function alignPlayerToLane()
	hrp.AlignPositionX.Attachment1.Position = Vector3.new(currentLaneX(), 0, 0)
end

function getSwipeDirection(input) --for touch and gamepad
	local delta = input.UserInputType == Enum.UserInputType.Touch and input.delta or input.position
	if input.UserInputType == Enum.UserInputType.Gamepad1 then
		delta = Vector3.new(delta.X, -delta.Y, 0) --gamepad Y is opposite of touch
	end
	local MIN_SWIPE_DISTANCE = input.UserInputType == Enum.UserInputType.Touch and 1 or .8 --some sort of screen scale for touch. gamepad max is 1
	local DOMINANCE = 1.5 -- X must be 1.5x stronger than Y to ignore diagonals

	-- Must be long enough
	if delta.Magnitude < MIN_SWIPE_DISTANCE then
		return nil
	end

	if math.abs(delta.X) > math.abs(delta.Y) * DOMINANCE then
		if delta.X > 0 then
			return Enum.SwipeDirection.Right
		else
			return Enum.SwipeDirection.Left
		end
	elseif math.abs(delta.Y) > math.abs(delta.X) * DOMINANCE then
		if delta.Y > 0 then
			return Enum.SwipeDirection.Down
		else
			return Enum.SwipeDirection.Up
		end
	end
end

function setVelocityY(force) 
	--temporarily set velocity using a constraint so it doesn't fight with physics solver or collision rebounding
	--may cause issue when trying to unset after other things have changed
	
	if hrp.LinearVelocityY.LineVelocity == force then return end --debounce
	toggleVerticalVelocity(force)
	local velocityWaitStartedTime = tick()
	task.spawn(function() --wait for it to reach target or timeout and then disable.
		while math.abs(force - hrp.AssemblyLinearVelocity.Y) > .5 and tick() - velocityWaitStartedTime < .2 do
			task.wait()
		end
		if hrp.LinearVelocityY.LineVelocity == force then --check if the original force is still on
			toggleVerticalVelocity(0)
		end
	end)
	
	--old method: shoots you up if you jump while hitting a bush because it adds the force to the current velocity
	--hrp.AssemblyLinearVelocity = Vector3.new(hrp.AssemblyLinearVelocity.X, force, hrp.AssemblyLinearVelocity.Z)
end

function toggleFastFalling(enabled)
	if fastFalling == enabled then return end --debounce
	if enabled then
		fastFalling = true
		setVelocityY(-50)
		toggleVerticalVelocity(-120)
	else
		fastFalling = false
		if playerVerticalStatus == "Falling" then --don't interrupt gliding
			toggleVerticalVelocity(0)
		end
	end
end

function downKeyPressed()
	if crashed then return end
	if tutorialMode and requiredControl and requiredControl.requiredControl ~= "Down" then return end

	if tutorialMode and requiredControl and requiredControl.requiredControl == "Down" then
		local startCFrame = hrp.CFrame
		togglePlayerFrozen(false)
		playerGui:WaitForChild("ScreenGui"):WaitForChild("TutorialInstructionFrame").Visible = false
		if not enforcingHeldControlForTutorial then
			task.spawn(function()
				if requiredControl.holdTillZ then
					enforcingHeldControlForTutorial = true
					while hrp and requiredControl and hrp.Position.Z >= requiredControl.z and hrp.Position.Z < requiredControl.holdTillZ do
						if not actionInputBeingHeld("Down") then
							playerGui:WaitForChild("ScreenGui"):WaitForChild("TutorialInstructionFrame").Visible = true
							togglePlayerFrozen(true)
							hrp:PivotTo(startCFrame)
						end
						task.wait()
					end
				end
				requiredControl = nil
				tutorialCheckpoint += 1
				enforcingHeldControlForTutorial = false
			end)
		end
	end
	
	if playerVerticalStatus == "Falling" or playerVerticalStatus == "Ascending" then
		toggleFastFalling(true)
		
		return true
	elseif playerVerticalStatus == "Running" then --Slide
		return setPlayerVerticalStatus("Sliding")
	end
end

function downKeyReleased()
	local consumed = false --should always disable fastFalling, but can also change status
	if fastFalling then
		toggleFastFalling(false)
		consumed = true
	end
	if playerVerticalStatus == "Sliding" and not isPlayerInsidePart("ArchCenterWall") then
		local statusChanged = setPlayerVerticalStatus("Running")
		if not consumed and statusChanged then
			consumed = true
		end
	end
	
	return consumed
end

function isPlayerInsidePart(partName) --for example, sliding through Arch
	local overlapParams = OverlapParams.new()
	local instances = {}
	for _, value in workspace.PathParts:GetChildren() do table.insert(instances, value) end
	overlapParams.FilterDescendantsInstances = instances
	overlapParams.FilterType = Enum.RaycastFilterType.Include
	overlapParams.RespectCanCollide = false
	local parts = workspace:GetPartBoundsInBox(hrp.CFrame, hrp.Size, overlapParams)
	for _, part in parts do
		if part.Name == partName then
			return true
		end
	end
end

function toggleSlidingState(enabled: boolean) --ended by jumping or expiring
	if enabled then
		playAnimation("Slide")
		slidUnderTrees = 0 --start counting when sliding starts
		clientUtil.toggleSoundEffect(SoundService.Sliding, true, .7, .5)
	else
		clientUtil.toggleSoundEffect(SoundService.Sliding, false, .3, nil)
	end
	updatePlayerCollisionGroup()
end

function handleJumpKeyPressed()
	if crashed then return end
	if tutorialMode and requiredControl and requiredControl.requiredControl ~= "Jump" then return end
	if onRamp and not tutorialMode then return end --wait till leaving ramp to jump
	if isPlayerInsidePart("ArchCenterWall") then return end
	
	if requiredControl and requiredControl.requiredControl == "Jump" then
		local startCFrame = hrp.CFrame
		togglePlayerFrozen(false)
		playerGui:WaitForChild("ScreenGui"):WaitForChild("TutorialInstructionFrame").Visible = false
		if not enforcingHeldControlForTutorial then
			task.spawn(function()
				if requiredControl.holdTillZ then
					enforcingHeldControlForTutorial = true
					while hrp and requiredControl and hrp.Position.Z >= requiredControl.z and hrp.Position.Z < requiredControl.holdTillZ do
						if not actionInputBeingHeld("Up") then
							playerGui:WaitForChild("ScreenGui"):WaitForChild("TutorialInstructionFrame").Visible = true
							togglePlayerFrozen(true)
							hrp:PivotTo(startCFrame)
						end
						task.wait()
					end
				end
				requiredControl = nil
				tutorialCheckpoint += 1
				enforcingHeldControlForTutorial = false
			end)
		end
	end

	if isNewPlayerVerticalStatusEligible("Ascending") then
		return setPlayerVerticalStatus("Ascending")
	elseif playerVerticalStatus == "Falling" then
		return setPlayerVerticalStatus("Gliding")
	end
end

function handleJumpKeyReleased()
	if playerVerticalStatus == "Gliding" then
		return setPlayerVerticalStatus("Falling")
	end
end

function areActionsOpposite(a, b)
	if (a == "Up" and b == "Down") or (a == "Down" and b == "Up")
		or (a == "Right" and b == "Left") or (a == "Left" and b == "Right") then
		return true
	end
end

function getActionOpposite(a)
	if a == "Up" then
		return "Down"
	elseif a == "Down" then
		return "Up"
	elseif a == "Right" then
		return "Left"
	elseif a == "Left" then
		return "Right"
	end
end

function addInputToQueue(action, begin)
	--clear previous actions when starting a new input
	if begin then
		for i, input in inputQueue do
			if input.action == action then
				table.remove(inputQueue, i) --override previous duplicate action
			elseif (action == "Left" or action == "Right") and areActionsOpposite(input.action, action) then
				--cancel out opposite action. ie I'm in left lane next to a log. I press right which gets queued and then left which gets cancelled. I shouldn't go right after the log. Or I'm in middle lane with log on right. Pressing right then left should keep me where I am.
				table.remove(inputQueue, i) 
				return
			end
		end
				
		if action == "Left" or action == "Right" then
			--clearOppositeActiveInputs(action) --ie I press and hold Left then press Right. It shouldn't go left again after a delay.
		end
	end
	
	if not crashed and hrp and not clientUtil.getGamePaused()
		and not (tutorialMode and requiredControl == nil and begin) --don't start input unless it's required
	then
		table.insert(inputQueue, {action = action, begin = begin, z = hrp.Position.Z, time = tick()})
	end
end

UserInputService.InputBegan:Connect(function(input, gameProcessedEvent)
	--print(gameProcessedEvent, input.KeyCode, input.UserInputType)
	if gameProcessedEvent and input.UserInputType ~= Enum.UserInputType.Touch and input.UserInputType ~= Enum.UserInputType.Gamepad1 then return end
	if crashed or not hrp then return end
	
	if input.KeyCode == Enum.KeyCode.Q and not clientUtil.getInLobby() and not raceMetadata then
		togglePause(true)
	end
	
	if input.KeyCode == Enum.KeyCode.E then
		useSpeedBoost()
	end
	
	--remaining controls disabled while paused
	if clientUtil.getGamePaused() then return end
	activeInputs[input] = {start = tick()} --touches that just started will have an undetermined action
	local z = hrp.Position.Z
	
	if input.KeyCode == Enum.KeyCode.D or input.KeyCode == Enum.KeyCode.Right or input.KeyCode == Enum.KeyCode.DPadRight then
		addInputToQueue("Right", true)
		activeInputs[input].action = "Right"
	elseif input.KeyCode == Enum.KeyCode.A or input.KeyCode == Enum.KeyCode.Left or input.KeyCode == Enum.KeyCode.DPadLeft then
		addInputToQueue("Left", true)
		activeInputs[input].action = "Left"
	elseif input.KeyCode == Enum.KeyCode.W or input.KeyCode == Enum.KeyCode.Up or input.KeyCode == Enum.KeyCode.ButtonA or input.KeyCode == Enum.KeyCode.ButtonR2 then
		addInputToQueue("Up", true)
		activeInputs[input].action = "Up"
	elseif input.UserInputType == Enum.UserInputType.Touch 
		and input.Position.X > camera.ViewportSize.X * .66 
		and input.Position.Y > camera.ViewportSize.Y * .5
	then --lower-right corner
		addInputToQueue("Up", true)
		activeInputs[input].action = "Up"
	elseif input.KeyCode == Enum.KeyCode.S or input.KeyCode == Enum.KeyCode.Down or input.KeyCode == Enum.KeyCode.DPadDown then
		addInputToQueue("Down", true)
		activeInputs[input].action = "Down"
	end
end)

UserInputService.InputChanged:Connect(function(input, gameProcessedEvent)
	--[[if input.Position.Magnitude > .1 and input.UserInputType == Enum.UserInputType.Gamepad1 
		and input.KeyCode == Enum.KeyCode.Thumbstick1
	then
		print(getSwipeDirection(input))
	end]]
	--reset thumbstickDirection each time it's released
	if input.UserInputType == Enum.UserInputType.Gamepad1 and input.KeyCode == Enum.KeyCode.Thumbstick1 then
		if thumbstickDirection then
			if not getSwipeDirection(input) then
				if activeInputs[input] and activeInputs[input].action then
					addInputToQueue(activeInputs[input].action, false)
				end
				thumbstickDirection = nil
				activeInputs[input] = nil
			end
		else
			local swipeDirection = getSwipeDirection(input)
			if swipeDirection then
				thumbstickDirection = swipeDirection
				activeInputs[input] = {start = tick()}
				
				if crashed or clientUtil.getGamePaused() then return end
				
				if swipeDirection == Enum.SwipeDirection.Right then
					addInputToQueue("Right", true)
					activeInputs[input].action = "Right"
				elseif swipeDirection == Enum.SwipeDirection.Left then
					addInputToQueue("Left", true)
					activeInputs[input].action = "Left"
				elseif swipeDirection == Enum.SwipeDirection.Down then
					addInputToQueue("Down", true)
					activeInputs[input].action = "Down"
				elseif swipeDirection == Enum.SwipeDirection.Up then
					--addInputToQueue("Up", true)
					--activeInputs[input].action = "Up"
				end
			end
		end
	end
	
	if input.UserInputType == Enum.UserInputType.Touch then
		--debounce each touch to only determine its action once
		if not activeInputs[input] then --unregistered swipes while paused for example
			return
		end
		if activeInputs[input].action then --continued swiping after action was taken
			return
		end
	end
	
	if input.UserInputType == Enum.UserInputType.Touch then
		--mobile joystick is considered processed
		if crashed or clientUtil.getGamePaused() then return end
		
		if input.Position.X < camera.ViewportSize.X * .36 then  --https://devforum.roblox.com/t/the-correct-way-to-design-mobile-buttons/2494558
			local swipeDirection = getSwipeDirection(input)
			if swipeDirection == Enum.SwipeDirection.Right then
				addInputToQueue("Right", true)
				activeInputs[input].action = "Right"
			elseif swipeDirection == Enum.SwipeDirection.Left then
				addInputToQueue("Left", true)
				activeInputs[input].action = "Left"
			elseif swipeDirection == Enum.SwipeDirection.Down then
				addInputToQueue("Down", true)
				activeInputs[input].action = "Down"
			elseif swipeDirection == Enum.SwipeDirection.Up then
				--addInputToQueue("Up", true)
				--activeInputs[input].action = "Up"
			end
		end
	end
end)

UserInputService.InputEnded:Connect(function(input, gameProcessedEvent)
	if gameProcessedEvent and input.UserInputType ~= Enum.UserInputType.Touch and input.UserInputType ~= Enum.UserInputType.Gamepad1 then return end
	
	if activeInputs[input] and activeInputs[input].action then
		addInputToQueue(activeInputs[input].action, false)
	end
	activeInputs[input] = nil --cleanup active input tracking
end)

local function handleArrowKeyInput(actionName, inputState, inputObject)
	if actionName == "BlockArrowCamera" then
		if clientUtil.getInLobby() then
			return Enum.ContextActionResult.Pass
		elseif inputState == Enum.UserInputState.Begin then
			activeInputs[actionName] = {}
			-- Check if the input is a key press and specifically the Right Arrow
	 		if inputObject.KeyCode == Enum.KeyCode.Right then
				addInputToQueue("Right", true)
				activeInputs[actionName].action = "Right"
				return Enum.ContextActionResult.Sink
			elseif inputObject.KeyCode == Enum.KeyCode.Left then
				addInputToQueue("Left", true)
				activeInputs[actionName].action = "Left"
				return Enum.ContextActionResult.Sink
			end
		elseif inputState == Enum.UserInputState.End or inputState == Enum.UserInputState.Cancel then
			if activeInputs[actionName] and activeInputs[actionName].action then
				addInputToQueue(activeInputs[actionName].action, false)
			end
			activeInputs[actionName] = nil
			return Enum.ContextActionResult.Sink
		else
			return Enum.ContextActionResult.Pass -- Continue processing if not handled here
		end
	end
end

local function handleSpaceKeyInput(actionName, inputState, inputObject)
	if actionName == "BlockSpaceToJump" then
		if clientUtil.getInLobby() then
			return Enum.ContextActionResult.Pass
		elseif inputState == Enum.UserInputState.Begin then
			activeInputs[actionName] = {}
			addInputToQueue("Up", true)
			activeInputs[actionName].action = "Up"
		elseif inputState == Enum.UserInputState.End or inputState == Enum.UserInputState.Cancel then
			if activeInputs[actionName] and activeInputs[actionName].action then
				addInputToQueue(activeInputs[actionName].action, false)
			end
			activeInputs[actionName] = nil
		end
		return Enum.ContextActionResult.Sink
	end
end

--ContextActionService:BindActionAtPriority("BlockArrowCamera", handleArrowKeyInput, false, Enum.ContextActionPriority.High.Value + 1, Enum.KeyCode.Left, Enum.KeyCode.Right)
ContextActionService:BindActionAtPriority("BlockSpaceToJump", handleSpaceKeyInput, false, Enum.ContextActionPriority.High.Value + 1, Enum.KeyCode.Space)

function toggleVerticalVelocity(strength: number) 
	--constant downward slope that is only applied while gliding or fast falling. studs per second
	hrp.LinearVelocityY.LineVelocity = strength
	hrp.LinearVelocityY.Enabled = strength ~= 0
end

function beginTutorial()
	--reset variables in case player respawned
	tutorialMode = true
	tutorialCheckpoint = 1
	requiredControl = nil

	--add the tutorial obstacles
	local tutorial = ReplicatedStorage.Tutorial:Clone()
	tutorial.Parent = workspace.PathParts
	tutorial:PivotTo(CFrame.new(centerLaneX, 0.5, 450))
	for _, obstacle in tutorial.Obstacles:GetChildren() do
		obstacle.Parent = workspace.PathParts --elevate obstacles to path parts for collision detection
	end
	for _, runway in tutorial.Runways:GetChildren() do
		runway.Parent = workspace.PathParts --elevate obstacles to path parts for collision detection
	end
	tutorial:Destroy() --remove empty model
	lastPathEndsAtZ += 1500 --length of tutorial runways
	nextObstacleAtZ = 1150 --add new obstacles right after tutorial is done (on the tutorial path)
	
	--when player reaches each checkpoint, pause and show the instructions
	local frame = playerGui:WaitForChild("ScreenGui"):WaitForChild("TutorialInstructionFrame")
	while not crashed and tutorialMode do
		task.wait()
		if requiredControl then
			continue --waiting for player to press the required key
		end
		
		if hrp.Position.Z <= tutorialCheckpoints[tutorialCheckpoint].z then --player is approaching next checkpoint
			frame.Visible = false
		else --player reached checkpoint and new control is assigned
			if tutorialCheckpoints[tutorialCheckpoint].instruction == "Done" then --finished tutorial
				ReplicatedStorage.Functions.playerCompletedTutorial:InvokeServer()
				tutorialMode = false
				toggleRunUIs()
			else
				requiredControl = tutorialCheckpoints[tutorialCheckpoint]
				frame.TextLabel.Text = tutorialCheckpoints[tutorialCheckpoint].instruction
				frame.Visible = true
				togglePlayerFrozen(true)
			end
		end
	end
end

--[[function getHeightFromGround() --ranges from about 6 to 12, but could be player-specific
	local rayOrigin = hrp.Position
	local rayDirection = Vector3.new(0, -500, 0) -- cast downward 500 studs

	local raycastParams = RaycastParams.new()
	local instances = {}
	for _, value in workspace.PathParts:GetChildren() do table.insert(instances, value) end
	raycastParams.FilterDescendantsInstances = instances
	raycastParams.FilterType = Enum.RaycastFilterType.Include
	raycastParams.RespectCanCollide = true
	raycastParams.IgnoreWater = true

	local result = workspace:Raycast(rayOrigin, rayDirection, raycastParams)

	if result then
		return (rayOrigin - result.Position).Magnitude
	end
end]]

function playAnimation(animation)
	if not crashed or animation == "FallOver" then --you can only fall while crashed
		-- Stop all current
		for _, track in pairs(animTracks) do
			if track.IsPlaying or true then track:Stop() end
		end
		
		local track: AnimationTrack = getOrLoadTrack(animation)
		track:Play()
		
		--Pause some animations that aren't looped
		if animation == "FallOver" then --it's 4 seconds long
			task.delay(3, function()
				if track.IsPlaying then
					track:AdjustSpeed(0)
				end
			end)
		end
	end
end

function getOrLoadTrack(animation)
	while not humanoid do task.wait(.1) end
	if animTracks[animation] then return animTracks[animation] end
	local anim = Instance.new("Animation")
	anim.AnimationId = anims[animation]
	local track = humanoid:LoadAnimation(anim)
	animTracks[animation] = track
	return track
end

function preloadAnimTracks()
	for k, v in pairs(anims) do
		getOrLoadTrack(k)
	end
end

function closeEyes(instant: boolean) --wait for eyes to close before returning unless it's set to instant
	local frame = playerGui:WaitForChild("EyeCloseGui"):WaitForChild("Frame")
	local t = frame.Top
	local b = frame.Bottom
	t.Position = UDim2.new(.5, 0, -1, 0)
	b.Position = UDim2.new(.5, 0, 1, 0)
	local tEndPosition = UDim2.new(.5, 0, -.35, 0)
	local bEndPosition = UDim2.new(.5, 0, 0.35, 0)
	if instant then
		t.Position = tEndPosition
		b.Position = bEndPosition
		frame.Visible = true
	else
		local tweenInfo = TweenInfo.new(1, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, 1, true)
		local tweenTop = TweenService:Create(t, tweenInfo, {Position = UDim2.new(.5, 0, -.6, 0)})
		local tweenBottom = TweenService:Create(b, tweenInfo, {Position = UDim2.new(.5, 0, .6, 0)})
		frame.Visible = true
		tweenTop:Play()
		tweenBottom:Play()
		task.wait(1.35)
		tweenTop:Pause()
		tweenBottom:Pause()
	
		tweenInfo = TweenInfo.new(1, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut)
		tweenTop = TweenService:Create(t, tweenInfo, {Position = UDim2.new(.5, 0, -.35, 0)})
		tweenBottom = TweenService:Create(b, tweenInfo, {Position = UDim2.new(.5, 0, 0.35, 0)})
		tweenTop:Play()
		tweenBottom:Play()
		tweenTop.Completed:Wait()
	end
end

function openEyes()
	--does not wait for eyes to fully open before returning
	local frame = playerGui:WaitForChild("EyeCloseGui"):WaitForChild("Frame")
	local t = frame.Top
	local b = frame.Bottom
	local targetTopPosition = UDim2.new(.5, 0, -1, 0)
	--[[if t.Position == targetTopPosition then return end --don't open again if already open
	t.Position = UDim2.new(.5, 0, -.35, 0)
	b.Position = UDim2.new(.5, 0, 0.35, 0)]]
	
	local tweenInfo = TweenInfo.new(.4, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut)
	local tweenTop = TweenService:Create(t, tweenInfo, {Position = targetTopPosition})
	local tweenBottom = TweenService:Create(b, tweenInfo, {Position = UDim2.new(.5, 0, 1, 0)})
	tweenTop:Play()
	tweenBottom:Play()
end

task.spawn(function()
	while task.wait(1) do
		if not clientUtil.getGamePaused() and not clientUtil.getInLobby() and not tutorialMode and not crashed then
			--accelerate speed at a diminishing rate
			setSpeed(speed + helperFunctions.acceleration(speed))
			cleanupPastParts()
		end
	end
end)

function isNewPlayerVerticalStatusEligible(newStatus)
	--check if new status is possible
	if newStatus == "Running" then
		return not inAir or crashed --allow Running status to cancel sound effects right after crashing
	elseif newStatus == "Ascending" then
		return not inAir or (inAir and tick() - materialChangedTime < .1) --on ground or coyote time
	elseif newStatus == "Falling" then
		return inAir
	elseif newStatus == "Gliding" then
		return stamina > 0 and playerVerticalStatus == "Falling"
	elseif newStatus == "Sliding" then
		return not inAir
	end
end

function setPlayerVerticalStatus(newStatus) --Running, Ascending, Falling, Gliding, Sliding
	if playerVerticalStatus == newStatus and newStatus ~= "Running" then return end --Running allowed for beginning of new rounds
	if not isNewPlayerVerticalStatusEligible(newStatus) then 
		--print(playerVerticalStatus," to ", newStatus, "rejected", inAir, tick() - materialChangedTime)
		return --usually happens right when you crash
	end
	
	--disable current status
	if playerVerticalStatus == "Running" then
		--NA
	elseif playerVerticalStatus == "Ascending" then
		--NA
	elseif playerVerticalStatus == "Falling" then
		--NA
	elseif playerVerticalStatus == "Gliding" then
		toggleContrails(false)
		toggleVerticalVelocity(0)
	elseif playerVerticalStatus == "Sliding" then
		toggleSlidingState(false)
	end
		
	--enable new status
	playerVerticalStatus = newStatus
	if playerVerticalStatus == "Running" then
		playAnimation("Run")
	elseif playerVerticalStatus == "Ascending" then
		jumpBeginHeight = hrp.Position.Y
		local jumpVelocity = 65
		if table.find((clientUtil.PlayerData() or {}).purchasedItems or {}, 8) then
			jumpVelocity += 10
		end
		--Physics mode prevents velocity from being cancelled sometimes
		humanoid:ChangeState(Enum.HumanoidStateType.Physics) 
		setVelocityY(jumpVelocity)
		task.delay(.1, function() --wait to become airborne
			humanoid:ChangeState(Enum.HumanoidStateType.Running) 
		
			--revert if player fails to become airborne. For example down key pressed before ascent got off ground
			if playerVerticalStatus == "Ascending" and not inAir then
				handlePlayerHitTheGround()
			end
		end)
		playAnimation("Jump")
		lastHrpHeights = {} --prevent heartbeat from thinking we just apexed
	elseif playerVerticalStatus == "Falling" then
		playAnimation("Jump")
		if actionInputBeingHeld("Down") then
			toggleFastFalling(true)
		end
	elseif playerVerticalStatus == "Gliding" then
		playAnimation("Fly")
		toggleContrails(true)
		clientUtil.toggleSoundEffect(windSound, true, 1, 1)
		local glideSlope = -3
		if table.find((clientUtil.PlayerData() or {}).purchasedItems or {}, 9) then
			glideSlope = -2.5
		end
		toggleVerticalVelocity(glideSlope)
	elseif playerVerticalStatus == "Sliding" then
		toggleSlidingState(true)
	end

	if playerVerticalStatus ~= "Gliding" and playerVerticalStatus ~= "Falling" then --keep playing between falling and gliding
		clientUtil.toggleSoundEffect(windSound, false, .5, nil)
	end

	return true
end

function cancelSoundEffects()
	clientUtil.toggleSoundEffect(windSound, false, .5, nil)
	clientUtil.toggleSoundEffect(SoundService.Sliding, false, .3, nil)
end

function handlePlayerHitTheGround()
	if fastFalling then
		toggleFastFalling(false)
	end
	if actionInputBeingHeld("Down") then
		setPlayerVerticalStatus("Sliding")
	elseif actionInputBeingHeld("Up") and not onRamp and playerVerticalStatus ~= "Ascending" then 
		--jump if you glide onto ground, wait if you glide onto ramp. Ignore failed Ascent which should go to Running.
		setPlayerVerticalStatus("Ascending")
	else
		setPlayerVerticalStatus("Running")
	end
end

function handlePlayerCharAdded(player, character)
	char = character
	
	--reload the player
	hrp = char:WaitForChild("HumanoidRootPart")
	humanoid = char:WaitForChild("Humanoid")
	humanoid.WalkSpeed = 32
	
	humanoid:GetPropertyChangedSignal("FloorMaterial"):Connect(function()
		if clientUtil.getInLobby() then return end
		--ground is Plastic
		onRamp = humanoid.FloorMaterial == Enum.Material.Carpet --unique material to differentiate from other parts
		
		if inAir ~= (humanoid.FloorMaterial == Enum.Material.Air) then --going from plastic to plaster doesn't count
			inAir = humanoid.FloorMaterial == Enum.Material.Air
			materialChangedTime = tick()
			if inAir then
				if actionInputBeingHeld("Up") then
					setPlayerVerticalStatus("Ascending")
				else
					setPlayerVerticalStatus("Falling")
				end
			else --just hit the ground
				handlePlayerHitTheGround()
			end
		end
	end)
		
	hrp.Touched:Connect(function(hit)
		if hit.Name == "KillBrick" and not clientUtil.getInLobby() then
			crashedObjectName = hit.Parent.Name
			crash()
		end
	end)
		
	animTracks = {}
	preloadAnimTracks()
		
	--attach constraints
	local lv = Instance.new("LinearVelocity", hrp)
	lv.Name = "LinearVelocityY"
	local lvAttachment = Instance.new("Attachment", hrp)
	lvAttachment.WorldPosition = hrp.Position
	lv.Attachment0 = lvAttachment
	lv.VelocityConstraintMode = Enum.VelocityConstraintMode.Line
	lv.LineDirection = Vector3.new(0, 1, 0)
	lv.LineVelocity = 0 --Target velocity
	lv.MaxForce = 1e6
	lv.Enabled = false
	
	local lvZ = Instance.new("LinearVelocity", hrp)
	lvZ.Name = "LinearVelocityZ"
	local lvZAttachment = Instance.new("Attachment", hrp)
	lvZAttachment.WorldPosition = hrp.Position
	lvZ.Attachment0 = lvZAttachment
	lvZ.VelocityConstraintMode = Enum.VelocityConstraintMode.Line
	lvZ.LineDirection = Vector3.new(0, 0, 1)
	lvZ.LineVelocity = 0 --Target velocity
	lvZ.MaxForce = 1e6
	lvZ.Enabled = false
	
	local ao = Instance.new("AlignOrientation", hrp)
	ao.Name = "AlignOrientation"
	local ao0 = Instance.new("Attachment", hrp)
	ao0.WorldCFrame = hrp.CFrame
	ao.Attachment0 = ao0
	local ao1 = Instance.new("Attachment", workspace.StartAnchor)
	ao.Attachment1 = ao1
	ao1.WorldCFrame = workspace.StartAnchor.CFrame
	ao.MaxTorque = 1e6
	ao.MaxAngularVelocity = 50
	ao.Responsiveness = 100
	ao.Enabled = false
	
	local ap = Instance.new("AlignPosition", hrp)
	ap.Name = "AlignPositionX"
	local ap0 = Instance.new("Attachment", hrp)
	ap0.WorldCFrame = hrp.CFrame
	ap.Attachment0 = ap0
	local ap1 = Instance.new("Attachment", workspace.StartAnchor)
	ap.Attachment1 = ap1
	ap.ForceLimitMode = Enum.ForceLimitMode.PerAxis
	ap.MaxAxesForce = Vector3.new(1e5, 0, 0)
	ap.Responsiveness = 50
	ap.ApplyAtCenterOfMass = true
	ap.Enabled = false
	
	local apZ = Instance.new("AlignPosition", hrp)
	apZ.Name = "AlignPositionZ"
	local ap0 = Instance.new("Attachment", hrp)
	ap0.WorldCFrame = hrp.CFrame
	ap.Attachment0 = ap0
	local ap1 = Instance.new("Attachment", workspace.StartAnchor)
	apZ.Attachment1 = ap1
	apZ.ForceLimitMode = Enum.ForceLimitMode.PerAxis
	apZ.MaxAxesForce = Vector3.new(0, 0, 1e6)
	apZ.Responsiveness = 150
	apZ.ApplyAtCenterOfMass = true
	apZ.Enabled = false
	
		
	--attach contrails
	local leftHand = char:WaitForChild("LeftHand")
	local rightHand = char:WaitForChild("RightHand")
	if leftHand and rightHand then
		local cL = ReplicatedStorage.Accessories.Contrail:Clone()
		cL.Parent = leftHand
		local wL = Instance.new("Weld", cL)
		wL.Part0 = leftHand
		wL.Part1 = cL
		cL.Position = cL.Parent.Position
		local cR = ReplicatedStorage.Accessories.Contrail:Clone()
		cR.Parent = rightHand
		local wR = Instance.new("Weld", cR)
		wR.Part0 = rightHand
		wR.Part1 = cR
		cR.Position = cR.Parent.Position
	end
	
	--attach speedlines https://www.youtube.com/watch?v=De01vmQqTB8
	local speedlines = ReplicatedStorage.Speedlines:Clone()
	speedlines.Parent = hrp
		
	returnToLobby()
end

function togglePause(showGui: boolean)
	if crashed then return end --no pause during crash or race
	if tutorialMode then return end --can't toggle pause in tutorial
	clientUtil.setGamePaused(not clientUtil.getGamePaused())

	--local ddf = playerGui:WaitForChild("ScreenGui"):WaitForChild("PauseMenuFrame"):WaitForChild("DropdownFrame")
	local height = 225
	if clientUtil.getGamePaused() then
		togglePlayerFrozen(true)
		--[[if showGui and ddf.Size.Y.Offset == 0 then
			ddf:TweenSize(UDim2.new(0, 75, 0, height), Enum.EasingDirection.Out, Enum.EasingStyle.Quad, .25, true)
		end]]
	else
		togglePlayerFrozen(false)
		--[[if showGui and ddf.Size.Y.Offset > 0 then
			ddf:TweenSize(UDim2.new(0, 75, 0, 0), Enum.EasingDirection.Out, Enum.EasingStyle.Quad, .25, true)
		end]]
		if playerVerticalStatus == "Sliding" and not actionInputBeingHeld("Down") then
			setPlayerVerticalStatus("Running")
		elseif playerVerticalStatus == "Gliding" and not actionInputBeingHeld("Up") then
			setPlayerVerticalStatus("Falling")
		end
	end
	local pausedImage = playerGui:WaitForChild("ScreenGui"):WaitForChild("PausedFrame")
	pausedImage.Visible = clientUtil.getGamePaused() and showGui

	return clientUtil.getGamePaused()
end

function toggleContrails(enabled: boolean)
	for _, descendant in pairs(char:GetDescendants()) do
		if descendant.Name == "Contrail" then
			descendant.Trail.Enabled = enabled
		end
	end
end

function updateTaskProgress(taskid, qtyDone) --called from all actions that could count towards any task
	--check if player has this task assigned
	if not clientUtil.PlayerData() or not clientUtil.PlayerData().playerTasks then return end
	for i, t in clientUtil.PlayerData().playerTasks do
		if t.taskid == taskid and not t.completedTime then
			local result = ReplicatedStorage.Functions.updateTaskProgressRemote:InvokeServer(taskid, qtyDone)
			if result then
				setPlayerData(result)
			end
		end
	end
end

function setPlayerData(newData) --functions can return immediate playerData to update UI
	clientUtil.setPlayerData(newData)
	--print("revives", clientUtil.countPurchasedItems(12))
	
	if clientUtil.PlayerData().completedTutorial then
		toggleRunUIs() --show shop on login after tutorial
	end
			
	playerGui:WaitForChild("DailyTasks").Enabled = true
	local menuFrame = playerGui:WaitForChild("MenuButtonsGui"):WaitForChild("TopBarFrame"):WaitForChild("MenuFrame")
	if clientUtil.PlayerData().completedTutorial then
		menuFrame:WaitForChild("SettingsButton").Visible = true
		if clientUtil.getInLobby() then
			--menuFrame:WaitForChild("ShopButtonFrame").Visible = true
		end
	end
end

function shakeCamera(intensity)
	task.spawn(function()
		local origCFrame = camera.CFrame
		for i = 1, 10 do
			camera.CFrame = origCFrame * CFrame.new(
				math.random(-intensity, intensity)/10,
				math.random(-intensity, intensity)/10,
				0
			)
			RunService.RenderStepped:Wait()
		end
		camera.CFrame = origCFrame
	end)
end

--handle if character was already loaded
if player.Character then
	handlePlayerCharAdded(player, player.Character)
end
player.CharacterAdded:Connect(function(character)
	handlePlayerCharAdded(player, character)
end)

player.CharacterRemoving:Connect(function() --died or reset.
	if clientUtil.getGamePaused() then
		togglePause(false)
	end
	if not clientUtil.getInLobby() then
		endRun("Reset", false)
	end
end)

ReplicatedStorage.Functions.togglePause.OnInvoke = function()
	return togglePause(true)
end

ReplicatedStorage.Events.returnToLobby.Event:Connect(function()
	if not crashed and not clientUtil.getInLobby() then
		endRun("Lobby button", false)
	end
end)

function getCoins()
	coins = ReplicatedStorage.Functions.getCoins:InvokeServer()
	if coins and coins > 0 then
		showCoins()
	end
end

function showCoins()
	local moneyFrame = playerGui:WaitForChild("MenuButtonsGui"):WaitForChild("TopBarFrame"):WaitForChild("MoneyFrame")
	moneyFrame.MoneyLabel.Text = helperFunctions.abbreviateNumber(coins)
	moneyFrame.Visible = true
end

ReplicatedStorage.Events.coinsUpdate.OnClientEvent:Connect(function(newCoins)
	coins = newCoins
	showCoins()
end)

function attemptToBeginRun()
	if clientUtil.getInLobby() and not crashed and not clientUtil.getGamePaused() then
		beginRun(false)
	end
end

workspace.StartTouchPart.Touched:Connect(function(hit)
	if hit.Parent == player.Character then
		attemptToBeginRun()
	end
end)

local gameModesGui = playerGui:WaitForChild("GameModesGui")
local gameModesInnerFrame = gameModesGui:WaitForChild("GameModesFrame"):WaitForChild("GameModesInnerFrame")
local endlessModeButton = gameModesInnerFrame:WaitForChild("Endless"):WaitForChild("EndlessModeButton")
endlessModeButton.MouseButton1Click:Connect(function()
	if clientUtil.getPlayersInHostsParty() > 0 then
		clientUtil.toastCreateFullScreen("You have other players in your party!")
	else
		gameModesGui.Enabled = false
		toggleRunUIs() --show play button again in case race fails to start
		attemptToBeginRun()
	end
end)
local racingButton = gameModesInnerFrame:WaitForChild("Racing"):WaitForChild("RacingModeButton")
racingButton.MouseButton1Click:Connect(function()
	if clientUtil.getPlayersInHostsParty() == 0 then
		clientUtil.toastCreateFullScreen("Invite players to your party first")
	else
		gameModesGui.Enabled = false
		toggleRunUIs() --show play button again in case race fails to start
		ReplicatedStorage.Functions.Races.hostStartedRace:InvokeServer()
	end
end)

ReplicatedStorage.Events.Races.startRace.OnClientEvent:Connect(function(race)
	if not crashed and not clientUtil.getInLobby() then
		endRun("Race started", false)
	end
	raceMetadata = race
	gameMode = "Race"
	beginRun(false)
end)

function showRaceResults()
	local raceResultsGui = playerGui:WaitForChild("RaceResultsGui")
	local playerListFrame = raceResultsGui:WaitForChild("Frame"):WaitForChild("PlayerList")

	--clear old leaderboard
	for _, frame in playerListFrame:GetChildren() do
		if frame:IsA("Frame") then
			frame:Destroy()
		end
	end

	--populate new leaderboard
	for i, playerData in raceMetadata.racers do
		local playerFrame = ReplicatedStorage.GuiComponents.RaceResultsPlayerFrame:Clone()
		playerFrame.PlayerName.Text = playerData.player.DisplayName
		playerFrame.Hidden.Text = helperFunctions.formatNumber(i)
		playerFrame.LayoutOrder = i
		playerFrame.Parent = playerListFrame
		--playerFrame.UIGradient.Color = playerData.score >= 0 and ColorSequence.new(Color3.fromRGB(255, 255, 255)) or ColorSequence.new(Color3.fromRGB(255, 0, 0))
	end
	
	raceResultsGui.Enabled = true
	task.delay(5, function()
		raceResultsGui.Enabled = false
	end)
end

ReplicatedStorage.Events.Races.raceEnded.OnClientEvent:Connect(function(race)
	raceMetadata = race
	
	if not crashed and not clientUtil.getInLobby() then
		endRun("Race Ended", false)
	end
	
	showRaceResults()
	raceMetadata = nil
	gameMode = "Endless"
end)

ReplicatedStorage.Events.Revive.reviveApply.Event:Connect(function()
	reviveApply()
end)

ReplicatedStorage.Events.Revive.reviveDecline.Event:Connect(function()
	reviveDecline()
end)

ReplicatedStorage.Events.purchaseCompleted.OnClientEvent:Connect(function(playerData, itemId)
	setPlayerData(playerData)
	if itemId == 12 then --if revive was just purchased, attempt to use it right away
		--reviveApply()
	end
end)

ReplicatedStorage.Events.purchasePromptClosed.OnClientEvent:Connect(function(itemId)
	if itemId == 12 then
		revivePurchasePromptTime = nil
		reviveDecline()
	end
end)

function useSpeedBoost()
	if not speedBoostFrame.Visible then return end
	speedBoostsUsed += 1
	setSpeedBoostFrameVisibility()
	
	local bonus = 25000
	local newSpeed = helperFunctions.findTargetSpeedForPoints(speed, bonus)
	setSpeed(newSpeed)
	score += bonus
	SoundService.Boost:Play()
end

speedBoostFrame.SpeedBoostButton.MouseButton1Click:Connect(function()
	useSpeedBoost()
end)

getCoins() --show coins on login if any
setPlayerData(ReplicatedStorage.Functions.getPlayerData:InvokeServer())
