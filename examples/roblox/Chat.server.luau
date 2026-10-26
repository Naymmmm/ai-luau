--!strict
-- Answers chat messages with Claude, moderating both the question and the answer.
-- Requires HTTP requests enabled, plus "anthropic" and "openai" keys in the experience's secret store.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TextService = game:GetService("TextService")

local AI = require(ReplicatedStorage:WaitForChild("AI"))

local moderator = AI.Provider.new({ Format = AI.Format.OpenAI.Responses, Secret = "openai" })
local claude = AI.Provider.new({
	Format = AI.Format.Anthropic.V2023_06_01,
	Secret = "anthropic",
	DefaultModel = "claude-sonnet-5-5",
	MaxTokens = 300,
	Moderation = { Provider = moderator, Policy = { DefaultThreshold = 0.5 } },
})

local remote = Instance.new("RemoteFunction")
remote.Name = "AskAI"
remote.Parent = ReplicatedStorage

remote.OnServerInvoke = function(player: Player, question: unknown): string
	if typeof(question) ~= "string" or #question == 0 or #question > 500 then
		return "Ask a shorter question."
	end
	local ok, result = pcall(function()
		return claude:Create({
			System = "You are a friendly guide in a Roblox experience. Answer in two sentences or fewer.",
			Prompt = question,
		})
	end)
	if not ok then
		if AI.IsError(result) and (result :: any).Kind == "moderation" then
			return "Let's talk about something else."
		end
		warn("AI request failed:", result)
		return "The guide is unavailable right now."
	end
	-- Roblox still requires its own text filter for any text shown to players.
	local filtered = TextService:FilterStringAsync(result.Text, player.UserId)
	return filtered:GetNonChatStringForBroadcastAsync()
end
