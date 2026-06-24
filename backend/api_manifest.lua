local fs = require("fs")
local config = require("config")
local http_client = require("http_client")
local logger = require("plugin_logger")
local utils = require("plugin_utils")
local paths = require("paths")

local api_manifest = {}

local _APIS_INIT_DONE = false
local _INIT_APIS_LAST_MESSAGE = ""

local DEFAULT_API_LIST = {
    {
        name = "Morrenus",
        url = "https://hubcapmanifest.com/api/v1/manifest/<appid>?api_key=<moapikey>",
        success_code = 200,
        unavailable_code = 404,
        enabled = true
    },
    {
        name = "Ryuu",
        url = "http://167.235.229.108/<appid>",
        success_code = 200,
        unavailable_code = 404,
        enabled = true
    },
    {
        name = "TwentyTwo Cloud",
        url = "https://api.twentytwocloud.com/download?appid=<appid>",
        success_code = 200,
        unavailable_code = 404,
        enabled = true
    },
    {
        name = "Sushi",
        url = "https://raw.githubusercontent.com/sushi-dev55-alt/sushitools-games-repo-alt/refs/heads/main/<appid>.zip",
        success_code = 200,
        unavailable_code = 404,
        enabled = true
    }
}

local function copy_default_api_list()
    local copy = {}
    for _, api in ipairs(DEFAULT_API_LIST) do
        table.insert(copy, {
            name = api.name,
            url = api.url,
            success_code = api.success_code,
            unavailable_code = api.unavailable_code,
            enabled = api.enabled
        })
    end
    return copy
end

local function is_valid_api_manifest(data)
    return type(data) == "table" and type(data.api_list) == "table"
end

local function write_api_manifest(path, data)
    local text = utils.encode_json(data)
    local normalized = utils.normalize_manifest_text(text)
    if normalized == "" then normalized = text end
    utils.write_text(path, normalized)
end

local function seed_default_api_manifest(path)
    local data = { api_list = copy_default_api_list() }
    write_api_manifest(path, data)
    return #data.api_list
end

local function read_api_manifest(path)
    local data = utils.read_json(path)
    if is_valid_api_manifest(data) then
        return data
    end
    return nil
end

