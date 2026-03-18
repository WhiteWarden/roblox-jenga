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
local speed = 0 --player's speed
local acceleration = 0 --acceleration of speed
local char --cache player's character object
local hrp --cache player's root part
local humanoid --cache player's humanoid
local lane = 2 --lane the player is in
local previousLane = lane --last lane the player was in
local changingLanes = nil --"Right" or "Left"
local laneWidth = 8 --width in studs of lanes
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
local inAir = false --track if player is airborne
local onRamp = false --track if player is on a ramp-tagged part
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
local materialChangedTime = tick() --last time the material under the player changed
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

function beginRun(restarting: boolean) --used to start a new run
	crashed = false --required before game pause
	if not clientUtil.getGamePaused() then
		togglePause(false) --anchors player
	else
		warn("beginRun with pause")
	end
	
	clientUtil.setInLobby(false)
	local direction = CFrame.Angles(0, math.rad(180), 0) --angle the player should face
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
	humanoid:SetStateEnabled(Enum.HumanoidStateType.FallingDown, false) --disable certain states to control animations
	humanoid:SetStateEnabled(Enum.HumanoidStateType.Ragdoll, false)
	humanoid:SetStateEnabled(Enum.HumanoidStateType.Climbing, false)
	humanoid:SetStateEnabled(Enum.HumanoidStateType.Swimming, false)
	humanoid.AutoRotate = false --direction is scripted
	char:WaitForChild("Animate").Enabled = false --disable default animations
	camera.CameraType = Enum.CameraType.Scriptable --take control of the camera
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

function endRun(endReason: string, startAnotherRun: boolean) --end the current run and cleanup
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
	hrp:PivotTo(CFrame.new(spawnCFrame.Position + Vector3.new(0, 4, 0)) * spawnCFrame.Rotation) --teleport player above spawn
	hrp.LinearVelocityZ.Enabled = false --disable physics controls
	hrp.LinearVelocityY.Enabled = false
	hrp.AlignOrientation.Enabled = false
	hrp.AlignPositionX.Enabled = false
	hrp.AlignPositionZ.Enabled = false
	humanoid.WalkSpeed = 32
	--humanoid.JumpPower = 50
	humanoid.JumpHeight = 18
	humanoid:SetStateEnabled(Enum.HumanoidStateType.FallingDown, true) --set states back to defaults
	humanoid:SetStateEnabled(Enum.HumanoidStateType.Ragdoll, true)
	humanoid:SetStateEnabled(Enum.HumanoidStateType.Climbing, true)
	humanoid:SetStateEnabled(Enum.HumanoidStateType.Swimming, true)
	humanoid.AutoRotate = true --let player move normally
	char:WaitForChild("Animate").Enabled = true
	toggleCameraConnection(false) --cleanup camera connection
	camera.CameraType = Enum.CameraType.Custom --back to default
	camera.CameraSubject = humanoid
	crashed = false
	tutorialMode = false
	if clientUtil.getGamePaused() then
		togglePause(true)
	end
	toggleRunUIs()
end

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

function setSpeed(newAmount) --apply acceleration 
	local med = 160
	local fast = 250
	if speed == startingSpeed then --update the music type based on speed
		clientUtil.setMusicSpeedLevel("Slow")
	elseif speed < med and newAmount >= med then
		clientUtil.setMusicSpeedLevel("Med")
	elseif speed < fast and newAmount >= fast then
		clientUtil.setMusicSpeedLevel("Fast")
	end
	speed = newAmount
	hrp.LinearVelocityZ.LineVelocity = speed --set constant forward velocity
	hrp.AlignPositionX.Responsiveness = speed --set how quickly you move side to side
	setSpeedBoostFrameVisibility()
end

function handleCollectibleTouched(collectible: Model, partName: string?) --apply effects when a collectible item is touched
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

function updatePlayerCollisionGroup() --should be called when you start/stop sliding/changing lanes. These control what types of obstacles the player can currently hit
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

function setPlayerCollisionGroup(group)
	if hrp.CollisionGroup ~= group then --only change collision group if necessary
		helperFunctions.setCollisionGroup(char, group)
	end
