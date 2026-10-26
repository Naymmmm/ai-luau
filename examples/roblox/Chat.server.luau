--!strict
-- Answers chat messages with Claude, moderating both the question and the answer.
-- Requires HTTP requests enabled, plus "anthropic" and "openai" keys in the experience's secret store.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TextService = game:GetService("TextService")

local AI = require(ReplicatedStorage:WaitForChild("AI"))

local moderator = AI.new({ provider = "openai", secret = "openai" })
local claude = AI.new({
	provider = "anthropic",
	secret = "anthropic",
	defaultModel = "claude-sonnet-5-5",
	maxTokens = 300,
	moderation = { client = moderator, policy = { defaultThreshold = 0.5 } },
})

local remote = Instance.new("RemoteFunction")
remote.Name = "AskAI"
remote.Parent = ReplicatedStorage

remote.OnServerInvoke = function(player: Player, question: unknown): string
	if typeof(question) ~= "string" or #question == 0 or #question > 500 then
		return "Ask a shorter question."
	end
	local ok, result = pcall(function()
		return claude:create({
			system = "You are a friendly guide in a Roblox experience. Answer in two sentences or fewer.",
			prompt = question,
		})
	end)
	if not ok then
		if AI.isError(result) and (result :: any).kind == "moderation" then
			return "Let's talk about something else."
		end
		warn("AI request failed:", result)
		return "The guide is unavailable right now."
	end
	-- Roblox still requires its own text filter for any text shown to players.
	local filtered = TextService:FilterStringAsync(result.text, player.UserId)
	return filtered:GetNonChatStringForBroadcastAsync()
end
