local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")
local ServerScriptService = game:GetService("ServerScriptService")
local TweenService = game:GetService("TweenService")
local RunService = game:GetService("RunService")
local SoundService = game:GetService("SoundService")
local serverUtil = require(ServerScriptService:WaitForChild("serverUtil"))
local helperFunctions = require(ReplicatedStorage:WaitForChild("Scripts"):WaitForChild("helperFunctions"))

local platform = script.Parent
local matchId = tonumber(platform.Name)
local sign = platform.TV.SurfaceGui.TextLabel

function startPartyTimer()
	serverUtil.setMatchStatus(matchId, "FormingParty")
	serverUtil.setMatchStartTime(matchId, tick() + 5)
end

function cancelPartyTimer()
	serverUtil.setMatchStatus(matchId, "Ready")
end

while true do
	local matchData = serverUtil.getMatch(matchId)
	if matchData.matchStatus == "Ready" then
		sign.Text = "Ready"
		local players = serverUtil.playersOnPlatform(platform)
		if #players > 0 then
			startPartyTimer()
		end
	elseif matchData.matchStatus == "FormingParty" then
		local players = serverUtil.playersOnPlatform(platform)
		if #players == 0 then
			cancelPartyTimer()
		else
			if matchData.nextMatchStartTime ~= nil then
				local secondsLeft = math.round(matchData.nextMatchStartTime - tick())
				sign.Text = secondsLeft > 0 and tostring(secondsLeft) or "Starting"
				if matchData.nextMatchStartTime <= tick() then
					local gameMode = workspace.StartingPads[tostring(matchId)]:GetAttribute("GameMode") or "Classic"
					serverUtil.startRound(matchId, players, gameMode)
					
					--teleport players in
					for _, player in pairs(players) do
						local char = player.Character
						if char then
							local hrp = char:FindFirstChild("HumanoidRootPart")
							if hrp then
								local center = serverUtil.towerCenter(matchId)
								local offset = Vector3.new(math.random(12, 15), 6, math.random(-3, 3))
								hrp:PivotTo(CFrame.new(center + offset))
							end
						end
					end
				end
			end
		end
	else
		sign.Text = "Busy"
	end
	
	task.wait(.25)
end