local m_utils = require("utils")
local fs = require("fs")
local http_client = require("http_client")
local config = require("config")
local paths = require("paths")
local utils = require("plugin_utils")
local safety = require("safety")

local auto_update = {}

local ALLOWED_UPDATE_ROOTS = {
    ["plugin.json"] = true,
    ["readme.md"] = true,
    ["README.md"] = true,
    ["CHANGELOG.md"] = true,
    ["backend"] = true,
    ["public"] = true,
    [".millennium"] = true,
    ["LICENSE"] = true,
    ["LICENSE.md"] = true,
}

local function remove_path(path)
    if path and path ~= "" and fs.exists(path) then
        pcall(fs.remove, path)
        if fs.exists(path) then
            pcall(fs.remove_all, path)
        end
    end
end

local function quote_arg(value)
    return '"' .. tostring(value or ""):gsub('"', '') .. '"'
end

local function compare_versions(a, b)
    local ta = utils.parse_version(a)
    local tb = utils.parse_version(b)
    local len = math.max(#ta, #tb)
    for i = 1, len do
        local ai = ta[i] or 0
        local bi = tb[i] or 0
        if ai < bi then return -1
        elseif ai > bi then return 1
        end
    end
    return 0
end

local function validate_update_path(rel_path)
    local rel = tostring(rel_path or ""):gsub("\\", "/")
    local ok, err = safety.validate_relative_archive_path(rel)
    if not ok then return false, err end

    if rel == "backend/temp_dl" or rel:sub(1, #"backend/temp_dl/") == "backend/temp_dl/" then
        return false, "update archive cannot write plugin temp files"
    end

    local top = rel:match("^([^/]+)")
    if not top or not ALLOWED_UPDATE_ROOTS[top] then
        return false, "unexpected top-level update path: " .. tostring(top or rel)
    end

    return true
end

local function inspect_extracted_archive(extract_dir)
    local ok_list, entries = pcall(fs.list_recursive, extract_dir)
    if not ok_list or not entries then
        return nil, nil, "Failed to inspect extracted update archive"
    end

    local top_dirs = {}
    local top_files = {}
    local entry_count = 0

    for _, entry in ipairs(entries) do
        entry_count = entry_count + 1
        local ok_path, rel_or_err = safety.validate_extracted_file(extract_dir, entry.path)
        if not ok_path then
            return nil, nil, "Unsafe update archive entry: " .. tostring(entry.path) .. " (" .. tostring(rel_or_err) .. ")"
        end

        local rel = tostring(rel_or_err):gsub("\\", "/")
        local top = rel:match("^([^/]+)")
        if top then
            if rel == top and not entry.is_directory then
                top_files[top] = true
            else
                top_dirs[top] = true
            end
        end
    end

    if entry_count == 0 then
        return nil, nil, "Update archive is empty"
    end

    if fs.exists(fs.join(extract_dir, "plugin.json")) then
        return entries, extract_dir
    end

    local single_dir = nil
    local dir_count = 0
    for name in pairs(top_dirs) do
        single_dir = name
        dir_count = dir_count + 1
    end
    for _ in pairs(top_files) do
        return nil, nil, "Update archive must contain plugin.json at its root"
    end

    if dir_count == 1 then
        local nested_root = fs.join(extract_dir, single_dir)
        if fs.exists(fs.join(nested_root, "plugin.json")) then
            return entries, nested_root
        end
    end

    return nil, nil, "Update archive must contain plugin.json at its root"
end

local function download_release_zip(zip_url, zip_path)
    remove_path(zip_path)
    local is_windows = m_utils.getenv("OS") == "Windows_NT"
    local cmd
    if is_windows then
        cmd = table.concat({
            "curl.exe -fL -A " .. quote_arg("OpenLuaTools-OpenSteamTool"),
            quote_arg(zip_url),
            "-o " .. quote_arg(zip_path),
        }, " ")
    else
        cmd = table.concat({
            "curl -fL -A " .. quote_arg("OpenLuaTools-OpenSteamTool"),
            "-o " .. quote_arg(zip_path),
            quote_arg(zip_url),
        }, " ")
    end

    m_utils.exec(cmd)

    if not fs.exists(zip_path) then
        return false, "Failed to download release asset"
    end

    return true
end

local function validate_archive_listing(zip_path, list_path)
    remove_path(list_path)
    local is_windows = m_utils.getenv("OS") == "Windows_NT"
    local cmd
    if is_windows then
        cmd = "tar.exe -tf " .. quote_arg(zip_path) .. " > " .. quote_arg(list_path)
    else
        cmd = "unzip -Z1 " .. quote_arg(zip_path) .. " > " .. quote_arg(list_path)
    end

    m_utils.exec(cmd)

    local listing = m_utils.read_file(list_path) or ""
    remove_path(list_path)
    if listing == "" then
        return false, "Failed to inspect release asset entries"
    end

    local count = 0
    for raw_entry in listing:gmatch("[^\r\n]+") do
        local entry = tostring(raw_entry or ""):gsub("\\", "/")
        entry = entry:gsub("^%s+", ""):gsub("%s+$", "")
        if entry ~= "" then
            local ok_entry, entry_err = safety.validate_relative_archive_path(entry)
            if not ok_entry then
                return false, "Unsafe update archive entry: " .. tostring(entry) .. " (" .. tostring(entry_err) .. ")"
            end
            count = count + 1
        end
    end

    if count == 0 then
        return false, "Update archive did not list any entries"
    end

    return true
end

local function extract_release_zip(zip_path, extract_dir)
    remove_path(extract_dir)
    fs.create_directories(extract_dir)

    local is_windows = m_utils.getenv("OS") == "Windows_NT"
    local cmd
    if is_windows then
        cmd = "tar.exe -xf " .. quote_arg(zip_path) .. " -C " .. quote_arg(extract_dir)
    else
        cmd = "unzip -o -q " .. quote_arg(zip_path) .. " -d " .. quote_arg(extract_dir)
    end

    m_utils.exec(cmd)

    local _, package_root, inspect_err = inspect_extracted_archive(extract_dir)
    if not package_root then
        return false, inspect_err
    end

    return true, package_root
end

local function download_and_extract(zip_url, zip_path, extract_dir)
    local ok_download, download_err = download_release_zip(zip_url, zip_path)
    if not ok_download then return false, download_err end

    local list_path = fs.join(fs.parent_path(zip_path), "update_entries.txt")
    local ok_listing, listing_err = validate_archive_listing(zip_path, list_path)
    if not ok_listing then return false, listing_err end

    return extract_release_zip(zip_path, extract_dir)
end

local function copy_update_files(package_root)
    local plugin_root = paths.get_plugin_dir()
    local ok_list, entries = pcall(fs.list_recursive, package_root)
    if not ok_list or not entries then
        return false, "Failed to inspect validated update package"
    end

    local copied = 0
    for _, entry in ipairs(entries) do
        if not entry.is_directory then
            local ok_path, rel_or_err = safety.validate_extracted_file(package_root, entry.path)
            if not ok_path then
                return false, "Unsafe update package entry: " .. tostring(entry.path) .. " (" .. tostring(rel_or_err) .. ")"
            end

            local ok_update_path, update_path_err = validate_update_path(rel_or_err)
            if not ok_update_path then
                return false, update_path_err
            end

            local dest = fs.join(plugin_root, rel_or_err)
            local ok_copy, copy_err = safety.copy_file(entry.path, dest, plugin_root)
            if not ok_copy then
                return false, "Failed to copy update file: " .. tostring(copy_err)
            end
            copied = copied + 1
        end
    end

    if copied == 0 then
        return false, "Update package did not contain files"
    end

    return true, copied
end

function auto_update.check_for_updates_now()
    local cfg_path = paths.backend_path(config.UPDATE_CONFIG_FILE)
    local cfg = utils.read_json(cfg_path)

    local latest_version = ""
    local zip_url = ""

    local gh_cfg = cfg.github
    if gh_cfg then
        local owner = gh_cfg.owner or ""
        local repo = gh_cfg.repo or ""
        local asset_name = gh_cfg.asset_name or "OpenSteamToolPlugin.zip"
        local tag = gh_cfg.tag or ""
        local tag_prefix = gh_cfg.tag_prefix or ""

        if owner == "" or repo == "" then
            return { success = false, error = "GitHub updater owner/repo is not configured" }
        end

        local endpoint = "https://api.github.com/repos/" .. owner .. "/" .. repo .. "/releases/latest"
        if tag ~= "" then
            endpoint = "https://api.github.com/repos/" .. owner .. "/" .. repo .. "/releases/tags/" .. tag
        end

        local resp = http_client.get(endpoint, {
            headers = {
                ["Accept"] = "application/vnd.github+json",
                ["User-Agent"] = "OpenLuaTools-Updater"
            },
            timeout = 10
        })
        if resp and resp.status == 200 and resp.body then
            local data = utils.decode_json(resp.body)
            local tag_name = data.tag_name or ""
            latest_version = tag_name ~= "" and tag_name or (data.name or "")
            if tag_prefix ~= "" and latest_version:sub(1, #tag_prefix) == tag_prefix then
                latest_version = latest_version:sub(#tag_prefix + 1)
            end

            for _, asset in ipairs(data.assets or {}) do
                if asset.name == asset_name then
                    zip_url = asset.browser_download_url
                    break
                end
            end
        end
    end

    if latest_version == "" or zip_url == "" then
        return { success = false, error = "Manifest missing version or zip_url" }
    end

    local ok_url, url_err = safety.validate_http_url(zip_url)
    if not ok_url then
        return { success = false, error = url_err }
    end

    local current_version = utils.get_plugin_version()

    if compare_versions(latest_version, current_version) <= 0 then
        return { success = true, message = "Up-to-date (current " .. current_version .. ")" }
    end

    local temp_root = utils.ensure_temp_download_dir()
    local pending_zip = fs.join(temp_root, config.UPDATE_PENDING_ZIP)
    local extract_dir = fs.join(temp_root, "update_extract")

    local ok_extract, package_root_or_err = download_and_extract(zip_url, pending_zip, extract_dir)
    if not ok_extract then
        remove_path(pending_zip)
        remove_path(extract_dir)
        return { success = false, error = package_root_or_err }
    end

    local ok_copy, copied_or_err = copy_update_files(package_root_or_err)
    remove_path(pending_zip)
    remove_path(extract_dir)
    if not ok_copy then
        return { success = false, error = copied_or_err }
    end

    local msg = "OpenLuaTools updated to " .. latest_version .. ". Reload OpenSteamTool/Millennium to use the new files."
    return { success = true, message = msg }
end

function auto_update.apply_pending_update_if_any()
    return ""
end

return auto_update
