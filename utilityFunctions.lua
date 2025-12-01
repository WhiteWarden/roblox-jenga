local utilityFunctions = {}
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")
local player = Players.LocalPlayer
local suffixes = {"K", "M", "B", "T", "Q"} --for abbreviating large numbers
local shopItems = { --currency can be Money or Robux. 
	--Add item IDs to PurchaseHandler script
	--To add a new item to the shop: add shopId here
	{id = 1, name="Wood", money=0, image="rbxassetid://6742484112"},
	{id = 2, name="Classic Studs", money=100, image="rbxassetid://6927295847"},
	{id = 3, name="Bread", money=200, image="rbxassetid://13161332855"},
	{id = 4, name="Sushi", money=1000, image="rbxassetid://1974497111"},
	{id = 3453337777, name="Banana", robux=10, image="rbxassetid://87765768134985"},
	{id = 3453149053, name="Stapler", robux=20, image="rbxassetid://110031942401566"},
	{id = 3453334660, name="Cheese", robux=50, image="rbxassetid://138749913853976"},
	{id = 3453154115, name="Fish", robux=50, image="rbxassetid://9400392150"},
	{id = 3453155317, name="Penguin", robux=50, image="rbxassetid://73241308992987"},
	{id = 3453069658, name="Rainbow", robux=100, image="rbxassetid://5265029984"},
	{id = 3453144574, name="Brainrot", robux=150, image="rbxassetid://95934746711773"},
	{id = 3453329211, name="Stack of Cash", robux=250, image="rbxassetid://118283496333573"},
		
}

local titles = { --can be for money, robux, locked, or free. locked are awarded by scripts
	{id = 1, display="Beginner", descr="Noob 😭", color = "#FFFFFF"},
	{id = 3457801457, display="⭐ Admin", robux=500, descr = "Permanent Admin!", color = "#FFFFFF"},
	{id = 3, display="⭐ Admin", money=200, descr="Temporary Admin until you leave.", color = "#F5DD08"},
	--{id = 4, display="⭐ Admin", money=1000, descr="Temporary Admin for 1 week.", color = "#F5DD08"},
	{id = 5, display="Novice", locked=true, descr="10 wins", color = "#FF7F27"},
	{id = 6, display="Experienced", locked=true, descr="25 wins", color = "#0598D6"},
	{id = 7, display="Pro", locked=true, descr="50 wins", color = "#D0C723"},
	{id = 8, display="Avid", locked=true, descr="75 wins", color = "#1C823A"},
	{id = 9, display="Super", locked=true, descr="100 wins", color = "#D80D15"},
	{id = 10, display="Powerful", locked=true, descr="200 wins", color = "#6A0E6B"},
	{id = 11, display="🏆 Master", locked=true, descr="500 wins", color = "#FFFFFF"},
	{id = 12, display="Not a beginner", money=50, descr="Not a noob anymore", color = "#FFFFFF"},
	{id = 13, display="Ultra", locked=true, descr="1K wins", color = "#7A297B"},
}

--add calculated flags to titles
for _, title in titles do
	title.free = (title.robux or title.money or 0) == 0 and not title.locked
end

function utilityFunctions.titles()
	return titles
end

function utilityFunctions.getTitleMeta(titleId)
	for _, title in titles do
		if title.id == titleId then
			return title
		end
	end
end

function utilityFunctions.shopItems()
	return shopItems
end

function utilityFunctions.getShopItemMeta(itemId)
	for _, item in shopItems do
		if item.id == itemId then
			return item
		end
	end
end

function utilityFunctions.NthValue(min, max, n, total)
	--returns value between min and max that is Nth of the total available
	return math.round(min + (n - 1) * (max - min) / (total - 1))
end

function utilityFunctions.abbreviateNumber(number)
	if not number then
		return 0
	end
	if number == 0 then
		return 0
	end

	--check for powers of 10 and add the appropriate suffix
	local finalNr = math.floor((((number/1000^(math.floor(math.log(number, 1e3))))*100)+0.5)) /100 .. (suffixes[math.floor(math.log(number, 1e3))] or "")
	return finalNr
end

function utilityFunctions.toastCreate(message)
	local playerGui = player:WaitForChild("PlayerGui")
	local toast = playerGui.ToastGui.ToastFrame:Clone()
	toast.Parent = playerGui.ToastGui.ToastAreaFrame
	toast.ToastLabel.Text = message
	toast.Visible = true
	AnimateToast(toast, "open")
	task.wait(5)
	pcall(function()  --in case player reset while toast was open
		AnimateToast(toast, "close")
	end)
end

function AnimateToast(toast, anim) --example script for opening and closing toasts
	local tweenInfo = TweenInfo.new(0.25, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
	local open = anim == "open"

	local frameParams = {}
	local txtParams = {TextTransparency = open and 0 or 1, BackgroundTransparency = open and 0.5 or 1}

	--game.TweenService:Create(toast, tweenInfo, {Size = open and UDim2.new(0, 326, 0, 58) or UDim2.new(0, 80, 0, 58), BackgroundTransparency = open and 0.4 or 1	}):Play()

	--game.TweenService:Create(toast, tweenInfo, frameParams):Play()
	game.TweenService:Create(toast.ToastLabel, tweenInfo, txtParams):Play()
	
	toast = not open and game.Debris:AddItem(toast, 0.25)
end

function utilityFunctions.shuffle(t)
	for i = #t, 1, -1 do
		local j = math.random(i)
		t[i], t[j] = t[j], t[i]
	end
end

function utilityFunctions.getMonthAndDay()
	if false then
		return 12, 4 -- for testing
	end
	local today = os.date("*t", os.time())
	return today.month, today.day
end

return utilityFunctions
