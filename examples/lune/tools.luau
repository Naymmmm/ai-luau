-- Runs a tool-use loop with Claude. Run with `ANTHROPIC_API_KEY=... lune run examples/lune/tools`.
local AI = require("../../AI")

local claude = AI.new({ provider = "anthropic", defaultModel = "claude-sonnet-5-5" })

local result = claude:run({
	prompt = "What's the weather in Paris and Tokyo?",
	tools = {
		{
			name = "get_weather",
			description = "Current weather for a city",
			parameters = {
				type = "object",
				properties = { city = { type = "string" } },
				required = { "city" },
			},
		},
	},
}, {
	get_weather = function(args)
		return { city = args.city, celsius = if args.city == "Paris" then 14 else 19, sky = "clear" }
	end,
})

print(result.response.text)
print(`({result.steps} model calls)`)
