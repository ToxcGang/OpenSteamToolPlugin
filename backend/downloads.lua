local m_utils = require("utils")
local fs = require("fs")
local http_client = require("http_client")
local config = require("config")
local logger = require("plugin_logger")
local paths = require("paths")
local steam_utils = require("steam_utils")
local utils = require("plugin_utils")
local api_manifest = require("api_manifest")
local settings_manager = require("settings.manager")
local cjson = require("json")
local safety = require("safety")

local downloads = {}
local DOWNLOAD_STATE = {}

local function _set_download_state(appid, update)
    if type(appid) == "string" then appid = tonumber(appid) end
    if not DOWNLOAD_STATE[appid] then DOWNLOAD_STATE[appid] = {} end
    for k, v in pairs(update) do
        DOWNLOAD_STATE[appid][k] = v
    end
end

local function _get_download_state(appid)
    if type(appid) == "string" then appid = tonumber(appid) end
    local state = DOWNLOAD_STATE[appid] or {}
    local copy = {}
    for k, v in pairs(state) do copy[k] = v end
    return copy
end

function downloads.get_add_status(appid)
    if type(appid) == "string" then appid = tonumber(appid) end

    local dest_root = utils.ensure_temp_download_dir()
    local state_file = fs.join(dest_root, tostring(appid) .. "_state.json")

    if fs.exists(state_file) then
        local content = m_utils.read_file(state_file)
        if content and content ~= "" then
            local success, data = pcall(cjson.decode, content)
            if success and type(data) == "table" and data.status then
                _set_download_state(appid, { status = data.status, error = data.error })

                if data.status == "extracted" then
                    -- Background script finished! Complete the installation synchronously.
                    local dest_path = fs.join(dest_root, tostring(appid) .. ".zip")
                    local extract_dir = fs.join(dest_root, "extracted_" .. tostring(appid))
                    local apiName = _get_download_state(appid).currentApi or "Unknown"

                    local ok, res = pcall(downloads._finalize_install_lua, appid, extract_dir, dest_path, apiName)
                    if not ok then
                        _set_download_state(appid, { status = "failed", error = tostring(res) })
                    end

                    -- Cleanup background script files
                    pcall(fs.remove, state_file)
                    pcall(fs.remove_all, extract_dir)
                    pcall(fs.remove, dest_path)
                    pcall(fs.remove, fs.join(dest_root, tostring(appid) .. "_dl.ps1"))
                    pcall(fs.remove, fs.join(dest_root, tostring(appid) .. "_dl.sh"))
                elseif data.status == "failed" then
                    pcall(fs.remove, state_file)
                end
            end
        end
    end

    return { success = true, state = _get_download_state(appid) }
end

function downloads._finalize_install_lua(appid, extract_dir, dest_path, api_name)
    _set_download_state(appid, { status = "processing" })
    local base_path = steam_utils.detect_steam_install_path()
    if not base_path or base_path == "" then error("Could not find Steam installation path") end

    local target_dir = steam_utils.ensure_opensteamtool_lua_dir()
    if not target_dir then error("Could not create OpenSteamTool Lua directory") end

    local depot_cache = fs.join(base_path, "depotcache")
    if not fs.exists(depot_cache) then fs.create_directories(depot_cache) end

    local target_lua = fs.join(target_dir, tostring(appid) .. ".lua")
    local extracted_lua_path = nil
    local copied_manifests = 0

    local success_list, files = pcall(fs.list_recursive, extract_dir)
    if not success_list or not files then
        error("Failed to inspect extracted archive")
    end

    for _, entry in ipairs(files) do
        if not entry.is_directory then
            local ok_path, rel_or_err = safety.validate_extracted_file(extract_dir, entry.path)
            if not ok_path then
                error("Unsafe archive entry: " .. tostring(entry.path) .. " (" .. tostring(rel_or_err) .. ")")
            end

            local name = entry.name or ""
            if safety.is_manifest_filename(name) then
                local dest_man = fs.join(depot_cache, name)
                local ok_copy, copy_err = safety.copy_file(entry.path, dest_man, depot_cache)
                if not ok_copy then
                    error("Failed to copy manifest " .. tostring(name) .. ": " .. tostring(copy_err))
                end
                copied_manifests = copied_manifests + 1
            elseif name:match("%.manifest$") then
                logger.warn("OpenLuaTools: Skipping invalid manifest filename: " .. tostring(name))
            end

            if safety.is_expected_lua_filename(name, appid) then
                extracted_lua_path = entry.path
            elseif name:match("%.lua$") then
                logger.warn("OpenLuaTools: Skipping unexpected Lua filename: " .. tostring(name))
            end
        end
    end

    if extracted_lua_path and fs.exists(extracted_lua_path) then
        local text = m_utils.read_file(extracted_lua_path)
        if text then
            -- OpenSteamTool supports setManifestid, so downloaded Lua scripts stay intact.
            m_utils.write_file(target_lua, text)
            _set_download_state(appid, { installedPath = target_lua, manifestCount = copied_manifests })
        else
            error("Failed to read extracted Lua file")
        end
    else
        error("No valid " .. tostring(appid) .. ".lua file found in archive")
    end

    _set_download_state(appid, { status = "done", success = true, api = api_name })
