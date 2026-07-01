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

local ACTIVE_STATUSES = {
    checking = true,
    queued = true,
    downloading = true,
    downloaded = true,
    extracting = true,
    processing = true,
    installing = true,
}

local function _now()
    if os and type(os.time) == "function" then
        return os.time()
    end
    return 0
end

local function _quote_arg(value)
    return '"' .. tostring(value or ""):gsub('"', '') .. '"'
end

local function _json(data)
    local ok, encoded = pcall(cjson.encode, data)
    if ok and encoded then return encoded end
    return '{"status":"failed","error":"serialization failed"}'
end

local function _write_state_file(path, data)
    m_utils.write_file(path, _json(data))
end

local function _download_paths(appid)
    local dest_root = utils.ensure_temp_download_dir()
    return {
        root = dest_root,
        zip = fs.join(dest_root, tostring(appid) .. ".zip"),
        extract_dir = fs.join(dest_root, "extracted_" .. tostring(appid)),
        state_file = fs.join(dest_root, tostring(appid) .. "_state.json"),
        list_file = fs.join(dest_root, tostring(appid) .. "_entries.txt"),
    }
end

local function _remove_temp_path(root, path)
    if path and path ~= "" and fs.exists(path) and safety.path_within(root, path) then
        pcall(fs.remove, path)
        if fs.exists(path) then
            pcall(fs.remove_all, path)
        end
    end
end

local function _cleanup_download_files(appid, keep_state)
    local p = _download_paths(appid)
    _remove_temp_path(p.root, p.zip)
    _remove_temp_path(p.root, p.extract_dir)
    _remove_temp_path(p.root, p.list_file)
    if not keep_state then
        _remove_temp_path(p.root, p.state_file)
    end
    _remove_temp_path(p.root, fs.join(p.root, tostring(appid) .. "_dl.ps1"))
    _remove_temp_path(p.root, fs.join(p.root, tostring(appid) .. "_dl.sh"))
end

local function _new_operation_id(appid)
    return tostring(appid) .. "-" .. tostring(_now()) .. "-" .. tostring(math.random(100000, 999999))
end

local function _is_stale(state)
    if not state or not ACTIVE_STATUSES[state.status] then return false end
    local started_at = tonumber(state.startedAt or state.updatedAt or 0) or 0
    if started_at <= 0 then return false end
    local stale_after = tonumber(config.DOWNLOAD_STALE_TIMEOUT_SECONDS) or 1200
    return (_now() - started_at) > stale_after
end

local function _set_download_state(appid, update)
    if type(appid) == "string" then appid = tonumber(appid) end
    if not DOWNLOAD_STATE[appid] then DOWNLOAD_STATE[appid] = {} end
    update.updatedAt = update.updatedAt or _now()
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

local function _validate_archive_listing(zip_path, list_path)
    _remove_temp_path(fs.parent_path(list_path), list_path)

    local is_windows = m_utils.getenv("OS") == "Windows_NT"
    local cmd
    if is_windows then
        cmd = "tar.exe -tf " .. _quote_arg(zip_path) .. " > " .. _quote_arg(list_path)
    else
        cmd = "unzip -Z1 " .. _quote_arg(zip_path) .. " > " .. _quote_arg(list_path)
    end

    m_utils.exec(cmd)

    local listing = m_utils.read_file(list_path) or ""
    _remove_temp_path(fs.parent_path(list_path), list_path)
    if listing == "" then
        return false, "Failed to inspect downloaded archive"
    end

    local count = 0
    for raw_entry in listing:gmatch("[^\r\n]+") do
        local entry = tostring(raw_entry or ""):gsub("\\", "/")
        entry = entry:gsub("^%s+", ""):gsub("%s+$", "")
        if entry ~= "" then
            local ok_entry, entry_err = safety.validate_relative_archive_path(entry)
            if not ok_entry then
                return false, "Unsafe archive entry: " .. tostring(entry) .. " (" .. tostring(entry_err) .. ")"
            end
            count = count + 1
        end
    end

    if count == 0 then
        return false, "Downloaded archive did not list any entries"
    end

    return true
