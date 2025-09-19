-- Services
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")

-- Modules
local ProfileService = require(ReplicatedStorage.Packages.ProfileService)
local ReplicaService = require(ReplicatedStorage.ReplicaService.ReplicaService)
local PlayerProfile = require(script.PlayerProfile)
local Promise = require(ReplicatedStorage.Packages.Promise)

local RemoteEvents = ReplicatedStorage.Remotes:WaitForChild("Events")
local RemoteFunctions = ReplicatedStorage.Remotes:WaitForChild("Function")

--======================================================================================================--
-- DataManager Configuration
--======================================================================================================--
local DataManager = {}
DataManager.DataName = game["Run Service"]:IsStudio() and "Studio_Version_9" or "Version_1"
DataManager.DataTemplate = require(script.Template)
DataManager.AutoSaveLoops = {}

local ProfileStore = ProfileService.GetProfileStore(DataManager.DataName, DataManager.DataTemplate)
local Profiles = {}        -- ProfileService objects per player
local PlayerReplicas = {}  -- ReplicaService objects per player
local PlayerDataToken = ReplicaService.NewClassToken("PlayerData")

--======================================================================================================--
-- Private Functions
--======================================================================================================--

function DataManager:GetReplica(player)
	return PlayerReplicas[player]
end

local function createValue(className, name, initialValue, parent)
	local valueObj = Instance.new(className)
	valueObj.Name = name
	valueObj.Value = initialValue
	valueObj.Parent = parent
	return valueObj
end

local function setupLeaderstats(player)
	local replica = DataManager:GetReplica(player)
	if not replica then return end
	-- Initialize values if missing
	replica:SetValue({"Level"}, replica.Data.Level or 0)
	replica:SetValue({"Exp"}, replica.Data.Exp or 0)
	replica:SetValue({"Coins"}, replica.Data.Coins or 0)
	replica:SetValue({"Inventory"}, replica.Data.Inventory or {})

	local statsFolder = Instance.new("Folder")
	statsFolder.Name = "PlayerStats"
	statsFolder.Parent = player

	local leaderstats = Instance.new("Folder")
	leaderstats.Name = "leaderstats"
	leaderstats.Parent = player
	
	local Items = Instance.new("Folder")
	Items.Name = "Items"
	Items.Parent = player
	

	

	local level = createValue("IntValue", "Level", replica.Data.Level, statsFolder)
	local exp = createValue("IntValue", "Exp", replica.Data.Exp, statsFolder)
	local coins = createValue("IntValue", "Coins", replica.Data.Coins, leaderstats)
	
	task.spawn(function()
		while task.wait(.1) do
				level.Value = replica.Data.Level 
		exp.Value = replica.Data.Exp 
		coins.Value = replica.Data.Coins 
		end
	

	end)

	return statsFolder
end

--======================================================================================================--
-- Inventory Functions
--======================================================================================================--

function DataManager:SaveInventory(player, profileData)
	profileData = profileData or Profiles[player].Profile.Data
	if not profileData then return end

	profileData.Inventory = {}

	for _, container in ipairs({player:FindFirstChild("Backpack"), player.Character}) do
		if container then
			for _, tool in ipairs(container:GetChildren()) do
				if tool:IsA("Tool") then
					local itemData = {
						Name = tool.Name,
						Type = tool:GetAttribute("Type") or "Unknown",
						Attributes = tool:GetAttributes(),
						Tags = tool:GetTags()
					}
					local index = #profileData.Inventory + 1
					profileData.Inventory[index] = itemData

					local replica =  DataManager:GetReplica(player)
					if replica then
						replica:SetValue({"Inventory", index}, itemData)
					end
				end
			end
		end
	end
end

function DataManager:LoadInventory(player, profileData)
	if not profileData.Inventory then return end
	local backpack = player:WaitForChild("Backpack")

	for _, itemData in ipairs(profileData.Inventory) do
		local template
		for _, v in ipairs(ReplicatedStorage.Assets.Models:GetDescendants()) do
			if v.Name == itemData.Name then
				template = v
				break
			end
		end

		if template and template:IsA("Tool") then
			local tool = template:Clone()
			for k, v in pairs(itemData.Attributes or {}) do tool:SetAttribute(k, v) end
			for _, tag in ipairs(itemData.Tags or {}) do tool:AddTag(tag) end
			tool.Parent = backpack
		else
			warn("Missing template for item:", itemData.Name)
		end
	end
end

function DataManager:ClearInventory(player)
	local profile = Profiles[player]
	if profile and profile.Data then
		table.clear(profile.Data.Inventory)
		local replica =  DataManager:GetReplica(player)
		if replica then pcall(function() replica:SetValue({"Inventory"}, profile.Data.Inventory) end) end
	end

	local function clearTools(container)
		if container then
			for _, tool in ipairs(container:GetChildren()) do
				if tool:IsA("Tool") then tool:Destroy() end
			end
		end
	end

	clearTools(player:FindFirstChild("Backpack"))
	clearTools(player.Character)
end

--======================================================================================================--
-- Player Management
--======================================================================================================--

function DataManager:PlayerAdded(player)
	local profile = ProfileStore:LoadProfileAsync("Data_" .. player.UserId, "ForceLoad")
	if not profile then player:Kick("Failed to load your data.") return end

	profile:AddUserId(player.UserId)
	profile:Reconcile()
	profile:ListenToRelease(function()
		local r = PlayerReplicas[player]
		if r then pcall(function() r:Destroy() end) PlayerReplicas[player] = nil end
		Profiles[player] = nil
		player:Kick("Your data was protected. Rejoin.")
	end)

	if not player:IsDescendantOf(Players) then profile:Release() return end

	if profile.Data and player:IsDescendantOf(Players) == true then
		player:SetAttribute("PROFILE_LOADED", true)
		local player_profile = {
			Profile = profile,
			Replica = ReplicaService.NewReplica({
				ClassToken = PlayerDataToken,
				Tags = {Player = player},
				Data = profile.Data,
				Replication = "All",
			}),
			_player = player
			}
			setmetatable(player_profile, Profiles)
	
		Profiles[player] = player_profile
		PlayerReplicas[player] = player_profile.Replica

		setupLeaderstats(player)
		DataManager:LoadInventory(player, profile.Data)

	
	end

	DataManager:StartAutoSave(player)
end

Players.PlayerRemoving:Connect(function(player)
	local profile = Profiles[player]
	if profile and profile.Data then
		
		DataManager:SaveInventory(player)
		print(PlayerReplicas[player].Data)
		profile.Profile:Release()
	end

	local r = PlayerReplicas[player]
	if r then pcall(function() r:Destroy() end) PlayerReplicas[player] = nil end
	DataManager.AutoSaveLoops[player] = nil
end)

function DataManager:IsActive(player) return Profiles[player] ~= nil end
function DataManager:Get(player)
	while not Profiles[player] do task.wait(0.1) end
	return Profiles[player].Profile.Data
end

--======================================================================================================--
-- AutoSave
--======================================================================================================--

function DataManager:StartAutoSave(player)
	if DataManager.AutoSaveLoops[player] then return end
	local profile = Profiles[player]
	if not profile then return end

	DataManager.AutoSaveLoops[player] = task.spawn(function()
		while player and player.Parent and Profiles[player] do
			task.wait(10)
			pcall(function() DataManager:SaveInventory(player) end)
		end
		DataManager.AutoSaveLoops[player] = nil
	end)
end

return DataManager
