-- Streams a reply to the terminal. Run with `OPENAI_API_KEY=... lune run examples/lune/stream`.
local stdio = require("@lune/stdio")

local AI = require("../../AI")

local openai = AI.new({ provider = "openai", defaultModel = "gpt-5.2" })

local stream = openai:stream({ prompt = "Explain WebSockets in three sentences." })
for event in stream:iter() do
	if event.type == "text" then
		stdio.write(event.delta)
	elseif event.type == "error" then
		stdio.ewrite(`\n{event.error}\n`)
	end
end
print()

local response = stream:await()
print(`[{response.usage.inputTokens} in, {response.usage.outputTokens} out]`)