end

local function _extract_archive(zip_path, extract_dir)
    local p_root = fs.parent_path(zip_path)
    _remove_temp_path(p_root, extract_dir)
    fs.create_directories(extract_dir)

    local is_windows = m_utils.getenv("OS") == "Windows_NT"
    local cmd
    if is_windows then
        cmd = "tar.exe -xf " .. _quote_arg(zip_path) .. " -C " .. _quote_arg(extract_dir)
    else
        cmd = "unzip -o -q " .. _quote_arg(zip_path) .. " -d " .. _quote_arg(extract_dir)
    end

    m_utils.exec(cmd)

    local ok_list, entries = pcall(fs.list_recursive, extract_dir)
    if not ok_list or not entries then
        return false, "Failed to inspect extracted archive"
    end

    local file_count = 0
    for _, entry in ipairs(entries) do
        if not entry.is_directory then
            file_count = file_count + 1
            local ok_path, rel_or_err = safety.validate_extracted_file(extract_dir, entry.path)
            if not ok_path then
                return false, "Unsafe archive entry: " .. tostring(entry.path) .. " (" .. tostring(rel_or_err) .. ")"
            end
        end
    end

    if file_count == 0 then
        return false, "Downloaded archive did not extract any files"
    end

    return true
end

local function _finalize_failed(appid, message)
    local state = _get_download_state(appid)
    local p = _download_paths(appid)
    _set_download_state(appid, {
        status = "failed",
        success = false,
        error = tostring(message or "Download failed"),
    })
    _write_state_file(p.state_file, {
        operationId = state.operationId,
        status = "failed",
        error = tostring(message or "Download failed"),
    })
    _cleanup_download_files(appid, true)
end

function downloads.get_add_status(appid)
    if type(appid) == "string" then appid = tonumber(appid) end

    local paths_for_app = _download_paths(appid)
    local state_file = paths_for_app.state_file
    local memory_state = _get_download_state(appid)

    if fs.exists(state_file) then
        local content = m_utils.read_file(state_file)
        if content and content ~= "" then
            local success, data = pcall(cjson.decode, content)
            if success and type(data) == "table" and data.status then
                local current_operation = memory_state.operationId
                if not data.operationId or not current_operation or data.operationId == current_operation then
                    _set_download_state(appid, {
                        status = data.status,
                        error = data.error,
                        operationId = data.operationId or current_operation,
                    })
                    memory_state = _get_download_state(appid)

                    if data.status == "downloaded" then
                        _set_download_state(appid, { status = "processing" })
                        local ok_process, err_process = pcall(function()
                            local ok_listing, listing_err = _validate_archive_listing(paths_for_app.zip, paths_for_app.list_file)
                            if not ok_listing then error(listing_err) end

                            _set_download_state(appid, { status = "extracting" })
                            local ok_extract, extract_err = _extract_archive(paths_for_app.zip, paths_for_app.extract_dir)
                            if not ok_extract then error(extract_err) end

                            local apiName = _get_download_state(appid).currentApi or "Unknown"
                            downloads._finalize_install_lua(appid, paths_for_app.extract_dir, paths_for_app.zip, apiName)
                        end)

                        if not ok_process then
                            _finalize_failed(appid, err_process)
                        else
                            _cleanup_download_files(appid, false)
                        end
                    elseif data.status == "extracted" then
                        local apiName = _get_download_state(appid).currentApi or "Unknown"
                        local ok_final, res = pcall(downloads._finalize_install_lua, appid, paths_for_app.extract_dir, paths_for_app.zip, apiName)
                        if not ok_final then
                            _finalize_failed(appid, res)
                        else
                            _cleanup_download_files(appid, false)
                        end
                    elseif data.status == "failed" then
                        _finalize_failed(appid, data.error or "Download failed")
                    elseif data.status == "cancelled" then
                        _set_download_state(appid, { status = "cancelled", success = false, error = data.error or "Cancelled by user" })
                        _cleanup_download_files(appid, false)
                    end
                end
            end
        end
    end

    local state = _get_download_state(appid)
    if _is_stale(state) then
        _finalize_failed(appid, "Download timed out")
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