end

local function _launch_async_download(appid, url, dest_path, extract_dir)
    local ok_url, url_err = safety.validate_http_url(url)
    if not ok_url then error(url_err) end

    local is_windows = m_utils.getenv("OS") == "Windows_NT"
    local dest_root = utils.ensure_temp_download_dir()
    local state_file = fs.join(dest_root, tostring(appid) .. "_state.json")

    m_utils.write_file(state_file, '{"status": "downloading"}')
    if not fs.exists(extract_dir) then fs.create_directories(extract_dir) end

    if is_windows then
        local cmd = string.format(
            'cmd.exe /C start "OpenLuaTools Downloader" cmd.exe /C "color 0B && echo OpenLuaTools is downloading the requested files... && echo Please keep this window open until it closes automatically. && echo. && (echo {"status": "downloading"} > "%s" && curl.exe -# -L -A "discord(dot)gg/luatools" "%s" -o "%s" && echo {"status": "extracting"} > "%s" && echo. && echo Extracting files... && tar.exe -xf "%s" -C "%s" && echo {"status": "extracted"} > "%s") || (echo. && echo ERROR: Download or extraction failed! && echo {"status": "failed"} > "%s" && timeout /t 5)"',
            state_file, url, dest_path, state_file, dest_path, extract_dir, state_file, state_file
        )
        m_utils.exec(cmd)
    else
        local sh_path = fs.join(paths.get_plugin_dir(), "backend", "scripts", "downloader.sh")
        m_utils.exec('chmod +x "' .. sh_path .. '"')
        local cmd = string.format(
            'nohup bash "%s" "%s" "%s" "%s" "%s" > /dev/null 2>&1 &',
            sh_path, url, dest_path, extract_dir, state_file
        )
        m_utils.exec(cmd)
    end
end

function downloads.start_add_via_openluatools_from_url(appid, url, apiName)
    if type(appid) == "string" then appid = tonumber(appid) end
    if not appid then return { success = false, error = "Invalid appid" } end

    logger.log("OpenLuaTools: StartAddViaOpenLuaToolsFromUrl appid=" .. tostring(appid) .. " api=" .. tostring(apiName))
    _set_download_state(appid, { status = "downloading", currentApi = apiName, bytesRead = 0, totalBytes = 0 })

    local ok, res = pcall(function()
        local dest_root = utils.ensure_temp_download_dir()
        local dest_path = fs.join(dest_root, tostring(appid) .. ".zip")
        local extract_dir = fs.join(dest_root, "extracted_" .. tostring(appid))
        _launch_async_download(appid, url, dest_path, extract_dir)
    end)

    if not ok then
        logger.warn("OpenLuaTools: Async Download crashed - " .. tostring(res))
        _set_download_state(appid, { status = "failed", error = tostring(res) })
        return { success = false, error = tostring(res) }
    end

    return { success = true }
end

