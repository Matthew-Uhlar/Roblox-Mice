--!strict
-- GameFeel controller (iteration 7 §B2, team Client): hit-stop and impact
-- shakes from Net.S2C.Fx (rules in Util/GameFeel). Client-only: the server
-- keeps its speed.
--
--   * Hit-stop: an own big crit (45 ms) or an own boss / champion kill (70 ms)
--     holds the camera frame (CameraController.hitStop), pauses the local
--     hero's animations and burst particles for that long. Rate-limited; off
--     when the Screen shake setting or Effects is "off".
--   * Impact shakes: own hits and hits taken, scaled by the damage, small and
--     capped (GameFeel.SHAKE_MAX); CameraController scales every shake by the
--     Screen shake setting (Full / Low / Off) and Effects ("off" = none).
--   * Cast sounds live in SoundController (FX "ability").

local Players = game:GetService("Players")

local Client = script.Parent.Parent
local Remotes = require(Client.Util.Remotes)
local GameFeelMath = require(Client.Util.GameFeel)
local State = require(script.Parent.State)

local GameFeel = {}

local conn: any = nil
local lastStop = -math.huge
local lastShake = 0

local camMod: any = nil
local function camera(): any
	if camMod == nil then
		local ok, mod = pcall(require, script.Parent.CameraController)
		camMod = if ok and type(mod) == "table" then mod else false
	end
	return camMod or nil
end

local hordeMod: any = nil
local function horde(): any
	if hordeMod == nil then
		local ok, mod = pcall(require, script.Parent.HordeRenderer)
		hordeMod = if ok and type(mod) == "table" then mod else false
	end
	return hordeMod or nil
end

local particlesMod: any = nil
local function particles(): any
	if particlesMod == nil then
		local ok, mod = pcall(require, Client.Visuals.Particles)
		particlesMod = if ok and type(mod) == "table" then mod else false
	end
	return particlesMod or nil
end

local function feelOn(): boolean
	local okF, f = pcall(State.feel)
	local okG, g = pcall(State.gfx)
	local shake = if okF and type(f) == "table" then f.shake else "full"
	local fx = if okG and type(g) == "table" then g.fx else "full"
	return GameFeelMath.shakeMult(shake, fx) > 0
end

-- Pauses the local hero's animation tracks for `seconds`.
local function freezeHero(seconds: number)
	local char = Players.LocalPlayer and Players.LocalPlayer.Character
	local hum = char and char:FindFirstChildOfClass("Humanoid")
	local animator = hum and hum:FindFirstChildOfClass("Animator")
	if not animator then
		return
	end
	local paused: { [AnimationTrack]: number } = {}
	for _, tr in (animator :: Animator):GetPlayingAnimationTracks() do
		paused[tr] = tr.Speed
		tr:AdjustSpeed(0)
	end
	task.delay(seconds, function()
		for tr, sp in paused do
			if tr.IsPlaying and tr.Speed == 0 then
				tr:AdjustSpeed(sp)
			end
		end
	end)
end

local function hitStop(seconds: number)
	local now = os.clock()
	if seconds <= 0 or not GameFeelMath.mayStop(lastStop, now) or not feelOn() then
		return
	end
	lastStop = now
	local cam = camera()
	if cam and cam.hitStop then
		cam.hitStop(seconds)
	end
	pcall(freezeHero, seconds)
	-- burst particles too, unless a boss-kill slow-mo owns the time scale
	local p = particles()
	local slowing = cam and cam.slowAmount and cam.slowAmount() > 0
	if p and p.setTimeScale and not slowing then
		pcall(p.setTimeScale, 0)
		task.delay(seconds, function()
			local c = camera()
			if not (c and c.slowAmount and c.slowAmount() > 0) then
				pcall(p.setTimeScale, 1)
			end
		end)
	end
end

local function shake(amount: number, duration: number)
	local now = os.clock()
	if amount <= 0 or now - lastShake < 0.08 then
		return
	end
	lastShake = now
	local cam = camera()
	if cam and cam.shake then
		cam.shake(amount, duration)
	end
end

local function onFx(batch: any)
	if type(batch) ~= "table" then
		return
	end
	local me = State.localUserId()
	for _, ev in batch do
		if type(ev) ~= "table" then
			continue
		end
		local t = ev.t
		if t == "hit" and tonumber(ev.by) == me then
			hitStop(GameFeelMath.hitStopFor(ev, me))
			shake(GameFeelMath.impactShake(tonumber(ev.amount) or 0, ev.crit == true, false), 0.18)
		elseif t == "die" and tonumber(ev.by) == me then
			local h = horde()
			local big = h ~= nil and h.isBoss ~= nil and h.isBoss(tonumber(ev.id)) == true
			local s = GameFeelMath.hitStopFor(ev, me, big)
			if s > 0 then
				hitStop(s)
				shake(0.8, 0.3)
			end
		elseif t == "hurt" and tonumber(ev.id) == me then
			shake(GameFeelMath.impactShake(tonumber(ev.amount) or 0, false, true), 0.22)
		end
	end
end

function GameFeel.init()
	if conn then
		return
	end
	conn = Remotes.on(Remotes.S2C.Fx, function(batch)
		local ok, err = pcall(onFx, batch)
		if not ok then
			warn("[Trunkfall] GameFeel: " .. tostring(err))
		end
	end)
end

function GameFeel.destroy()
	if conn then
		pcall(function()
			conn:Disconnect()
		end)
		conn = nil
	end
end

return GameFeel