end

function currentLaneX() --get the x coordinate of the current lane's center
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
	if addAmount < 0 and table.find((clientUtil.PlayerData() or {}).purchasedItems or {}, 5) then --check if player has item 5
		addAmount *= .8 --lower stamina drain
	end
	
	local previousStamina = stamina
	stamina = math.clamp(stamina + addAmount, 0, maxStamina) --add stamina within limits
	
	local yellowThreshold = .4 * maxStamina
	local redThreshold = .2 * maxStamina
	
	if stamina > previousStamina then --show yellow/red border around screen as stamina gets dangerously low
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
	
	if clientUtil.getInLobby() or not hrp then return end --ignore if player is respawning
		
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
				
		--check if jump apex has been reached by checking the last few hights that were recorded
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
		
		--track previous heights to check apex with
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
		
		if math.abs(differenceSideways) > .1 and laneChangeStartedCFrame then --if we have distance to move and our starting position was recorded
			local totalX = math.abs(currentLaneX() - laneChangeStartedCFrame.Position.X) --the total amount of movement that needed to be made for this lane change
			local alpha = math.clamp((currentLaneX() - hrp.Position.X) / totalX, -1, 1)  --how far through the movement we are so far
			
			--adjust facing angle while changing lanes
			if playerVerticalStatus == "Gliding" then
				directionZ += math.rad(math.sin(alpha * math.pi) * 30) --roll while flying
			else
				directionY += math.rad(math.sin(alpha * math.pi) * 30) --interpolate with sine wave up to max angle
			end
		end
		
		hrp.AlignOrientation.Attachment1.CFrame = CFrame.Angles(0, directionY, directionZ) --move players orientation towards this angle
		
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
	end

	makePassedPartsInvisible()
end)

function actionInputBeingHeld(action) --check if the input for a particular action is being held
	for _, i in activeInputs do
		if i.action == action then
			return i
		end
	end
end

function clearOppositeActiveInputs(action) --clears the cache of active inputs that are no longer valid
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
			elseif entry.action == "Up" then --handle up input starting or stopping
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
		hrp.Speedlines.ParticleEmitter.Enabled = speed > minSpeed and not crashed and not clientUtil.getInLobby() and not clientUtil.getGamePaused() --show speed lines at high speeds
		local offset = speed > maxSpeed and 8 or math.map(speed, minSpeed, maxSpeed, 3, 8) --can go from about 3 to 8 to control how intense the lines look
		hrp.Speedlines:PivotTo(CFrame.new(camera.CFrame.Position + camera.CFrame.LookVector * offset) * camera.CFrame.Rotation) --place the speed line emitter in front of player's camera
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

function toggleCameraConnection(enabled) --cached connection to help move the camera every frame during a run
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

function getLaneOfPosition(pos: Vector3) --check what lane the given position is in
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

function reviveApply() --let the player use a revive
	if not waitForReviveDecisionStartedTime or clientUtil.getInLobby() then return end
	revivePurchasePromptTime = nil
	
	--if player has revives, consume one
	if table.find((clientUtil.PlayerData() or {}).purchasedItems or {}, 12) then --item 12 is a revive
		waitForReviveDecisionStartedTime = nil

		local consumed = ReplicatedStorage.Functions.consumeItem:InvokeServer(12) --this must be verified by the server
		if consumed then
			revivedTime = tick()
			crashed = false
			revivesUsed += 1
			
			local reviveFrame = playerGui:WaitForChild("ScreenGui"):WaitForChild("ReviveFrame")
			reviveFrame.Visible = false
			
			hrp.LinearVelocityZ.Enabled = true --re-enable physics controls to start moving again
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
				revivedTime = nil --reset after a delay
			end)
		else
			reviveDecline() --last resort fail if couldn't consume item
		end
	else
		revivePurchasePromptTime = tick()
		MarketplaceService:PromptProductPurchase(player, 3538063996) --prompt a revive purchase if they have none	
	end
end