function downloads.start_add_via_openluatools(appid)
    if type(appid) == "string" then appid = tonumber(appid) end
    if not appid then return { success = false, error = "Invalid appid" } end

    logger.log("OpenLuaTools: StartAddViaOpenLuaTools appid=" .. tostring(appid))
    _set_download_state(appid, { status = "queued", bytesRead = 0, totalBytes = 0 })

    local apis = api_manifest.load_api_manifest()
    if not apis or #apis == 0 then
        _set_download_state(appid, { status = "failed", error = "No APIs available" })
        return { success = true }
    end

    local dest_root = utils.ensure_temp_download_dir()
    local dest_path = fs.join(dest_root, tostring(appid) .. ".zip")
    local extract_dir = fs.join(dest_root, "extracted_" .. tostring(appid))
    local morrenus_api_key = settings_manager.get_morrenus_api_key()

    local ok, res = pcall(function()
        -- Note: For auto-add we only try the FIRST valid URL without verifying it via a synchronous HTTP request,
        -- because verifying it synchronously would defeat the purpose of async downloads.
        -- We assume CheckApisForApp already verified availability before user clicked this!
        local target_url = nil
        local target_name = nil
        for _, api in ipairs(apis) do
            local name = api.name or "Unknown"
            local template = api.url or ""
            local success_code = tonumber(api.success_code) or 200
            local can_try = true

            if string.find(template, "<moapikey>") then
                if not morrenus_api_key or morrenus_api_key == "" then
                    can_try = false
                else
                    template = template:gsub("<moapikey>", morrenus_api_key)
                end
            end
            if string.find(template, "<apikey>") then
                if not api.api_key or api.api_key == "" then
                    can_try = false
                else
                    template = template:gsub("<apikey>", api.api_key)
                end
            end

            if can_try then
                local url = template:gsub("<appid>", tostring(appid))
                local ok_url = safety.validate_http_url(url)
                local success = false

                if ok_url then
                    if string.lower(name) == "morrenus" then
                        local status_url = "https://hubcapmanifest.com/api/v1/status/" .. tostring(appid) .. "?api_key=" .. tostring(morrenus_api_key)
                        local s_resp = http_client.get(status_url, { headers = { ["User-Agent"] = config.USER_AGENT }, timeout = 5 })
                        if s_resp and s_resp.status == success_code then
                            success = true
                        end
                    else
                        local resp = http_client.head(url, { headers = { ["User-Agent"] = config.USER_AGENT }, timeout = 5 })
                        if resp and resp.status == success_code then
                            success = true
                        else
                            local get_resp = http_client.get(url, { headers = { ["User-Agent"] = config.USER_AGENT }, timeout = 5 })
                            if get_resp and get_resp.status == success_code then
                                success = true
                            end
                        end
                    end

                    if success then
                        target_url = url
                        target_name = name
                        break
                    end
                else
                    logger.warn("OpenLuaTools: Skipping unsafe API URL for " .. tostring(name))
                end
            end
        end
        if not target_url then error("Not available on any API") end

        _set_download_state(appid, { status = "downloading", currentApi = target_name })
        _launch_async_download(appid, target_url, dest_path, extract_dir)
    end)

    if not ok then
        logger.warn("OpenLuaTools: start_add_via_openluatools crashed - " .. tostring(res))
        _set_download_state(appid, { status = "failed", error = tostring(res) })
        return { success = false, error = tostring(res) }
    end

    return { success = true }
end

function downloads.check_apis_for_app(appid)
    if type(appid) == "string" then appid = tonumber(appid) end
    if not appid then return { success = false, error = "Invalid appid" } end

    local apis = api_manifest.load_api_manifest()
    if not apis or #apis == 0 then
        return { success = true, results = {} }
    end

    local results = {}
    local morrenus_api_key = settings_manager.get_morrenus_api_key()

    for _, api in ipairs(apis) do
        local name = api.name or "Unknown"
        local template = api.url or ""
        local success_code = tonumber(api.success_code) or 200
        local can_try = true

        if string.find(template, "<moapikey>") then
            if not morrenus_api_key or morrenus_api_key == "" then
                can_try = false
            else
                template = template:gsub("<moapikey>", morrenus_api_key)
            end
        end
        if string.find(template, "<apikey>") then
            if not api.api_key or api.api_key == "" then
                can_try = false
            else
                template = template:gsub("<apikey>", api.api_key)
            end
        end

        if can_try then
            local url = template:gsub("<appid>", tostring(appid))
            local ok_url = safety.validate_http_url(url)
            local available = false

            if ok_url then
                if string.lower(name) == "morrenus" then
                    local status_url = "https://hubcapmanifest.com/api/v1/status/" .. tostring(appid) .. "?api_key=" .. tostring(morrenus_api_key)
                    local resp = http_client.get(status_url, { headers = { ["User-Agent"] = config.USER_AGENT }, timeout = 5 })
                    if resp and resp.status == success_code then
                        available = true
                    end
                else
                    local success = false
                    local resp = http_client.head(url, { headers = { ["User-Agent"] = config.USER_AGENT }, timeout = 5 })
                    if resp and resp.status == success_code then
                        success = true
                    else
                        -- Fallback to GET if HEAD fails
                        local get_resp = http_client.get(url, { headers = { ["User-Agent"] = config.USER_AGENT }, timeout = 5 })
                        if get_resp and get_resp.status == success_code then
                            success = true
                        end
                    end

                    if success then
                        available = true
                    end
                end
            else
                logger.warn("OpenLuaTools: Skipping unsafe API URL for " .. tostring(name))
            end

            table.insert(results, {
                name = name,
                available = available,
                url = available and url or nil
            })
        end
    end

    return { success = true, results = results }
end

return downloads
