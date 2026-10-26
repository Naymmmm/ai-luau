-- Streams a reply to the terminal. Run with `OPENAI_API_KEY=... lune run examples/lune/stream`.
local stdio = require("@lune/stdio")

local AI = require("../../AI")

local openai = AI.Provider.new({ Format = AI.Format.OpenAI.Responses, DefaultModel = "gpt-5.2" })

local stream = openai:Stream({ Prompt = "Explain WebSockets in three sentences." })
for event in stream:Iter() do
	if event.Type == "text" then
		stdio.write(event.Delta)
	elseif event.Type == "error" then
		stdio.ewrite(`\n{event.Error}\n`)
	end
end
print()

local response = stream:Await()
print(`[{response.Usage.InputTokens} in, {response.Usage.OutputTokens} out]`)
