-- Compiles every .luau file under the given roots with the Luau compiler and
-- reports syntax errors. Usage: lune run scripts/compile-check.luau src tests
local fs = require("@lune/fs")
local luau = require("@lune/luau")
local process = require("@lune/process")

local roots = process.args
if #roots == 0 then
	roots = { "src", "tests" }
end

local checked, bad = 0, 0
local function walk(dir: string)
	for _, name in fs.readDir(dir) do
		local path = dir .. "/" .. name
		if fs.isDir(path) then
			walk(path)
		elseif string.sub(name, -5) == ".luau" then
			checked += 1
			local ok, err = pcall(luau.compile, fs.readFile(path))
			if not ok then
				bad += 1
				print("✗ " .. path .. "\n    " .. tostring(err))
			end
		end
	end
end

for _, root in roots do
	walk(root)
end
print(string.format("compiled %d files, %d with errors", checked, bad))
if bad > 0 then
	process.exit(1)
end
