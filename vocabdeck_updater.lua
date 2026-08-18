-- VocabDeck OTA update checker.
--
-- Fetches the latest release from GitHub, compares versions, and if a newer
-- version is available, downloads, verifies, and installs it.
--
-- Uses Trapper:dismissableRunInSubprocess() for all network operations so the
-- UI thread is never blocked (network calls run in a separate OS process).
local _ = require("gettext")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")
local JSON = require("json")
local ltn12 = require("ltn12")
local http = require("socket.http")
local ffiUtil = require("ffi/util")
local Device = require("device")
local socketutil = require("socketutil")
local UIManager = require("ui/uimanager")
local NetworkMgr = require("ui/network/manager")
local Trapper = require("ui/trapper")
local InfoMessage = require("ui/widget/infomessage")
local ConfirmBox = require("ui/widget/confirmbox")
local T = ffiUtil.template
local socket = require("socket")

local Updater = {}
local PRESERVED_LOCAL_FILES = {
    "vocabdeck_apikeys.lua",
    "vocabdeck_configuration.lua",
}

-- ── Helpers ─────────────────────────────────────────────────────────────────

local function getPluginDir()
    return debug.getinfo(1, "S").source:match("@(.+%.koplugin)/")
end

local function dbg(...)
    logger.dbg("[vocabdeck:updater]", ...)
end

local function warn(...)
    logger.warn("[vocabdeck:updater]", ...)
end

--- Parse major/minor/patch from version strings like "v1.2.3" or "1.2.3".
local function parseSemver(v)
    v = (v or ""):match("^v?(.+)$") or ""
    local maj, min, pat = v:match("^(%d+)%.(%d+)%.?(%d*)$")
    return tonumber(maj) or 0, tonumber(min) or 0, tonumber(pat) or 0
end

--- Returns true when version string a is strictly greater than b.
local function semverGt(a, b)
    local a1, a2, a3 = parseSemver(a)
    local b1, b2, b3 = parseSemver(b)
    if a1 ~= b1 then return a1 > b1 end
    if a2 ~= b2 then return a2 > b2 end
    return a3 > b3
end

--- Best-effort HTTPS GET; returns the response body string or nil.
--- Blocking — only call inside Trapper:dismissableRunInSubprocess().
local function httpsGet(url)
    local sink = {}
    socketutil:set_timeout()
    local code, headers, status = socket.skip(1, http.request{
        url = url,
        sink = ltn12.sink.table(sink),
        method = "GET",
        headers = { ["User-Agent"] = "vocabdeck.koplugin" },
    })
    socketutil:reset_timeout()
    if headers == nil then
        warn("Network unreachable", status or code or "unknown")
        return nil
    end
    if code ~= 200 then
        warn("HTTP status unexpected:", status or code or "unknown")
        return nil
    end
    return table.concat(sink)
end

--- Download a file via HTTPS to dest_path.
--- Blocking — only call inside Trapper:dismissableRunInSubprocess().
local function httpsDownload(url, dest_path)
    socketutil:set_timeout(socketutil.FILE_BLOCK_TIMEOUT, socketutil.FILE_TOTAL_TIMEOUT)
    local f, ferr = io.open(dest_path, "wb")
    if not f then return false, ferr end
    local code, headers, status = socket.skip(1, http.request{
        url = url,
        sink = ltn12.sink.file(f),
        method = "GET",
        headers = { ["User-Agent"] = "vocabdeck.koplugin" },
    })
    pcall(f.close, f)
    socketutil:reset_timeout()
    if code ~= 200 then
        os.remove(dest_path)
        return false, status or tostring(code)
    end
    return true
end

--- Move a file or directory.
local function moveFile(src, dest)
    local mv_bin = Device:isAndroid() and "/system/bin/mv" or "/bin/mv"
    return ffiUtil.execute(mv_bin, src, dest) == 0
end

local function copyPreservedLocalFiles(old_dir, new_dir)
    for _, filename in ipairs(PRESERVED_LOCAL_FILES) do
        local source = old_dir .. "/" .. filename
        if lfs.attributes(source, "mode") == "file" then
            local copy_err = ffiUtil.copyFile(source, new_dir .. "/" .. filename)
            if copy_err then
                return false, string.format("could not preserve %s: %s", filename, copy_err)
            end
        end
    end
    return true
end

