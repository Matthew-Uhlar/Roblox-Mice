--!strict
-- LobbyLook (iter 6, team Look, client): the swap puff when a player's elephant
-- look changes in the lobby.
--
-- The server (CosmeticsService) dresses every player in the Herd Suit in the
-- lobby too (same builder as in a run; Visuals/BotAnimator already animates any
-- character's "HerdSuit" model, idle / walk) and rebuilds it in place on a class,
-- skin, ascension look or cosmetic change. It writes the character attribute
-- "LookKey" (the look's identity), which changes only when the look does. This
-- controller polls the characters (POLL seconds; a lobby holds at most 4) and,
-- when a known character's LookKey changes outside a run (no player attribute
-- "Squad"), bursts a puff of smoke plus a few glints at its root. A character's
-- first key (join, respawn) is silent. Particles honours the Effects setting
-- ("off" = no burst). No connections per character: nothing to leak.
--
--   LobbyLook.init() / LobbyLook.destroy()
--   LobbyLook.poll() -> number   one check now; returns the puffs played (tests)

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local LobbyLook = {}

LobbyLook.KEY = "LookKey"
LobbyLook.POLL = 0.15
LobbyLook.PUFF = 22
LobbyLook.GLINT = 10
LobbyLook.GLINT_COLOR = Color3.fromRGB(255, 214, 102)

local known: { [Model]: string } = {}
local conn: RBXScriptConnection? = nil
local acc = 0

local Particles: any = nil
local function particles(): any
	if Particles == nil then
		local ok, mod = pcall(function()
			local visuals = script.Parent.Parent:FindFirstChild("Visuals")
			local inst = visuals and visuals:FindFirstChild("Particles")
			return if inst and inst:IsA("ModuleScript") then require(inst) :: any else nil
		end)
		Particles = if ok and type(mod) == "table" and type(mod.burst) == "function" then mod else false
	end
	return Particles or nil
end

local function puff(character: Model)
	local root = character:FindFirstChild("HumanoidRootPart")
	if not root or not root:IsA("BasePart") then
		return
	end
	local P = particles()
	if not P then
		return
	end
	local pos = root.Position
	pcall(P.burst, "poof", pos, LobbyLook.PUFF)
	pcall(P.burst, "glint", pos + Vector3.new(0, 2, 0), LobbyLook.GLINT, LobbyLook.GLINT_COLOR)
end

function LobbyLook.poll(): number
	local played = 0
	local seen: { [Model]: boolean } = {}
	for _, plr in Players:GetPlayers() do
		local char = plr.Character
		if not char or not char.Parent then
			continue
		end
		seen[char] = true
		local key = char:GetAttribute(LobbyLook.KEY)
		if type(key) ~= "string" then
			continue
		end
		local prev = known[char]
		known[char] = key
		if prev ~= nil and prev ~= key and plr:GetAttribute("Squad") == nil then
			puff(char)
			played += 1
		end
	end
	for char in known do
		if not seen[char] then
			known[char] = nil -- respawned / left: drop the old character
		end
	end
	return played
end

function LobbyLook.init()
	if conn then
		return
	end
	acc = 0
	conn = RunService.Heartbeat:Connect(function(dt: number)
		acc += dt
		if acc < LobbyLook.POLL then
			return
		end
		acc = 0
		local ok, err = pcall(LobbyLook.poll)
		if not ok then
			warn("[LobbyLook] " .. tostring(err))
		end
	end)
end

function LobbyLook.destroy()
	if conn then
		conn:Disconnect()
		conn = nil
	end
	table.clear(known)
end

return LobbyLook
