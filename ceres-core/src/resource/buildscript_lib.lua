-- Build script utilities for Ceres

-- macro support
function define(id, value)
    if type(value) == "function" then
        ceres.registerMacro(id, value)
    else
        ceres.registerMacro(id, function()
            return value
        end)
    end
end

ceres.registerMacro("macro_define", define)

-- map library

local mapMeta = {}
mapMeta.__index = mapMeta

-- Reads a file from the map and returns its contents as a string if successful
function mapMeta:readFile(path)
    if self.kind == "mpq" then
        return self.archive:readFile(path)
    elseif self.kind == "dir" then
        return fs.readFile(self.path .. path)
    end
end

-- Adds a file to the map, as a lua string
-- This doesn't modify the map in any way, it only adds the file to be written when either
-- map:writeToDir() or map:writeToMpq() is called
function mapMeta:addFileString(path, contents)
    self.added[path] = {
        kind = "string",
        contents = contents
    }
end

-- Adds a file to the map, reading the contents from another file on the disk
-- This doesn't modify the map in any way, it only adds the file to be written when either
-- map:writeToDir() or map:writeToMpq() is called
function mapMeta:addFileDisk(archivePath, filePath)
    self.added[path] = {
        kind = "file",
        path = filePath
    }
end

-- Writes the map to a directory
-- Any files added to the map via map:addFileString() or map:addFileDisk() will be
-- written at this stage
function mapMeta:writeToDir(path)
    if self.kind == "dir" then
        fs.copyDir(self.path, path) 
    elseif self.kind == "mpq" then
        self.archive:extractTo(path)
    end

    for k, v in pairs(self.added) do
        if v.kind == "string" then
            fs.writeFile(path .. k, v.contents)
        elseif v.kind == "file" then
            fs.copyFile(v.filePath, path .. k)
        end
    end
end

-- Writes the map to an mpq archive
-- Any files added to the map via map:addFileString() or map:addFileDisk() will be
-- written at this stage
function mapMeta:writeToMpq(path)
    local creator = mpq.new()

    if self.kind == "dir" then
        local success, errorMsg = creator:addFromDir(self.path)
        if not success then
            print("Couldn't add directory " .. self.path .. " to archive: " .. errorMsg)
        end
    elseif self.kind == "mpq" then
        local success, errorMsg = creator:addFromMpq(self.archive)
        if not success then
            print("Couldn't add files from another archive: " .. errorMsg)
        end
    end

    for k, v in pairs(self.added) do
        if v.kind == "string" then
            creator:add(k, v.contents)
        elseif v.kind == "file" then
            local success, errorMsg = creator:addFromFile(k, v.path)
            if not success then
                print("Couldn't add file " .. k .. " to archive: " .. errorMsg)
            end
        end
    end

    return creator:write(path)
end

function ceres.openMap(name)
    local map = {
        added = {}
    }
    local mapPath = ceres.layout.mapsDirectory .. name

    if not fs.exists(mapPath) then
        return false, "map does not exist"
    end

    if fs.isDir(mapPath) then
        map.kind = "dir"

        map.path = mapPath .. "/"
    elseif fs.isFile(mapPath) then
        map.kind = "mpq"

        local archive, errorMsg = mpq.open(mapPath)

        if not archive then
            return false, errorMsg
        end

        map.archive = archive
    else
        return false, "map path is not a file or directory"
    end

    setmetatable(map, mapMeta)

    return map
end

-- default build functionality

-- Describes the folder layout used by Ceres.
-- Can be changed on a per-project basis.
-- This layout will also be used by the VSCode extension.
ceres.layout = {
    mapsDirectory = "maps/",
    srcDirectory = "src/",
    libDirectory = "lib/",
    targetDirectory = "target/"
}