local function _launch_async_download(appid, url, operation_id)
    local ok_url, url_err = safety.validate_http_url(url)
    if not ok_url then error(url_err) end

    local is_windows = m_utils.getenv("OS") == "Windows_NT"
    local p = _download_paths(appid)
    local connect_timeout = tonumber(config.DOWNLOAD_CONNECT_TIMEOUT_SECONDS) or 15
    local max_time = tonumber(config.DOWNLOAD_MAX_TIME_SECONDS) or 900
    local retries = tonumber(config.DOWNLOAD_RETRIES) or 2

    _cleanup_download_files(appid, false)
    _write_state_file(p.state_file, { operationId = operation_id, status = "downloading" })
    if not fs.exists(p.root) then fs.create_directories(p.root) end

    if is_windows then
        local cmd = string.format(
            'cmd.exe /C start "OpenLuaTools Downloader" cmd.exe /C "color 0B && echo OpenLuaTools is downloading the requested files... && echo Please keep this window open until it closes automatically. && echo. && (echo {"operationId":"%s","status":"downloading"} > "%s" && curl.exe -# --fail --location --connect-timeout %d --max-time %d --retry %d --retry-delay 2 --retry-all-errors -A "%s" "%s" -o "%s" && echo {"operationId":"%s","status":"downloaded"} > "%s") || (echo. && echo ERROR: Download failed or timed out! && echo {"operationId":"%s","status":"failed","error":"Download failed"} > "%s" && timeout /t 5)"',
            operation_id, p.state_file,
            connect_timeout, max_time, retries, config.USER_AGENT, url, p.zip,
            operation_id, p.state_file,
            operation_id, p.state_file
        )
        m_utils.exec(cmd)
    else
        local sh_path = fs.join(paths.get_plugin_dir(), "backend", "scripts", "downloader.sh")
        m_utils.exec('chmod +x "' .. sh_path .. '"')
        local cmd = string.format(
            'nohup bash "%s" "%s" "%s" "%s" "%s" "%s" download-only %d %d %d "%s" > /dev/null 2>&1 &',
            sh_path, url, p.zip, p.extract_dir, p.state_file, operation_id,
            connect_timeout, max_time, retries, config.USER_AGENT
        )
        m_utils.exec(cmd)
    end
end

local function _request(method, url, options)
    local fn = http_client[method]
    if type(fn) ~= "function" then
        return nil, "Unsupported HTTP method: " .. tostring(method)
    end

    local ok, resp = pcall(fn, url, options)
    if ok then
        return resp, nil
    end
    return nil, tostring(resp)
end

local function _error_type(message)
    local lower = tostring(message or ""):lower()
    if lower:find("timeout", 1, true) or lower:find("timed out", 1, true) then
        return "timeout"
    end
    return "error"
end

local function _result(name, available, url, status, status_code, error, error_type)
    return {
        name = name,
        available = available == true,
        url = available and url or nil,
        status = status,
        statusCode = status_code,
        error = error,
        errorType = error_type,
    }
end

local function _classify_response(name, url, resp, req_err, success_code, unavailable_code)
    if not resp then
        return nil, req_err or "No response"
    end

    local status_code = tonumber(resp.status)
    if not status_code then
        return nil, "No HTTP status"
    end

    if status_code == success_code or status_code == 200 or status_code == 206 then
        return _result(name, true, url, "available", status_code)
    end

    if status_code == unavailable_code or status_code == 404 then
        return _result(name, false, nil, "unavailable", status_code)
    end

    if status_code == 429 then
        return _result(name, false, nil, "error", status_code, "API rate limited the request", "rate_limited")
    end

    if status_code == 408 or status_code == 504 then
        return _result(name, false, nil, "error", status_code, "API request timed out", "timeout")
    end

    if status_code >= 500 then
        return _result(name, false, nil, "error", status_code, "API returned server error " .. tostring(status_code), "error")
    end

    return nil, "Inconclusive HTTP status " .. tostring(status_code)
