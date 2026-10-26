-- Runs a tool-use loop with Claude. Run with `ANTHROPIC_API_KEY=... lune run examples/lune/tools`.
local AI = require("../../AI")

local claude = AI.Provider.new({ Format = AI.Format.Anthropic.Latest, DefaultModel = "claude-sonnet-5-5" })

local result = claude:Run({
	Prompt = "What's the weather in Paris and Tokyo?",
	Tools = {
		{
			Name = "get_weather",
			Description = "Current weather for a city",
			Parameters = {
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

print(result.Response.Text)
print(`({result.Steps} model calls)`)