--- Show an InfoMessage and force a repaint so it appears immediately.
local function showMessage(text, timeout)
    local opts = {
        text = _(text),
        dismissable = false,
    }
    if timeout ~= nil then
        opts.timeout = timeout
    end
    local msg = InfoMessage:new(opts)
    UIManager:show(msg)
    UIManager:forceRePaint()
    return msg
end

--- Close a widget previously shown with showMessage().
local function closeMessage(msg)
    if msg then
        msg.dismiss_callback = nil
        UIManager:close(msg)
    end
end

-- ── GitHub release parsing ──────────────────────────────────────────────────

--- Parses a GitHub release API response into a simple version/zip_url map.
local function parseReleaseInfo(json)
    if not json or not json.tag_name then
        warn("Invalid release JSON: missing tag_name")
        return nil
    end
    local version = json.tag_name:match("^v?(.+)$") or json.tag_name
    local zip_url
    -- Prefer the curated release package. GitHub's zipball is only a fallback
    -- and may have a generated root directory or different archive metadata.
    if type(json.assets) == "table" then
        for _, asset in ipairs(json.assets) do
            local name = type(asset.name) == "string" and asset.name:lower() or ""
            if asset.browser_download_url
                and (name:match("%.zip$") or asset.content_type == "application/zip") then
                zip_url = asset.browser_download_url
                break
            end
        end
    end
    zip_url = zip_url or json.zipball_url
    if not zip_url then
        warn("No downloadable asset found in release")
        return nil
    end
    return {
        version = version,
        zip_url = zip_url,
        name = json.name or json.tag_name,
        description = json.body or "",
    }
end

--- Decode a JSON string, returning nil on failure.
local function safeDecodeJson(body)
    if not body or body == "" or body:sub(1, 1) ~= "{" then
        return nil
    end
    local ok, data = pcall(JSON.decode, body, JSON.decode.simple)
    if not ok or not data then
        return nil
    end
    return data
end

local function parseMetaVersion(meta_file)
    local f = io.open(meta_file, "rb")
    if not f then return nil end
    local content = f:read("*a") or ""
    f:close()
    return content:match("version%s*=%s*['\"]([^'\"]+)['\"]")
end

local function verifyArchiveFile(archive_file)
    local attr = lfs.attributes(archive_file)
    if not attr or not attr.size or attr.size < 128 then
        return false, "downloaded archive is empty or too small"
    end
    local f = io.open(archive_file, "rb")
    if not f then
        return false, "could not open downloaded archive"
    end
    local magic = f:read(4) or ""
    f:close()
    if magic ~= "PK\003\004" and magic ~= "PK\005\006" and magic ~= "PK\007\008" then
        return false, "downloaded file is not a ZIP archive"
    end
    return true
end

local function prepareExtractDir(extract_dir)
    if lfs.attributes(extract_dir) then
        local removed, remove_err = ffiUtil.purgeDir(extract_dir)
        if not removed then
            return false, remove_err or "could not clear extraction directory"
        end
    end
    local created, create_err = lfs.mkdir(extract_dir)
    if not created and lfs.attributes(extract_dir, "mode") ~= "directory" then
        return false, create_err or "could not create extraction directory"
    end
    return true
end

local function safeArchiveEntry(entry)
    if not entry or type(entry.path) ~= "string" or entry.path == "" then
        return nil, "archive contains an entry without a path"
    end
    if entry.mode ~= "file" and entry.mode ~= "directory" then
        return nil, "archive contains an unsupported entry type"
    end
    local path = entry.path:gsub("\\", "/")
    if path:find("\0", 1, true)
        or path:sub(1, 1) == "/"
        or path:match("^%a:/")
        or ("/" .. path .. "/"):find("/../", 1, true) then
        return nil, "archive contains an unsafe path"
    end
    return path
end

local function extractWithArchiver(archive_file, extract_dir)
    local loaded, Archiver = pcall(require, "ffi/archiver")
    if not loaded then
        return false, "KOReader Archiver is unavailable: " .. tostring(Archiver)
    end

    local arc
    local ran, extracted, extract_err, stop_fallback = pcall(function()
        arc = Archiver.Reader:new()
        if not arc:open(archive_file) then
            return false, arc.err or "could not open archive"
        end
        for entry in arc:iterate() do
            local entry_path, path_err = safeArchiveEntry(entry)
            if not entry_path then
                return false, path_err, true
            end
            if not arc:extractToPath(entry.path, extract_dir .. "/" .. entry_path) then
                return false, arc.err or "could not extract archive entry"
            end
        end
        if arc.err then
            return false, arc.err
        end
        return true
    end)
    if arc then
        pcall(arc.close, arc)
    end
    if not ran then
        return false, tostring(extracted)
    end
    return extracted, extract_err, stop_fallback