local function fetch_remote_manifest_text()
    logger.log("InitApis: Fetching manifest from " .. config.API_MANIFEST_URL)
    local resp = http_client.get(config.API_MANIFEST_URL, { timeout = 15 })
    if resp and resp.status == 200 and resp.body then
        logger.log("InitApis: Fetched manifest, length=" .. tostring(#resp.body))
        return resp.body
    end

    logger.warn("InitApis: Primary URL failed, trying proxy...")
    resp = http_client.get(config.API_MANIFEST_PROXY_URL, { timeout = config.HTTP_PROXY_TIMEOUT_SECONDS })
    if resp and resp.status == 200 and resp.body then
        logger.log("InitApis: Fetched manifest from proxy, length=" .. tostring(#resp.body))
        return resp.body
    end

    logger.warn("InitApis: Proxy also failed")
    return ""
end

local function ensure_api_manifest_data()
    local path = paths.backend_path(config.API_JSON_FILE)
    local data = read_api_manifest(path)
    if data then return data end

    logger.warn("OpenLuaTools: api.json missing or invalid; attempting to initialize")
    pcall(api_manifest.init_apis)
    data = read_api_manifest(path)
    if data then return data end

    logger.warn("OpenLuaTools: seeding bundled default API manifest")
    seed_default_api_manifest(path)
    return read_api_manifest(path) or { api_list = {} }
end

function api_manifest.init_apis()
    logger.log("InitApis: invoked")
    if _APIS_INIT_DONE then
        logger.log("InitApis: already completed this session, skipping")
        return { success = true, message = _INIT_APIS_LAST_MESSAGE }
    end

    local api_json_path = paths.backend_path(config.API_JSON_FILE)
    local message = ""

    if fs.exists(api_json_path) and read_api_manifest(api_json_path) then
        logger.log("InitApis: Local file exists -> " .. api_json_path .. "; skipping remote fetch")
    else
        logger.log("InitApis: Local file missing or invalid -> " .. api_json_path)
        local manifest_text = fetch_remote_manifest_text()

        local normalized = ""
        if manifest_text ~= "" then
            normalized = utils.normalize_manifest_text(manifest_text)
        end

        if normalized ~= "" then
            utils.write_text(api_json_path, normalized)
            local count = utils.count_apis(normalized)
            message = "No API's Configured, Loaded " .. tostring(count) .. " Free Ones :D"
            logger.log("InitApis: Wrote new api.json with " .. tostring(count) .. " entries")
        else
            local count = seed_default_api_manifest(api_json_path)
            message = "No API's Configured, Loaded " .. tostring(count) .. " bundled defaults"
            logger.warn("InitApis: Manifest empty, wrote bundled defaults")
        end
    end

    _APIS_INIT_DONE = true
    _INIT_APIS_LAST_MESSAGE = message
    logger.log("InitApis: completed message=" .. tostring(message))
    return { success = true, message = message }
end

function api_manifest.get_init_apis_message()
    logger.log("InitApis: GetInitApisMessage invoked")
    local msg = _INIT_APIS_LAST_MESSAGE or ""
    if msg ~= "" then
        logger.log("InitApis: delivering queued message -> " .. msg)
    end
    _INIT_APIS_LAST_MESSAGE = ""
    return { success = true, message = msg }
end

function api_manifest.store_last_message(message)
    _INIT_APIS_LAST_MESSAGE = message or ""
end

function api_manifest.fetch_free_apis_now()
    logger.log("OpenLuaTools: FetchFreeApisNow invoked")
    local manifest_text = ""

    logger.log("OpenLuaTools: Fetching manifest from " .. config.API_MANIFEST_URL)
    local resp = http_client.get(config.API_MANIFEST_URL, { timeout = 15 })
    if resp and resp.status == 200 and resp.body then
        manifest_text = resp.body
        logger.log("OpenLuaTools: Fetched manifest from primary URL")
    else
        logger.warn("OpenLuaTools: Primary manifest URL failed, trying proxy...")
        resp = http_client.get(config.API_MANIFEST_PROXY_URL, { timeout = config.HTTP_PROXY_TIMEOUT_SECONDS })
        if resp and resp.status == 200 and resp.body then
            manifest_text = resp.body
            logger.log("OpenLuaTools: Fetched manifest from proxy URL")
        else
            logger.warn("OpenLuaTools: Proxy manifest URL also failed")
            return { success = false, error = "Both URLs failed" }
        end
    end

    local normalized = ""
    if manifest_text ~= "" then
        normalized = utils.normalize_manifest_text(manifest_text)
    end

    if normalized == "" then
        return { success = false, error = "Empty manifest" }
    end

    utils.write_text(paths.backend_path(config.API_JSON_FILE), normalized)
    local count = utils.count_apis(normalized)
    return { success = true, count = count }
end

function api_manifest.load_api_manifest()
    local path = paths.backend_path(config.API_JSON_FILE)
    local text = utils.read_text(path)

    local normalized = utils.normalize_manifest_text(text)
    if normalized and normalized ~= text and normalized ~= "" then
        utils.write_text(path, normalized)
        logger.log("OpenLuaTools: Normalized api.json")
        text = normalized
    end

    local data = ensure_api_manifest_data()
    local apis = {}
    if data and type(data.api_list) == "table" then
        for _, api in ipairs(data.api_list) do
            if api.enabled then
                table.insert(apis, api)
            end
        end
    end
    return apis
end

function api_manifest.add_custom_api(payload)
    if not payload or type(payload.name) ~= "string" or type(payload.url) ~= "string" then
        return { success = false, error = "Invalid payload: name and url are required" }
    end

    local path = paths.backend_path(config.API_JSON_FILE)
    local text = ""
    if fs.exists(path) then
        text = utils.read_text(path)
    end

    local data = { api_list = {} }
    if text ~= "" then
        local ok, parsed = pcall(utils.decode_json, text)
        if ok and type(parsed) == "table" and type(parsed.api_list) == "table" then
            data = parsed
        end
    end

    local new_api = {
        name = payload.name,
        url = payload.url,
        success_code = payload.success_code or 200,
        unavailable_code = payload.unavailable_code or 404,
        enabled = true
    }
    
    if payload.api_key and payload.api_key ~= "" then
        new_api.api_key = payload.api_key
    end

    table.insert(data.api_list, new_api)

    local new_text = utils.encode_json(data)
    local formatted = utils.normalize_manifest_text(new_text)
    utils.write_text(path, formatted)
    
    logger.log("OpenLuaTools: Added custom API: " .. payload.name)
    return { success = true }
end

function api_manifest.get_api_list()
    local success, apis = pcall(api_manifest.load_api_manifest)
    if not success then
        return { success = false, error = tostring(apis), apis = {} }
    end

    local morrenus_api_key = ""
    local ok, sm = pcall(require, "settings.manager")
    if ok and sm and sm.get_morrenus_api_key then
        morrenus_api_key = sm.get_morrenus_api_key() or ""
    end

    local api_names = {}
    for i, api in ipairs(apis) do
        local url = api.url or ""
        if not (string.find(url, "<moapikey>") and (not morrenus_api_key or morrenus_api_key == "")) then
            table.insert(api_names, { name = api.name or "Unknown", index = i - 1 })
        end
    end

    return { success = true, apis = api_names }
end

function api_manifest.get_all_apis()
    local data = ensure_api_manifest_data()
    local apis = {}
    if data and type(data.api_list) == "table" then
        for _, api in ipairs(data.api_list) do
            table.insert(apis, {
                name    = api.name or "Unknown",
                url     = api.url or "",
                enabled = api.enabled ~= false  -- default true
            })
        end
    end
    return { success = true, apis = apis }
end

function api_manifest.toggle_api(name)
    if not name or type(name) ~= "string" or name == "" then
        return { success = false, error = "name is required" }
    end

    local path = paths.backend_path(config.API_JSON_FILE)
    local data = utils.read_json(path)
    if not data or type(data.api_list) ~= "table" then
        return { success = false, error = "Failed to load api.json" }
    end

    local found = false
    local new_state = false
    for _, api in ipairs(data.api_list) do
        if api.name == name then
            api.enabled = not (api.enabled ~= false)
            new_state = api.enabled
            found = true
            break
        end
    end

    if not found then
        return { success = false, error = "API not found: " .. name }
    end

    local new_text = utils.encode_json(data)
    local formatted = utils.normalize_manifest_text(new_text)
    utils.write_text(path, formatted)

    logger.log("OpenLuaTools: Toggled API '" .. name .. "' -> " .. tostring(new_state))
    return { success = true, enabled = new_state }
end

function api_manifest.remove_api(name)
    if not name or type(name) ~= "string" or name == "" then
        return { success = false, error = "name is required" }
    end

    local path = paths.backend_path(config.API_JSON_FILE)
    local data = utils.read_json(path)
    if not data or type(data.api_list) ~= "table" then
        return { success = false, error = "Failed to load api.json" }
    end

    local new_list = {}
    local found = false
    for _, api in ipairs(data.api_list) do
        if api.name == name then
            found = true
        else
            table.insert(new_list, api)
        end
    end

    if not found then
        return { success = false, error = "API not found: " .. name }
    end

    data.api_list = new_list
    local new_text = utils.encode_json(data)
    local formatted = utils.normalize_manifest_text(new_text)
    utils.write_text(path, formatted)

    logger.log("OpenLuaTools: Removed API '" .. name .. "'")
    return { success = true }
end

function api_manifest.rename_api(old_name, new_name)
    if not old_name or old_name == "" or not new_name or new_name == "" then
        return { success = false, error = "old_name and new_name are required" }
    end

    local path = paths.backend_path(config.API_JSON_FILE)
    local data = utils.read_json(path)
    if not data or type(data.api_list) ~= "table" then
        return { success = false, error = "Failed to load api.json" }
    end

    local found = false
    for _, api in ipairs(data.api_list) do
        if api.name == old_name then
            api.name = new_name
            found = true
            break
        end
    end

    if not found then
        return { success = false, error = "API not found: " .. old_name }
    end

    local new_text = utils.encode_json(data)
    local formatted = utils.normalize_manifest_text(new_text)
    utils.write_text(path, formatted)

    logger.log("OpenLuaTools: Renamed API '" .. old_name .. "' -> '" .. new_name .. "'")
    return { success = true }
end

function api_manifest.set_api_order(ordered_names)
    if type(ordered_names) ~= "table" then
        return { success = false, error = "ordered_names must be a table" }
    end

    local path = paths.backend_path(config.API_JSON_FILE)
    local data = utils.read_json(path)
    if not data or type(data.api_list) ~= "table" then
        return { success = false, error = "Failed to load api.json" }
    end

    local new_list = {}
    local added = {}

    -- Add items in the requested order
    for _, name in ipairs(ordered_names) do
        for _, api in ipairs(data.api_list) do
            if api.name == name and not added[name] then
                table.insert(new_list, api)
                added[name] = true
                break
            end
        end
    end

    -- Add any items that were left out of the ordered list (safeguard)
    for _, api in ipairs(data.api_list) do
        if not added[api.name] then
            table.insert(new_list, api)
        end
    end

    data.api_list = new_list
    local new_text = utils.encode_json(data)
    local formatted = utils.normalize_manifest_text(new_text)
    utils.write_text(path, formatted)

    logger.log("OpenLuaTools: Reordered APIs")
    return { success = true }
end

return api_manifest