-- This is the default map build procedure
-- Takes a single "build command" specifying
-- what and how to build.
function ceres.buildMap(buildCommand)
    local map, mapScript
    local mapName = buildCommand.input
    local outputType = buildCommand.output

    if not (outputType == "script" or outputType == "mpq" or outputType == "dir") then
        print("ERR: Output type must be one of 'mpq', 'dir' or 'script'")
        return false
    end

    if mapName == nil and (outputType == "mpq" or outputType == "dir") then
        print("ERR: Output type " .. outputType .. " requires an input map, but none was specified")
        return false
    end

    print("Received build command");
    print("    Input: " .. tostring(mapName))
    print("    Retain map script: " .. tostring(buildCommand.retainMapScript))
    print("    Output type: " .. buildCommand.output)

    if mapName ~= nil then
        local loadedMap, errorMsg = ceres.openMap(mapName)
        if errorMsg ~= nil then
            print("ERR: Could not load map " .. mapName .. ": " .. errorMsg)
            return false
        end
        print("Loaded map " .. mapName)

        if buildCommand.retainMapScript then
            local loadedScript, errorMsg = loadedMap:readFile("war3map.lua")
            if errorMsg ~= nil then
                print("WARN: Could not extract script from map " .. mapName .. ": " .. errorMsg)
                print("WARN: Map script won't be included in the final artifact")
            else
                print("Loaded map script from " .. mapName)
                mapScript = loadedScript
            end
        end

        map = loadedMap
    end

    if map == nil then
        print("Building in script-only mode")
    end

    if mapScript == nil then
        print("Building without including original map script")
    end

    _G.currentMap = map

    local script, errorMsg = ceres.compileScript {
        srcDirectory = ceres.layout.srcDirectory,
        libDirectory = ceres.layout.libDirectory,
        mapScript = mapScript or ""
    }

    if errorMsg ~= nil then
        print("ERR: Map build failed:")
        print(errorMsg)
        return false
    end

    print("Successfuly built the map")

    local errorMsg
    local artifactPath
    if outputType == "script" then
        print("Writing artifact [script] to " .. ceres.layout.targetDirectory .. "war3map.lua")
        _, errorMsg = fs.writeFile(ceres.layout.targetDirectory .. "war3map.lua", script)
    elseif outputType == "mpq" then
        artifactPath = ceres.layout.targetDirectory .. mapName
        print("Writing artifact [mpq] to " .. artifactPath)
        _, errorMsg = map:writeToMpq(artifactPath)
    elseif outputType == "dir" then
        artifactPath = ceres.layout.targetDirectory .. mapName .. ".dir"
        print("Writing artifact [dir] to " .. artifactPath)
        _, errorMsg = map:writeToDir(artifactPath)
    end

    if errorMsg ~= nil then
        print("ERR: Saving the artifact failed: " .. errorMsg)
        return false
    else
        print("Build complete!")
        return artifactPath
    end
end

-- arg parsing
local args = ceres.getScriptArgs()

arg = {
    exists = function(arg_name)
        for _, v in pairs(args) do
            if v == arg_name then
                return true
            end
        end
        return false
    end,
    value = function(arg_name)
        local arg_pos
        for i, v in ipairs(args) do
            if v == arg_name then
                arg_pos = i
                break
            end
        end

        if arg_pos ~= nil and #args > arg_pos then
            return args[arg_pos + 1]
        end
    end
}

-- default handler

local handlerSuppressed = false

function ceres.suppressDefaultHandler()
    handlerSuppressed = true
end

-- The default handler for "build" and "run" commands in Ceres
-- Will parse the arguments and invoke ceres.buildMap()
function ceres.defaultHandler()
    if ceres.isManifestRequested() then
        ceres.sendManifest(ceres.layout)
        return
    end

    if handlerSuppressed then
        return
    end

    local mapArg = arg.value("--map")
    local outputType = arg.value("--output") or "mpq"
    local noKeepScript = arg.value("--no-map-script") or false

    local artifactPath = ceres.buildMap {
        input = mapArg,
        output = outputType,
        retainMapScript = not noKeepScript
    }

    if ceres.isRunmapRequested() then
        if artifactPath == nil then
            print("WARN: Runmap was requested, but the current build did not produce a runnable artifact...")
        else
            print("Runmap was requested, running the map...")
            ceres.runMap(artifactPath)
        end
    end
end