end

local function _prepare_api(api, appid, morrenus_api_key)
    local name = tostring(api.name or "Unknown")
    local template = tostring(api.url or "")
    local success_code = tonumber(api.success_code) or 200
    local unavailable_code = tonumber(api.unavailable_code) or 404

    if template == "" then
        return nil, _result(name, false, nil, "error", nil, "API URL is empty", "error")
    end

    if string.find(template, "<moapikey>", 1, true) then
        if not morrenus_api_key or morrenus_api_key == "" then
            return nil, _result(name, false, nil, "skipped", nil, "Morrenus API key is missing", "missing_key")
        end
        template = template:gsub("<moapikey>", morrenus_api_key)
    end

    if string.find(template, "<apikey>", 1, true) then
        if not api.api_key or api.api_key == "" then
            return nil, _result(name, false, nil, "skipped", nil, "API key is missing", "missing_key")
        end
        template = template:gsub("<apikey>", api.api_key)
    end

    local url = template:gsub("<appid>", tostring(appid))
    local ok_url, url_err = safety.validate_http_url(url)
    if not ok_url then
        logger.warn("OpenLuaTools: Skipping unsafe API URL for " .. tostring(name) .. ": " .. tostring(url_err))
        return nil, _result(name, false, nil, "error", nil, url_err, "error")
    end

    return {
        name = name,
        url = url,
        success_code = success_code,
        unavailable_code = unavailable_code,
    }
end

local function _probe_morrenus_api(prepared, appid, morrenus_api_key)
    local status_url = "https://hubcapmanifest.com/api/v1/status/" .. tostring(appid) .. "?api_key=" .. tostring(morrenus_api_key)
    local resp, req_err = _request("get", status_url, {
        headers = { ["User-Agent"] = config.USER_AGENT },
        timeout = config.API_PROBE_TIMEOUT_SECONDS or 12,
    })

    local result, classify_err = _classify_response(
        prepared.name,
        prepared.url,
        resp,
        req_err,
        prepared.success_code,
        prepared.unavailable_code
    )
    if result then return result end

    return _result(
        prepared.name,
        false,
        nil,
        "error",
        resp and tonumber(resp.status) or nil,
        classify_err or req_err or "Morrenus status check failed",
        _error_type(classify_err or req_err)
    )
end

local function _probe_direct_zip_api(prepared)
    local timeout = config.API_PROBE_TIMEOUT_SECONDS or 12
    local base_headers = {
        ["User-Agent"] = config.USER_AGENT,
        ["Accept"] = "application/zip,*/*",
    }

    local head_resp, head_err = _request("head", prepared.url, {
        headers = base_headers,
        timeout = timeout,
    })

    local head_result, head_classify_err = _classify_response(
        prepared.name,
        prepared.url,
        head_resp,
        head_err,
        prepared.success_code,
        prepared.unavailable_code
    )
    if head_result and (
        head_result.status == "available" or
        head_result.status == "unavailable" or
        head_result.errorType == "rate_limited" or
        head_result.statusCode == 408 or
        head_result.statusCode == 504 or
        (head_result.statusCode and head_result.statusCode >= 500)
    ) then
        return head_result
    end

    local range_headers = {
        ["User-Agent"] = config.USER_AGENT,
        ["Accept"] = "application/zip,*/*",
        ["Range"] = "bytes=0-0",
    }
    local get_resp, get_err = _request("get", prepared.url, {
        headers = range_headers,
        timeout = timeout,
    })

    local get_result, get_classify_err = _classify_response(
        prepared.name,
        prepared.url,
        get_resp,
        get_err,
        prepared.success_code,
        prepared.unavailable_code
    )
    if get_result then return get_result end

    local message = get_classify_err or get_err or head_classify_err or head_err or "API probe failed"
    return _result(
        prepared.name,
        false,
        nil,
        "error",
        get_resp and tonumber(get_resp.status) or head_resp and tonumber(head_resp.status) or nil,
        message,
        _error_type(message)
    )