function reviveDecline() --handle player deciding not to use a revive
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
	hrp.LinearVelocityZ.Enabled = false --disable physics controls
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
		progress:TweenSize(UDim2.new(0, 0, 0, 3), Enum.EasingDirection.Out, Enum.EasingStyle.Linear, reviveDesisionTime) --drain time left bar at a constant rate

		task.delay(reviveDesisionTime, function()
			if not revivePurchasePromptTime then
				reviveDecline() --decline if player didn't make a choice in time
			end
		end)
	end
end

function checkIfPlayerCrashed(delta)
	if crashed then return end
	
	local overlapParams = OverlapParams.new()
	local instances = {}
	--list of collidable base parts (no meshes used). Ignore parts with noCrash tag like ramps unless I stop.
	for _, obstaclePart in workspace.PathParts:GetDescendants() do 
		if obstaclePart:IsA("BasePart") and
			not (hrp.Velocity.Z > 10 and CollectionService:HasTag(obstaclePart, "noCrash")) then
			table.insert(instances, obstaclePart)
		end
	end
	overlapParams.FilterDescendantsInstances = instances --only these parts are checked
	overlapParams.FilterType = Enum.RaycastFilterType.Include
	overlapParams.RespectCanCollide = true --ignore parts the player can't collide with right now
	overlapParams.CollisionGroup = hrp.CollisionGroup
	
	local distance = speed * delta + 2 --buffer
	local boxSize = Vector3.new(2, 2, distance) --size of area to check
	local boxCFrame = CFrame.new(hrp.Position + Vector3.new(0, 0, boxSize.Z / 2)) --use position and size to create the CFrame
	local parts = workspace:GetPartBoundsInBox(
		boxCFrame,
		boxSize,
		overlapParams
	) --check for eligible parts in the specified area
	
	if #parts > 0 then
		if parts[1].Parent.Name == "Bush" and playerVerticalStatus == "Ascending" then
			parts[1].CanCollide = false
			return
		end
		
		--check for held lane changes
		local diverting = false
				
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

function isPartObstacle(part) --check parents of part to see if it's a descendant of PathParts
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
	for _, value in workspace.PathParts:GetChildren() do table.insert(instances, value) end --get a list of current path parts
	overlapParams.FilterDescendantsInstances = instances
	overlapParams.FilterType = Enum.RaycastFilterType.Include  --only check these parts in the list
	overlapParams.RespectCanCollide = true --ignore parts the player can't collide with right now
	overlapParams.CollisionGroup = hrp.CollisionGroup
	overlapParams.MaxParts = 1 --I only care if one was found or not
	local x = (right and -1 or 1) * laneWidth
	local z = (laneWidth / 2 + 1) / 2 --center 2.5 studs ahead with 5 stud length
	local diagOffset = Vector3.new(x, 0, z)
	local cf = CFrame.new(hrp.Position + diagOffset) --rotation doesn't matter
	local size = Vector3.new(laneWidth - 2, 2, laneWidth / 2 + 1) --if you look ahead to prevent hitting a bush right after changing lanes, you also can't get onto low ramps
	local parts = workspace:GetPartBoundsInBox(cf, size, overlapParams) --check for parts using this CFrame and size
	return #parts == 0 --just check if a part was found or not
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
		laneChangeStartedCFrame = hrp.CFrame --record where the player started this movement
		alignPlayerToLane()
	elseif lane > 1 and not right then
		lane -= 1
		laneChangeStartedCFrame = hrp.CFrame
		alignPlayerToLane()
	end
end

function alignPlayerToLane() --use AlignPosition to move player towards the center of the lane they should be in
	hrp.AlignPositionX.Attachment1.Position = Vector3.new(currentLaneX(), 0, 0)
end

function getSwipeDirection(input) --for touch and gamepad to detect if the movement is enough in a particular direction
	local delta = input.UserInputType == Enum.UserInputType.Touch and input.delta or input.position --get distance moved so far
	if input.UserInputType == Enum.UserInputType.Gamepad1 then
		delta = Vector3.new(delta.X, -delta.Y, 0) --gamepad Y is opposite of touch
	end
	local MIN_SWIPE_DISTANCE = input.UserInputType == Enum.UserInputType.Touch and 1 or .8 --some sort of screen scale for touch. gamepad max is 1
	local DOMINANCE = 1.5 -- X must be 1.5x stronger than Y to ignore diagonals

	-- Must be long enough
	if delta.Magnitude < MIN_SWIPE_DISTANCE then
		return nil
	end

	if math.abs(delta.X) > math.abs(delta.Y) * DOMINANCE then --check if the swipe is dominant in one particular direction
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
end

