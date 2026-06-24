local m_utils = require("utils")
local fs = require("fs")
local http_client = require("http_client")
local logger = require("plugin_logger")
local utils = require("plugin_utils")
local paths = require("paths")
local cjson = require("json")
local safety = require("safety")

local fixes = {}

local function _fix_paths(appid)
    local dest_root = utils.ensure_temp_download_dir()
    return {
        dest_root = dest_root,
        dest_zip = fs.join(dest_root, "fix_" .. tostring(appid) .. ".zip"),
        state_file = fs.join(dest_root, "fix_" .. tostring(appid) .. "_state.json"),
        meta_file = fs.join(dest_root, "fix_" .. tostring(appid) .. "_meta.json"),
        extract_dir = fs.join(dest_root, "fix_extracted_" .. tostring(appid)),
    }
end

local function _write_json(path, data)
    local ok, content = pcall(cjson.encode, data)
    if not ok then return false end
    m_utils.write_file(path, content)
    return true
end

function fixes.check_for_fixes(appid)
    if type(appid) == "string" then appid = tonumber(appid) end
    local result = {
        success = true,
        appid = appid,
        gameName = "Unknown Game (" .. tostring(appid) .. ")",
        genericFix = { status = 0, available = false },
        onlineFix = { status = 0, available = false }
    }

    local FIXES_INDEX_URL = "https://index.openluatools.work/fixes-index.json"
    local resp = http_client.get(FIXES_INDEX_URL, { timeout = 10 })
    if resp and resp.status == 200 and resp.body then
        local data = utils.decode_json(resp.body)
        if type(data) == "table" then
            local generic_url = "https://files.luatools.work/GameBypasses/" .. tostring(appid) .. ".zip"
            local online_url = "https://files.luatools.work/OnlineFix1/" .. tostring(appid) .. ".zip"

            local has_generic = false
            for _, v in ipairs(data.genericFixes or {}) do if tonumber(v) == appid then has_generic = true break end end
            if has_generic then
                result.genericFix.status = 200
                result.genericFix.available = true
                result.genericFix.url = generic_url
            else
                result.genericFix.status = 404
            end

            local has_online = false
            for _, v in ipairs(data.onlineFixes or {}) do if tonumber(v) == appid then has_online = true break end end
            if has_online then
                result.onlineFix.status = 200
                result.onlineFix.available = true
                result.onlineFix.url = online_url
            else
                result.onlineFix.status = 404
            end
        end
    end

    return result
end

function fixes.apply_game_fix(appid, download_url, install_path, fix_type, game_name)
    local ok_url, url_err = safety.validate_http_url(download_url)
    if not ok_url then return { success = false, error = url_err } end

    if not install_path or install_path == "" or not fs.exists(install_path) then
        return { success = false, error = "Game install path not found" }
    end

    local p = _fix_paths(appid)
    local install_root = fs.absolute(install_path)

    logger.log("OpenLuaTools: Applying fix to " .. tostring(install_path))
    m_utils.write_file(p.state_file, '{"status": "downloading"}')
    _write_json(p.meta_file, { installPath = install_root, fixType = fix_type or "", gameName = game_name or "" })

    if fs.exists(p.extract_dir) then pcall(fs.remove_all, p.extract_dir) end
    fs.create_directories(p.extract_dir)

    local is_windows = m_utils.getenv("OS") == "Windows_NT"
    if is_windows then
        local cmd = string.format(
            'cmd.exe /C start "OpenLuaTools Downloader" cmd.exe /C "color 0B && echo OpenLuaTools is downloading the requested files... && echo Please keep this window open until it closes automatically. && echo. && (echo {"status": "downloading"} > "%s" && curl.exe -# -L -A "discord(dot)gg/luatools" "%s" -o "%s" && echo {"status": "extracting"} > "%s" && echo. && echo Extracting files... && tar.exe -xf "%s" -C "%s" && echo {"status": "extracted"} > "%s") || (echo. && echo ERROR: Download or extraction failed! && echo {"status": "failed"} > "%s" && timeout /t 5)"',
            p.state_file, download_url, p.dest_zip, p.state_file, p.dest_zip, p.extract_dir, p.state_file, p.state_file
        )
        m_utils.exec(cmd)
    else
        local sh_path = fs.join(paths.get_plugin_dir(), "backend", "scripts", "downloader.sh")
        m_utils.exec('chmod +x "' .. sh_path .. '"')
        local cmd = string.format(
            'nohup bash "%s" "%s" "%s" "%s" "%s" > /dev/null 2>&1 &',
            sh_path, download_url, p.dest_zip, p.extract_dir, p.state_file
        )
        m_utils.exec(cmd)
    end

    return { success = true }
end

function fixes._finalize_apply_fix(appid, extract_dir, install_path)
    if not install_path or install_path == "" or not fs.exists(install_path) then
        error("Game install path not found")
    end
    if not extract_dir or extract_dir == "" or not fs.exists(extract_dir) then
        error("Extracted fix directory not found")
    end

    local install_root = fs.absolute(install_path)
    local copied = 0
    local success_list, files = pcall(fs.list_recursive, extract_dir)
    if not success_list or not files then
        error("Failed to inspect extracted fix archive")
    end

    for _, entry in ipairs(files) do
        if not entry.is_directory then
            local ok_path, rel_or_err = safety.validate_extracted_file(extract_dir, entry.path)
            if not ok_path then
                error("Unsafe fix archive entry: " .. tostring(entry.path) .. " (" .. tostring(rel_or_err) .. ")")
            end

            local dest = fs.join(install_root, rel_or_err)
            if not safety.path_within(install_root, dest) then
                error("Fix archive destination escaped the game directory")
            end

            local ok_copy, copy_err = safety.copy_file(entry.path, dest, install_root)
            if not ok_copy then
                error("Failed to copy fix file: " .. tostring(copy_err))
            end

            copied = copied + 1
        end
    end

    if copied == 0 then
        error("Fix archive did not contain any files")
    end

    return { copied = copied }
end

function fixes.get_apply_status(appid)
    local p = _fix_paths(appid)

    if not fs.exists(p.state_file) then
        return { success = true, state = { status = "done" } }
    end

    local content = m_utils.read_file(p.state_file)
    if content and content ~= "" then
        local success, data = pcall(cjson.decode, content)
        if success and type(data) == "table" and data.status then
            if data.status == "extracted" then
                local meta = utils.read_json(p.meta_file)
                local ok_final, res = pcall(fixes._finalize_apply_fix, appid, p.extract_dir, meta.installPath)
                if ok_final then
                    data.status = "done"
                    data.copied = res.copied
                else
                    data.status = "failed"
                    data.error = tostring(res)
                end
                pcall(fs.remove, p.state_file)
                pcall(fs.remove, p.meta_file)
                pcall(fs.remove, p.dest_zip)
                pcall(fs.remove_all, p.extract_dir)
            elseif data.status == "failed" then
                pcall(fs.remove, p.state_file)
                pcall(fs.remove, p.meta_file)
                pcall(fs.remove, p.dest_zip)
                pcall(fs.remove_all, p.extract_dir)
            end
            return { success = true, state = data }
        end
    end

    return { success = true, state = { status = "downloading" } }
end

return fixes
