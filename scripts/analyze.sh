#!/usr/bin/env sh
# Type-checks AI.luau and the Roblox example against the Roblox API with luau-lsp,
# validates the Moonwave doc comments, then checks formatting with StyLua.
set -eu
cd "$(dirname "$0")/.."

DEFS="types/globalTypes.d.luau"
if [ ! -f "$DEFS" ]; then
	mkdir -p types
	curl -fsSL "https://raw.githubusercontent.com/JohnnyMorganz/luau-lsp/main/scripts/globalTypes.None.d.luau" -o "$DEFS"
fi

rojo sourcemap examples/roblox/example.project.json --absolute -o types/sourcemap.json
luau-lsp analyze --platform=roblox --definitions=@roblox="$DEFS" --sourcemap=types/sourcemap.json \
	AI.luau examples/roblox
moonwave-extractor extract AI.luau >/dev/null
stylua --check AI.luau tests examples
