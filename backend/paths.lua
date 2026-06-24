local fs = require("fs")
local m_utils = require("utils")

local paths = {}

-- Fallback logic for when Millennium hasn't set the env var
local function get_current_file_path()
    local info = debug.getinfo(2, "S")
    if info and info.source and info.source:sub(1, 1) == "@" then
        return info.source:sub(2)
    end
    return fs.current_path()
end

local backend_dir = nil
local plugin_dir = nil

local function path_exists(path)
    return path and path ~= "" and fs.exists(path)
end

local function normalize_backend_path(path)
    if not path or path == "" then return nil end

    local abs = fs.absolute(path)
    if abs:match("%.lua$") then
        return fs.absolute(fs.parent_path(abs))
    end

    if path_exists(fs.join(abs, "main.lua")) then
        return abs
    end

    local nested_backend = fs.join(abs, "backend")
    if path_exists(fs.join(nested_backend, "main.lua")) then
        return fs.absolute(nested_backend)
    end

    return abs
end

local function add_candidate(candidates, seen, path)
    if not path or path == "" then return end
    local abs = fs.absolute(path)
    if seen[abs] then return end
    seen[abs] = true
    table.insert(candidates, abs)
end

function paths.get_backend_dir()
    if backend_dir then return backend_dir end
    
    local be_path = m_utils.get_backend_path()
    if be_path and be_path ~= "" then
        backend_dir = normalize_backend_path(be_path)
        return backend_dir
    end

    local file_path = get_current_file_path()
    local dir = file_path:match("(.*[/\\])")
    if dir then
        dir = dir:sub(1, -2)
    else
        dir = "."
    end
    backend_dir = fs.absolute(dir)
    return backend_dir
end

function paths.get_plugin_dir()
    if plugin_dir then return plugin_dir end
    local bdir = paths.get_backend_dir()
    if path_exists(fs.join(bdir, "plugin.json")) then
        plugin_dir = bdir
    else
        plugin_dir = fs.absolute(fs.join(bdir, ".."))
    end
    return plugin_dir
end

function paths.backend_path(filename)
    return fs.join(paths.get_backend_dir(), filename)
end

function paths.public_candidates(filename)
    local candidates = {}
    local seen = {}
    local rel = tostring(filename or "")

    local function add_public_dir(dir)
        if rel == "" then
            add_candidate(candidates, seen, dir)
        else
            add_candidate(candidates, seen, fs.join(dir, rel))
        end
    end

    local bdir = paths.get_backend_dir()
    local pdir = paths.get_plugin_dir()

    add_public_dir(fs.join(pdir, "public"))
    add_public_dir(fs.join(bdir, "public"))
    add_public_dir(fs.join(bdir, "..", "public"))
    add_public_dir(fs.join(bdir, "..", "..", "public"))

    return candidates
end

function paths.find_public_path(filename)
    for _, candidate in ipairs(paths.public_candidates(filename)) do
        if fs.exists(candidate) then
            return candidate
        end
    end
    return nil
end

function paths.public_path(filename)
    local found = paths.find_public_path(filename)
    if found then return found end
    return paths.public_candidates(filename)[1]
end

return paths