function toggleFastFalling(enabled) --toggle if player should be falling more quickly
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

function downKeyPressed() --handle the down key being pressed
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
	overlapParams.FilterType = Enum.RaycastFilterType.Include --only look through these parts
	overlapParams.RespectCanCollide = false --include parts player can't hit
	local parts = workspace:GetPartBoundsInBox(hrp.CFrame, hrp.Size, overlapParams) --get a list of parts at this CFrame within the size
	for _, part in parts do
		if part.Name == partName then
			return true --player is inside this part's bounding box
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
			task.spawn(function() --spawn a task so it doesn't block the main thread. This is to force the player to keep trying until they complete the glide by holding the jump key
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

	if isNewPlayerVerticalStatusEligible("Ascending") then --jump if eligible
		return setPlayerVerticalStatus("Ascending")
	elseif playerVerticalStatus == "Falling" then --start gliding if player was falling
		return setPlayerVerticalStatus("Gliding")
	end
end

function handleJumpKeyReleased() --stop gliding when key is released
	if playerVerticalStatus == "Gliding" then
		return setPlayerVerticalStatus("Falling")
	end
end

function areActionsOpposite(a, b) --check if these two inputs are opposites of each other
	if (a == "Up" and b == "Down") or (a == "Down" and b == "Up")
		or (a == "Right" and b == "Left") or (a == "Left" and b == "Right") then
		return true
	end
end

function getActionOpposite(a) --determine the opposite action
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

function addInputToQueue(action, begin) --queue up inputs so they are handled in order once they become eligible to carry out
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
	end
	
	if not crashed and hrp and not clientUtil.getGamePaused()
		and not (tutorialMode and requiredControl == nil and begin) --don't start input unless it's required
	then
		table.insert(inputQueue, {action = action, begin = begin, z = hrp.Position.Z, time = tick()}) --track metadata about the input
	end
end

UserInputService.InputBegan:Connect(function(input, gameProcessedEvent)
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
				
				if swipeDirection == Enum.SwipeDirection.Right then --record the input action once it has moved far enough to be recognised
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
	
	if activeInputs[input] and activeInputs[input].action then --add the end of this keypress to the queue to be handled
		addInputToQueue(activeInputs[input].action, false)
	end
	activeInputs[input] = nil --cleanup active input tracking
end)

local function handleSpaceKeyInput(actionName, inputState, inputObject) --this is used instead of the default handling
	if actionName == "BlockSpaceToJump" then
		if clientUtil.getInLobby() then
			return Enum.ContextActionResult.Pass --let the game handle it normally
		elseif inputState == Enum.UserInputState.Begin then
			activeInputs[actionName] = {}
			addInputToQueue("Up", true)
			activeInputs[actionName].action = "Up"
		elseif inputState == Enum.UserInputState.End or inputState == Enum.UserInputState.Cancel then --when the spacebar is being released
			if activeInputs[actionName] and activeInputs[actionName].action then
				addInputToQueue(activeInputs[actionName].action, false)
			end
			activeInputs[actionName] = nil
		end
		return Enum.ContextActionResult.Sink --consume the input to prevent default processing
	end
end

ContextActionService:BindActionAtPriority("BlockSpaceToJump", handleSpaceKeyInput, false, Enum.ContextActionPriority.High.Value + 1, Enum.KeyCode.Space) --override the default action when pressing space

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
				ReplicatedStorage.Functions.playerCompletedTutorial:InvokeServer() --tell the server that we finished
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
					track:AdjustSpeed(0) --pause anim before it ends
				end
			end)
		end
	end
end

