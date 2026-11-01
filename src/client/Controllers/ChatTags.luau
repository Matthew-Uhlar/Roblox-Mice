--!strict
-- Chat tags for VIP / Cheese Club members (QC2 B1, client part). The server
-- (MonetizationService, Fix Team 1) sets two attributes on the Player:
--   ChatTag       string, e.g. "VIP" or "🧀 Club"
--   ChatTagColor  Color3 or a hex string ("#FFC93C" / "FFC93C"); optional
-- This hook prefixes incoming TextChatService messages from those players
-- with the coloured tag. Legacy chat is not supported. Everything is
-- pcall-guarded: a broken tag must never break chat.

local Players = game:GetService("Players")
local TextChatService = game:GetService("TextChatService")

local ChatTags = {}

local MAX_TAG_CHARS = 20
local DEFAULT_HEX = "FFC93C" -- cheese gold (STYLE.md)

local installed = false

-- Rich-text escape (the tag goes inside a <font> element).
local function escape(s: string): string
	return (s:gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;"):gsub('"', "&quot;"):gsub("'", "&apos;"))
end

-- First `n` UTF-8 characters (emoji-safe truncation).
local function truncate(s: string, n: number): string
	local ok, cut = pcall(utf8.offset, s, n + 1)
	if ok and type(cut) == "number" then
		return string.sub(s, 1, cut - 1)
	end
	return s
end

local function toHex(c: any): string?
	if typeof(c) == "Color3" then
		return string.upper((c :: Color3):ToHex())
	elseif type(c) == "string" then
		local h = string.gsub(c, "^#", "")
		if #h == 6 and string.match(h, "^%x+$") then
			return string.upper(h)
		end
	end
	return nil
end

-- The rich-text prefix for a player's tag, or nil if they have none.
function ChatTags.prefixFor(player: Player): string?
	local tag = player:GetAttribute("ChatTag")
	if type(tag) ~= "string" then
		return nil
	end
	tag = truncate((string.gsub(tag, "^%s+", ""):gsub("%s+$", "")), MAX_TAG_CHARS)
	if tag == "" or not utf8.len(tag) then
		return nil
	end
	local hex = toHex(player:GetAttribute("ChatTagColor")) or DEFAULT_HEX
	return string.format('<font color="#%s">[%s]</font>', hex, escape(tag))
end

local function onIncoming(message: TextChatMessage): TextChatMessageProperties?
	local source = message.TextSource
	if not source then
		return nil -- system message
	end
	local player = Players:GetPlayerByUserId(source.UserId)
	if not player then
		return nil
	end
	local prefix = ChatTags.prefixFor(player)
	if not prefix then
		return nil
	end
	local props = Instance.new("TextChatMessageProperties")
	props.PrefixText = prefix .. " " .. message.PrefixText
	return props
end

function ChatTags.init()
	if installed then
		return
	end
	local ok, err = pcall(function()
		if TextChatService.ChatVersion ~= Enum.ChatVersion.TextChatService then
			return -- legacy chat: not supported
		end
		TextChatService.OnIncomingMessage = function(message: TextChatMessage)
			local okTag, props = pcall(onIncoming, message)
			if okTag then
				return props
			end
			return nil
		end
		installed = true
	end)
	if not ok then
		warn("[Trunkfall] chat tags unavailable: " .. tostring(err))
	end
end

function ChatTags.destroy()
	if installed then
		pcall(function()
			(TextChatService :: any).OnIncomingMessage = nil
		end)
		installed = false
	end
end

return ChatTags