end

local function extractArchive(archive_file, extract_dir)
    local reasons = {}
    local ready, ready_err = prepareExtractDir(extract_dir)
    if not ready then return false, ready_err end

    local extracted, extract_err, stop_fallback = extractWithArchiver(archive_file, extract_dir)
    if extracted then return true end
    if stop_fallback then return false, extract_err end
    reasons[#reasons + 1] = extract_err or "KOReader Archiver failed"

    -- Compatibility path for KOReader versions that still expose this API.
    if type(Device.unpackArchive) == "function" then
        ready, ready_err = prepareExtractDir(extract_dir)
        if not ready then return false, ready_err end
        local called, unpacked, unpack_err = pcall(
            Device.unpackArchive, Device, archive_file, extract_dir, false
        )
        if called and unpacked then return true end
        reasons[#reasons + 1] = called
            and (unpack_err or "legacy archive extractor failed")
            or tostring(unpacked)
    end

    -- Last resort for platforms that provide a command-line unzip utility.
    ready, ready_err = prepareExtractDir(extract_dir)
    if not ready then return false, ready_err end
    local rc, exit_type, exit_code = os.execute(
        string.format("unzip -oq %q -d %q", archive_file, extract_dir)
    )
    if rc == true or rc == 0 then return true end
    reasons[#reasons + 1] = string.format(
        "unzip failed (%s)", tostring(exit_code or exit_type or rc)
    )
    return false, table.concat(reasons, "; ")
end

-- ── Public API ──────────────────────────────────────────────────────────────

local CHECK_INTERVAL = 3600  -- seconds between network checks (1 hour)
local GS_KEY_TIME  = "vocabdeck_last_update_check"
local GS_KEY_AVAIL = "vocabdeck_update_available"
local GS_KEY_VER   = "vocabdeck_latest_version"
local GS_KEY_ZIP   = "vocabdeck_latest_zip_url"

--- Load reader settings helper.
local function getGS()
    local ok, gs = pcall(function() return G_reader_settings end)
    return (ok and gs) or nil
end

--- Check for updates. Caches result for 1 hour so repeated taps don't hit
--- the network. Shows dialogs directly — no Trapper coroutine needed
--- for the check (blocking HTTP is fine for user-initiated actions).
function Updater.check(plugin, current_version)
    local plugin_dir = getPluginDir()
    if not plugin_dir then
        UIManager:show(InfoMessage:new{
            text = _("Could not determine plugin directory."),
        })
        return
    end
    local meta = dofile(plugin_dir .. "/_meta.lua")
    if not meta or not meta.update_url then
        UIManager:show(InfoMessage:new{
            text = _("No update URL configured for this plugin."),
        })
        return
    end

    if not NetworkMgr:isWifiOn() then
        UIManager:show(InfoMessage:new{
            text = _("Wi-Fi is not enabled. Please connect to the internet first."),
        })
        return
    end

    local gs = getGS()
    local now = os.time()
    local last = gs and gs:readSetting(GS_KEY_TIME) or 0
    local last_num = type(last) == "number" and last or 0

    -- Return cached result if checked recently
    if (now - last_num) < CHECK_INTERVAL and gs then
        local cached_avail = gs:readSetting(GS_KEY_AVAIL) == true
        local cached_ver   = gs:readSetting(GS_KEY_VER) or ""
        local cached_zip   = gs:readSetting(GS_KEY_ZIP) or ""
        if cached_avail and semverGt(cached_ver, current_version) then
            UIManager:show(ConfirmBox:new{
                text = T(_("VocabDeck v%1 is available.\n\nCurrent version: v%2\n\nDownload and install now?"), cached_ver, current_version),
                ok_text = _("Update"),
                ok_callback = function()
                    if Device.isEmulator() then
                        UIManager:show(InfoMessage:new{
                            text = _("Emulator detected.\nUpdates are not applied in the emulator."),
                        })
                        return
                    end
                    if cached_zip == "" then
                        cached_zip = meta.update_url:gsub("/releases/latest", "/zipball/v" .. cached_ver)
                    end
                    Updater._install(plugin_dir, {
                        version = cached_ver,
                        zip_url = cached_zip,
                    })
                end,
            })
        else
            UIManager:show(InfoMessage:new{
                text = T(_("VocabDeck is up to date (v%1)."), current_version),
                timeout = 3,
            })
        end
        return
    end

    -- Show checking message
    local status_msg = showMessage("Checking for updates…")

    -- Live check: blocking HTTPS, fast for Wi-Fi connections
    local body = httpsGet(meta.update_url)
    closeMessage(status_msg)

    if not body then
        UIManager:show(InfoMessage:new{
            text = _("Failed to check for updates.\n\nCould not reach the update server. Check your internet connection."),
        })
        return
    end

    local release_data = safeDecodeJson(body)
    if not release_data then
        UIManager:show(InfoMessage:new{
            text = _("Failed to parse release information."),
        })
        return
    end

    local release = parseReleaseInfo(release_data)
    if not release then
        UIManager:show(InfoMessage:new{
            text = _("Failed to parse release information."),
        })
        return
    end

    -- Cache the result
    if gs then
        local has_upd = semverGt(release.version, current_version)
        gs:saveSetting(GS_KEY_TIME, now)
        gs:saveSetting(GS_KEY_AVAIL, has_upd)
        gs:saveSetting(GS_KEY_VER, release.version)
        gs:saveSetting(GS_KEY_ZIP, release.zip_url or "")
        pcall(gs.flush, gs)
    end

    -- Show result
    if not semverGt(release.version, current_version) then
        UIManager:show(InfoMessage:new{
            text = T(_("VocabDeck is up to date (v%1)."), current_version),
            timeout = 3,
        })
        return
    end

    UIManager:show(ConfirmBox:new{
        text = T(_("VocabDeck v%1 is available.\n\nCurrent version: v%2\n\nDownload and install now?"), release.version, current_version),
        ok_text = _("Update"),
        ok_callback = function()
            if Device.isEmulator() then
                UIManager:show(InfoMessage:new{
                    text = _("Emulator detected.\nUpdates are not applied in the emulator."),
                })
                return
            end
            Updater._install(plugin_dir, release)
        end,
    })
end

--- Download, verify, and install an update.
--- This is called after the user confirms they want to update.
--- @param plugin_dir string  The plugin directory path.
--- @param release table  The parsed release info (version, zip_url, etc.).
function Updater._install(plugin_dir, release)
    -- Wrap in Trapper:wrap() so dismissableRunInSubprocess runs in a coroutine.
    -- Called from a regular callback (not inside a coroutine), so without this
    -- Trapper falls back to blocking in-process execution.
    Trapper:wrap(function()
        local archive_file = plugin_dir .. "_" .. release.version .. ".zip"
        local extract_dir = plugin_dir .. "_" .. release.version

        -- Show download progress
        local status_msg = showMessage("Downloading update…\n\nKOReader will ask to restart after the update is installed.")

        -- Step 1: Download the update zip (runs in subprocess)
        local completed, ok, err = Trapper:dismissableRunInSubprocess(function()
            local success, reason = httpsDownload(release.zip_url, archive_file)
            return success, reason
        end, status_msg)

        if not completed then
            closeMessage(status_msg)
            os.remove(archive_file)
            return
        end

        if not ok then
            closeMessage(status_msg)
            UIManager:show(InfoMessage:new{
                text = T(_("Failed to download update.\n\n%1"), err or _("Unknown error")),
            })
            return
        end

        local archive_ok, archive_err = verifyArchiveFile(archive_file)
        if not archive_ok then
            closeMessage(status_msg)
            UIManager:show(InfoMessage:new{
                text = T(_("Failed to verify downloaded update.\n\n%1"), archive_err or _("Invalid archive")),
            })
            os.remove(archive_file)
            return
        end

        -- Step 2: Extract the update
        closeMessage(status_msg)
        status_msg = showMessage("Extracting update…")

        -- Extraction runs in a subprocess so large archives do not block UI.
        local completed2, extract_ok, extract_err = Trapper:dismissableRunInSubprocess(function()
            return extractArchive(archive_file, extract_dir)
        end, status_msg)

        if not completed2 then
            closeMessage(status_msg)
            ffiUtil.purgeDir(extract_dir)
            os.remove(archive_file)
            return
        end

        if not extract_ok then
            closeMessage(status_msg)
            UIManager:show(InfoMessage:new{
                text = T(_("Failed to extract update.\n\n%1"),
                    extract_err or _("Unknown error")),
            })
            ffiUtil.purgeDir(extract_dir)
            os.remove(archive_file)
            return
        end

        -- Step 3: Verify the update
        closeMessage(status_msg)
        status_msg = showMessage("Verifying update…")

        local completed3, verified = Trapper:dismissableRunInSubprocess(function()
            -- The zip from GitHub creates a subdirectory named {repo}-{sha}.
            -- Find the actual _meta.lua inside the extracted tree.
            local meta_file = extract_dir .. "/_meta.lua"
            if not lfs.attributes(meta_file) then
                -- Try to find it in a subdirectory
                local dirs = {}
                for entry in lfs.dir(extract_dir) do
                    if entry ~= "." and entry ~= ".." then
                        local path = extract_dir .. "/" .. entry
                        if lfs.attributes(path, "mode") == "directory" then
                            dirs[#dirs + 1] = path
                        end
                    end
                end
                if #dirs == 1 then
                    meta_file = dirs[1] .. "/_meta.lua"
                end
            end
            if not lfs.attributes(meta_file) then
                return false, "no _meta.lua found"
            end
            local update_version = parseMetaVersion(meta_file)
            if update_version ~= release.version then
                return false, "version mismatch"
            end
            -- Remember the actual extracted plugin directory
            local extracted_plugin_dir = meta_file:match("^(.+)/_meta%.lua$")
            if extracted_plugin_dir and extracted_plugin_dir ~= extract_dir then
                -- Move the subdirectory contents up to extract_dir
                for entry in lfs.dir(extracted_plugin_dir) do
                    if entry ~= "." and entry ~= ".." then
                        local ok_rename, err_rename = os.rename(
                            extracted_plugin_dir .. "/" .. entry,
                            extract_dir .. "/" .. entry
                        )
                        if not ok_rename then
                            warn("Failed to move", entry, err_rename)
                        end
                    end
                end
                -- Remove the now-empty subdirectory
                ffiUtil.purgeDir(extracted_plugin_dir)
            end
            return true
        end, status_msg)

        if not completed3 then
            closeMessage(status_msg)
            ffiUtil.purgeDir(extract_dir)
            os.remove(archive_file)
            return
        end

        if not verified then
            closeMessage(status_msg)
            UIManager:show(InfoMessage:new{
                text = _("Failed to verify the update: the downloaded file does not appear to be a valid VocabDeck release."),
            })
            ffiUtil.purgeDir(extract_dir)
            os.remove(archive_file)
            return
        end

        -- Step 4: Swap directories (backup old, install new)
        closeMessage(status_msg)
        status_msg = showMessage("Applying update…")

        local completed4, swapped, swap_err = Trapper:dismissableRunInSubprocess(function()
            local backup_dir = plugin_dir .. ".backup"
            if lfs.attributes(backup_dir) then
                ffiUtil.purgeDir(backup_dir)
            end
            local ok_move = moveFile(plugin_dir, backup_dir)
            if not ok_move then
                return false, "backup failed"
            end
            ok_move = moveFile(extract_dir, plugin_dir)
            if not ok_move then
                -- Restore backup
                moveFile(backup_dir, plugin_dir)
                return false, "install failed"
            end
            local preserved, preserve_err = copyPreservedLocalFiles(backup_dir, plugin_dir)
            if not preserved then
                ffiUtil.purgeDir(plugin_dir)
                if not moveFile(backup_dir, plugin_dir) then
                    preserve_err = preserve_err .. "; restoring the old version failed"
                end
                return false, preserve_err
            end
            -- Clean up backup and archive
            ffiUtil.purgeDir(backup_dir)
            os.remove(archive_file)
            return true
        end, status_msg)

        closeMessage(status_msg)

        if not completed4 or not swapped then
            UIManager:show(InfoMessage:new{
                text = T(_("Failed to install update.\n\n%1\n\nOld version has been restored."),
                    swap_err or _("Unknown error")),
            })
            return
        end

        -- Step 5: Done — prompt restart
        UIManager:askForRestart(
            T(_("VocabDeck updated to v%1.\n\nRestart KOReader to activate the new version."),
                release.version)
        )
    end)
end

return Updater