function getOrLoadTrack(animation)
	while not humanoid do task.wait(.1) end --wait if player is respawning
	if animTracks[animation] then return animTracks[animation] end --use cached version if there is one
	local anim = Instance.new("Animation")
	anim.AnimationId = anims[animation]
	local track = humanoid:LoadAnimation(anim) --create an animation track reference and save it for later
	animTracks[animation] = track
	return track
end

function preloadAnimTracks() --pre-load the tracks so they can be started on demand
	for k, v in pairs(anims) do
		getOrLoadTrack(k)
	end
end

function closeEyes(instant: boolean) --wait for eyes to close before returning unless it's set to instant
	local frame = playerGui:WaitForChild("EyeCloseGui"):WaitForChild("Frame")
	local t = frame.Top
	local b = frame.Bottom
	t.Position = UDim2.new(.5, 0, -1, 0) --starting positions of top and bottom half
	b.Position = UDim2.new(.5, 0, 1, 0)
	local tEndPosition = UDim2.new(.5, 0, -.35, 0) --where they will tween to
	local bEndPosition = UDim2.new(.5, 0, 0.35, 0)
	if instant then
		t.Position = tEndPosition
		b.Position = bEndPosition
		frame.Visible = true
	else
		local tweenInfo = TweenInfo.new(1, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, 1, true)
		local tweenTop = TweenService:Create(t, tweenInfo, {Position = UDim2.new(.5, 0, -.6, 0)})
		local tweenBottom = TweenService:Create(b, tweenInfo, {Position = UDim2.new(.5, 0, .6, 0)}) --tween the frames to their new position using a sine function at the beginning and end. Reverse is enabled so that they begin to bounce back.
		frame.Visible = true
		tweenTop:Play()
		tweenBottom:Play()
		task.wait(1.35)
		tweenTop:Pause() --stop this tween and start the next one as they are bouncing back
		tweenBottom:Pause()
	
		tweenInfo = TweenInfo.new(1, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut)
		tweenTop = TweenService:Create(t, tweenInfo, {Position = UDim2.new(.5, 0, -.35, 0)}) --tween the frames to their next position
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
	
	local tweenInfo = TweenInfo.new(.4, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut)
	local tweenTop = TweenService:Create(t, tweenInfo, {Position = targetTopPosition})
	local tweenBottom = TweenService:Create(b, tweenInfo, {Position = UDim2.new(.5, 0, 1, 0)}) --similar to closing except they open in one smooth motion
	tweenTop:Play()
	tweenBottom:Play()
end

