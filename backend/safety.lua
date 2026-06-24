local fs = require("fs")
local m_utils = require("utils")

local safety = {}

local UNSAFE_URL_CHARS = {
    '"', "'", "`", "<", ">", "|", "&", "^", "!", "%"
}

local UNSAFE_PATH_CHARS = {
    '"', "'", "`", "<", ">", "|", "&", "^", "!", ":", "*", "?"
}

local function has_control_chars(value)
    return tostring(value or ""):find("[%z\1-\31\127]") ~= nil
end

local function contains_any(value, chars)
    value = tostring(value or "")
    for _, ch in ipairs(chars) do
        if value:find(ch, 1, true) then
            return true
        end
    end
    return false
end

local function normalize_path(path)
    local abs = fs.absolute(tostring(path or ""))
    abs = abs:gsub("\\", "/")
    abs = abs:gsub("/+$", "")
    return abs
end

function safety.validate_http_url(url)
    url = tostring(url or "")
    if url == "" then
        return false, "URL is required"
    end

    local lower = url:lower()
    if lower:sub(1, 7) ~= "http://" and lower:sub(1, 8) ~= "https://" then
        return false, "Only http:// and https:// URLs are allowed"
    end

    if has_control_chars(url) or contains_any(url, UNSAFE_URL_CHARS) then
        return false, "URL contains unsafe characters"
    end

    return true
end

function safety.path_within(base, path)
    local base_abs = normalize_path(base)
    local path_abs = normalize_path(path)

    if base_abs == "" or path_abs == "" then
        return false
    end

    local base_lower = base_abs:lower()
    local path_lower = path_abs:lower()
    return path_lower == base_lower or path_lower:sub(1, #base_lower + 1) == base_lower .. "/"
end

function safety.relative_path(base, path)
    local base_abs = normalize_path(base)
    local path_abs = normalize_path(path)
    local base_lower = base_abs:lower()
    local path_lower = path_abs:lower()

    if path_lower == base_lower then
        return ""
    end

    if path_lower:sub(1, #base_lower + 1) ~= base_lower .. "/" then
        return nil
    end

    return path_abs:sub(#base_abs + 2)
end

function safety.validate_relative_archive_path(path)
    path = tostring(path or ""):gsub("\\", "/")

    if path == "" then
        return false, "empty archive path"
    end
    if has_control_chars(path) or contains_any(path, UNSAFE_PATH_CHARS) then
        return false, "unsafe archive path characters"
    end
    if path:sub(1, 1) == "/" or path:match("^%a:[/]") then
        return false, "absolute archive paths are not allowed"
    end

    for segment in path:gmatch("[^/]+") do
        if segment == "." or segment == ".." or segment == "" then
            return false, "relative traversal is not allowed"
        end
    end

    if path:find("//", 1, true) then
        return false, "empty path segments are not allowed"
    end

    return true
end

function safety.validate_extracted_file(base_dir, file_path)
    if not safety.path_within(base_dir, file_path) then
        return false, "extracted file escaped the extraction directory"
    end

    local rel = safety.relative_path(base_dir, file_path)
    if not rel then
        return false, "could not resolve extracted file path"
    end

    local ok, err = safety.validate_relative_archive_path(rel)
    if not ok then
        return false, err
    end

    return true, rel
end

function safety.is_expected_lua_filename(name, appid)
    return tostring(name or "") == tostring(appid) .. ".lua"
end

function safety.is_manifest_filename(name)
    return tostring(name or ""):match("^%d+_%d+%.manifest$") ~= nil
end

function safety.copy_file(src, dest, allowed_dest_root)
    if allowed_dest_root and not safety.path_within(allowed_dest_root, dest) then
        return false, "destination escaped the allowed root"
    end

    local parent = fs.parent_path(dest)
    if parent and parent ~= "" and not fs.exists(parent) then
        fs.create_directories(parent)
    end

    local content = m_utils.read_file(src)
    if not content then
        return false, "failed to read source file"
    end

    m_utils.write_file(dest, content)
    return true
end

return safety