end

local function _probe_api(api, appid, morrenus_api_key)
    local prepared, skipped_or_error = _prepare_api(api, appid, morrenus_api_key)
    if not prepared then return skipped_or_error end

    if string.lower(prepared.name) == "morrenus" then
        return _probe_morrenus_api(prepared, appid, morrenus_api_key)
    end

    return _probe_direct_zip_api(prepared)
end

function downloads.start_add_via_openluatools_from_url(appid, url, apiName)
    if type(appid) == "string" then appid = tonumber(appid) end
    if not appid then return { success = false, error = "Invalid appid" } end

    logger.log("OpenLuaTools: StartAddViaOpenLuaToolsFromUrl appid=" .. tostring(appid) .. " api=" .. tostring(apiName))
    local operation_id = _new_operation_id(appid)
    _set_download_state(appid, {
        status = "downloading",
        currentApi = apiName,
        bytesRead = 0,
        totalBytes = 0,
        operationId = operation_id,
        startedAt = _now(),
        success = false,
        error = nil,
    })

    local ok, res = pcall(function()
        _launch_async_download(appid, url, operation_id)
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
    local operation_id = _new_operation_id(appid)
    _set_download_state(appid, {
        status = "queued",
        bytesRead = 0,
        totalBytes = 0,
        operationId = operation_id,
        startedAt = _now(),
        success = false,
        error = nil,
        apiErrors = {},
    })

    local apis = api_manifest.load_api_manifest()
    if not apis or #apis == 0 then
        _set_download_state(appid, { status = "failed", error = "No APIs available" })
        return { success = true }
    end

    local morrenus_api_key = settings_manager.get_morrenus_api_key()

    local ok, res = pcall(function()
        local target_url = nil
        local target_name = nil
        local api_errors = {}
        for _, api in ipairs(apis) do
            local result = _probe_api(api, appid, morrenus_api_key)
            if result and result.status == "error" then
                api_errors[result.name or "Unknown"] = {
                    type = result.errorType or "error",
                    code = result.statusCode,
                    message = result.error,
                }
                _set_download_state(appid, { apiErrors = api_errors })
            end

            if result and result.available and result.url then
                target_url = result.url
                target_name = result.name
                break
            end
        end
        if not target_url then
            local has_errors = false
            for _ in pairs(api_errors) do
                has_errors = true
                break
            end
            if has_errors then
                error("No API could be checked successfully; one or more APIs failed or were rate limited")
            end
            error("Not available on any API")
        end

        _set_download_state(appid, { status = "downloading", currentApi = target_name })
        _launch_async_download(appid, target_url, operation_id)
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
        local result = _probe_api(api, appid, morrenus_api_key)
        if result then
            table.insert(results, result)
        end
    end

    return { success = true, results = results }
end

function downloads.cancel_add_via_openluatools(appid)
    if type(appid) == "string" then appid = tonumber(appid) end
    if not appid then return { success = false, error = "Invalid appid" } end

    local operation_id = _new_operation_id(appid)
    local p = _download_paths(appid)
    _set_download_state(appid, {
        status = "cancelled",
        success = false,
        error = "Cancelled by user",
        operationId = operation_id,
    })
    _write_state_file(p.state_file, {
        operationId = operation_id,
        status = "cancelled",
        error = "Cancelled by user",
    })
    _cleanup_download_files(appid, false)

    return { success = true }
end

return downloads