task.spawn(function() --spawn a constant loop that can perform needed actions 
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
			humanoid:ChangeState(Enum.HumanoidStateType.Running)  --set back to default after a short delay
		
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
	
	humanoid:GetPropertyChangedSignal("FloorMaterial"):Connect(function() --check whenever the material the player is standing on changes
		if clientUtil.getInLobby() then return end
		--ground is Plastic
		onRamp = humanoid.FloorMaterial == Enum.Material.Carpet --unique material to differentiate from other parts
		
		if inAir ~= (humanoid.FloorMaterial == Enum.Material.Air) then --going from plastic to plaster doesn't count
			inAir = humanoid.FloorMaterial == Enum.Material.Air --check if the player is in the air
			materialChangedTime = tick() --track when it changed
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
		
	hrp.Touched:Connect(function(hit) --check whenever anything touches the player
		if hit.Name == "KillBrick" and not clientUtil.getInLobby() then
			crashedObjectName = hit.Parent.Name
			crash()
		end
	end)
		
	animTracks = {}
	preloadAnimTracks()
		
	--attach constraints
	local lv = Instance.new("LinearVelocity", hrp) --this is used for gliding down at a constant rate
	lv.Name = "LinearVelocityY"
	local lvAttachment = Instance.new("Attachment", hrp)
	lvAttachment.WorldPosition = hrp.Position
	lv.Attachment0 = lvAttachment
	lv.VelocityConstraintMode = Enum.VelocityConstraintMode.Line --this only applies to one axis so it doesn't conflict with the other LinearVelocity objects
	lv.LineDirection = Vector3.new(0, 1, 0)
	lv.LineVelocity = 0 --Target velocity
	lv.MaxForce = 1e6 --needs to be strong to go up ramps etc.
	lv.Enabled = false --only enabled when needed during a run
	
	local lvZ = Instance.new("LinearVelocity", hrp) --this will keep the player moving forward at a constant rate
	lvZ.Name = "LinearVelocityZ"
	local lvZAttachment = Instance.new("Attachment", hrp)
	lvZAttachment.WorldPosition = hrp.Position
	lvZ.Attachment0 = lvZAttachment
	lvZ.VelocityConstraintMode = Enum.VelocityConstraintMode.Line
	lvZ.LineDirection = Vector3.new(0, 0, 1)
	lvZ.LineVelocity = 0 --Target velocity
	lvZ.MaxForce = 1e6
	lvZ.Enabled = false
	
	local ao = Instance.new("AlignOrientation", hrp) --this rotates the player towards the direction they should be facing
	ao.Name = "AlignOrientation"
	local ao0 = Instance.new("Attachment", hrp)
	ao0.WorldCFrame = hrp.CFrame
	ao.Attachment0 = ao0
	local ao1 = Instance.new("Attachment", workspace.StartAnchor) --direction is in relation to this anchored part
	ao.Attachment1 = ao1
	ao1.WorldCFrame = workspace.StartAnchor.CFrame --orientation is in reference to the world
	ao.MaxTorque = 1e6
	ao.MaxAngularVelocity = 50
	ao.Responsiveness = 100 --this affects how quickly they move
	ao.Enabled = false
	
	local ap = Instance.new("AlignPosition", hrp) --this moves the player to the lane they should be in
	ap.Name = "AlignPositionX"
	local ap0 = Instance.new("Attachment", hrp)
	ap0.WorldCFrame = hrp.CFrame
	ap.Attachment0 = ap0
	local ap1 = Instance.new("Attachment", workspace.StartAnchor) --in relation to anchored part
	ap.Attachment1 = ap1
	ap.ForceLimitMode = Enum.ForceLimitMode.PerAxis
	ap.MaxAxesForce = Vector3.new(1e5, 0, 0) --only applies to horizontal movement
	ap.Responsiveness = 50
	ap.ApplyAtCenterOfMass = true --prevents rotational forces
	ap.Enabled = false
	
	local apZ = Instance.new("AlignPosition", hrp) --this moves the player forward
	apZ.Name = "AlignPositionZ"
	local ap0 = Instance.new("Attachment", hrp)
	ap0.WorldCFrame = hrp.CFrame
	ap.Attachment0 = ap0
	local ap1 = Instance.new("Attachment", workspace.StartAnchor)
	apZ.Attachment1 = ap1
	apZ.ForceLimitMode = Enum.ForceLimitMode.PerAxis
	apZ.MaxAxesForce = Vector3.new(0, 0, 1e6) --lots of force to overcome and friction with the ground or ramps
	apZ.Responsiveness = 150
	apZ.ApplyAtCenterOfMass = true
	apZ.Enabled = false
	
		
	--attach contrails using attachments on the hands
	local leftHand = char:WaitForChild("LeftHand")
	local rightHand = char:WaitForChild("RightHand")
	if leftHand and rightHand then
		local cL = ReplicatedStorage.Accessories.Contrail:Clone()
		cL.Parent = leftHand
		local wL = Instance.new("Weld", cL) --welds make sure they remain with the hands
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

	local height = 225
	if clientUtil.getGamePaused() then
		togglePlayerFrozen(true)
	else
		togglePlayerFrozen(false)
		if playerVerticalStatus == "Sliding" and not actionInputBeingHeld("Down") then --go back to running if they were sliding when pause started
			setPlayerVerticalStatus("Running")
		elseif playerVerticalStatus == "Gliding" and not actionInputBeingHeld("Up") then  --go back to falling if they were gliding
			setPlayerVerticalStatus("Falling")
		end
	end
	local pausedImage = playerGui:WaitForChild("ScreenGui"):WaitForChild("PausedFrame")
	pausedImage.Visible = clientUtil.getGamePaused() and showGui

	return clientUtil.getGamePaused()
end

function toggleContrails(enabled: boolean)
	for _, descendant in pairs(char:GetDescendants()) do --search the character for the contrail objects
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
			local result = ReplicatedStorage.Functions.updateTaskProgressRemote:InvokeServer(taskid, qtyDone) --tell the server the task finished
			if result then
				setPlayerData(result) --record the updated data if this change was approved
			end
		end
	end
end

function setPlayerData(newData) --functions can return immediate playerData to update UI
	clientUtil.setPlayerData(newData)
	
	if clientUtil.PlayerData().completedTutorial then
		toggleRunUIs() --show shop on login after tutorial
	end
			
	playerGui:WaitForChild("DailyTasks").Enabled = true
	local menuFrame = playerGui:WaitForChild("MenuButtonsGui"):WaitForChild("TopBarFrame"):WaitForChild("MenuFrame")
	if clientUtil.PlayerData().completedTutorial then
		menuFrame:WaitForChild("SettingsButton").Visible = true
	end
end

function shakeCamera(intensity)
	task.spawn(function() --don't block the process that called this
		local origCFrame = camera.CFrame
		for i = 1, 10 do --number of shakes to do
			camera.CFrame = origCFrame * CFrame.new(
				math.random(-intensity, intensity)/10,
				math.random(-intensity, intensity)/10,
				0
			) --randomize the angle based on the intensity
			RunService.RenderStepped:Wait() --make one change per frame
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

ReplicatedStorage.Functions.togglePause.OnInvoke = function() --listen for pause button being pressed in GUI
	return togglePause(true)
end

ReplicatedStorage.Events.returnToLobby.Event:Connect(function() --listen for reset button being pressed in GUI
	if not crashed and not clientUtil.getInLobby() then
		endRun("Lobby button", false)
	end
end)

function getCoins()
	coins = ReplicatedStorage.Functions.getCoins:InvokeServer() --request coins from server
	if coins and coins > 0 then
		showCoins()
	end
end

function showCoins()
	local moneyFrame = playerGui:WaitForChild("MenuButtonsGui"):WaitForChild("TopBarFrame"):WaitForChild("MoneyFrame")
	moneyFrame.MoneyLabel.Text = helperFunctions.abbreviateNumber(coins) --format the number as a string
	moneyFrame.Visible = true
end

ReplicatedStorage.Events.coinsUpdate.OnClientEvent:Connect(function(newCoins) --listen for server updating coins
	coins = newCoins
	showCoins()
end)

function attemptToBeginRun()
	if clientUtil.getInLobby() and not crashed and not clientUtil.getGamePaused() then
		beginRun(false)
	end
end

workspace.StartTouchPart.Touched:Connect(function(hit) --listen for player touching the starting line
	if hit.Parent == player.Character then
		attemptToBeginRun()
	end
end)

local gameModesGui = playerGui:WaitForChild("GameModesGui")
local gameModesInnerFrame = gameModesGui:WaitForChild("GameModesFrame"):WaitForChild("GameModesInnerFrame")
local endlessModeButton = gameModesInnerFrame:WaitForChild("Endless"):WaitForChild("EndlessModeButton")
endlessModeButton.MouseButton1Click:Connect(function() --listen for GUI button clicked
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
		local playerFrame = ReplicatedStorage.GuiComponents.RaceResultsPlayerFrame:Clone() --copy the frame template
		playerFrame.PlayerName.Text = playerData.player.DisplayName
		playerFrame.Hidden.Text = helperFunctions.formatNumber(i)
		playerFrame.LayoutOrder = i --sort the order they are displayed in
		playerFrame.Parent = playerListFrame
	end
	
	raceResultsGui.Enabled = true
	task.delay(5, function()
		raceResultsGui.Enabled = false --hide it again after a delay
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

ReplicatedStorage.Events.purchasePromptClosed.OnClientEvent:Connect(function(itemId) --listen for event from server
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
setPlayerData(ReplicatedStorage.Functions.getPlayerData:InvokeServer()) --initial load of player data so we have it available locally
