local DJStations = {}
local StationDBMapping = {} -- Maps game ID to database ID
local StationWhitelists = {} -- dbId -> {whitelist entries}

-- Per-station light controls (in-memory only, not saved to database)
-- flash: 0 = off, 1 = high (every tick), 2 = low (every 2 ticks)
local StationLightControls = {}

-- Per-station particle effects (in-memory only, not saved to database)
local StationParticleEffects = {}

local function getStationParticleEffects(stationId)
    if not StationParticleEffects[stationId] then
        StationParticleEffects[stationId] = {
            smoke = false,
            fire = false,
        }
    end
    return StationParticleEffects[stationId]
end

-- Initialize default controls for a station if they don't exist

local function getStationLightControls(stationId)
    if not StationLightControls[stationId] then
        StationLightControls[stationId] = {
            lights = {
                ambient = {
                    enabled = true,
                    rotateHorizontal = true,
                    rotateVertical = false,
                    flash = GetFlashValue("low"), -- low
                    speed = GetSpeedValue("normal"), -- normal = 2.0
                    primaryColor = {255, 0, 0}, -- RGB: red
                    secondaryColor = {255, 100, 0}, -- RGB: orange
                },
                spotlight = {
                    enabled = true,
                    rotateHorizontal = true,
                    rotateVertical = false, 
                    flash = GetFlashValue("off"), -- off
                    speed = GetSpeedValue("normal"), -- normal = 2.0
                    primaryColor = {0, 255, 0}, -- RGB: green
                    secondaryColor = {0, 200, 255}, -- RGB: cyan
                },
                barlight = {
                    enabled = true,
                    rotateHorizontal = true,
                    rotateVertical = true,
                    flash = GetFlashValue("low"), -- low
                    speed = GetSpeedValue("normal"), -- normal = 2.0
                    primaryColor = {0, 0, 255}, -- RGB: blue
                    secondaryColor = {255, 0, 255}, -- RGB: magenta
                }
            }
        }
    end
    return StationLightControls[stationId]
end

function CanInteractWithStation(source, stationId)
    local station = DJStations[stationId]
    if not station then
        return false, false, "Station not found"
    end
    
    -- Admins can always access
    if IsPlayerAdmin(source) then
        print("Admin can access station interaction")
        return true, true, nil
    end
    
    -- Check if player is owner
    local playerIdentifier = GetIdentifier(source)
    if playerIdentifier and station.identifier and station.identifier == playerIdentifier then
        print("Player is owner of station")
        return true, true, nil
    end
    
    -- Check whitelist
    local dbId = StationDBMapping[stationId]
    if dbId then
        local whitelist = LoadStationWhitelist(dbId)
        if whitelist and #whitelist > 0 then
            -- Whitelist exists, check access
            if CheckWhitelistAccess(source, stationId) then
                print("Player is whitelisted for station")
                return true, false, nil
            end
        end
    end
    return false, false, "You are not whitelisted for this station"
end

-- Create database tables on resource start
CreateThread(function()
    MySQL.ready(function()
        -- Main stations table
        MySQL.Async.execute([[
            CREATE TABLE IF NOT EXISTS `pickle_dj_stations` (
                `id` INT(11) NOT NULL AUTO_INCREMENT,
                `identifier` VARCHAR(255),
                `name` VARCHAR(255) NOT NULL,
                `coords` TEXT NOT NULL,
                `heading` FLOAT NOT NULL,
                `prop` VARCHAR(50) NOT NULL,
                `created_by` VARCHAR(255),
                `created_at` TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
                PRIMARY KEY (`id`)
            ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
        ]], {})
        
        -- Entities table for all station-related objects (speakers, lights, etc.)
        MySQL.Async.execute([[
            CREATE TABLE IF NOT EXISTS `pickle_dj_entities` (
                `id` INT(11) NOT NULL AUTO_INCREMENT,
                `station_id` INT(11) NOT NULL,
                `entity_type` VARCHAR(50) NOT NULL,
                `coords` TEXT NOT NULL,
                `heading` FLOAT NOT NULL,
                `model` VARCHAR(50),
                `data` TEXT,
                `created_at` TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
                PRIMARY KEY (`id`),
                INDEX `idx_station_id` (`station_id`),
                INDEX `idx_entity_type` (`entity_type`),
                FOREIGN KEY (`station_id`) REFERENCES `pickle_dj_stations`(`id`) ON DELETE CASCADE
            ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
        ]], {})
        
        -- Whitelist table for DJ stations
        MySQL.Async.execute([[
            CREATE TABLE IF NOT EXISTS `pickle_dj_whitelist` (
                `id` INT(11) NOT NULL AUTO_INCREMENT,
                `station_id` INT(11) NOT NULL,
                `type` ENUM('player', 'job', 'ace') NOT NULL,
                `value` VARCHAR(255) NOT NULL,
                `name` VARCHAR(255),
                `rank` INT(11) DEFAULT 0,
                `created_at` TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
                PRIMARY KEY (`id`),
                INDEX `idx_station_id` (`station_id`),
                INDEX `idx_type` (`type`),
                FOREIGN KEY (`station_id`) REFERENCES `pickle_dj_stations`(`id`) ON DELETE CASCADE
            ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
        ]], {})
        
        debugPrint("^2[pickle_dj]^0 Database tables initialized")
    end)
end)

function RegisterDJStation(station, skipSync)
    local id
    repeat
        id = math.random(1, 1000000)
    until not DJStations[id]
    
    -- Initialize light controls from station data or get defaults
    local lightControls = station.lightControls
    if not lightControls then
        lightControls = getStationLightControls(id)
    else
        -- Store the provided controls
        StationLightControls[id] = lightControls
    end
    
    DJStations[id] = {
        name = station.name or "Unknown",
        coords = station.coords or vec3(0.0, 0.0, 0.0),
        heading = station.heading or 0.0,
        streamId = station.streamId or nil,
        prop = station.prop or nil,
        speakers = station.speakers or nil,
        lights = station.lights or nil,
        smokemachines = station.smokemachines or nil,
        lightControls = lightControls,
        identifier = station.identifier or nil,
    }
    if skipSync then return id end
    
    -- Include light controls in the station data sent to clients
    local stationData = {
        name = station.name,
        coords = station.coords,
        heading = station.heading,
        prop = station.prop,
        speakers = station.speakers,
        lights = station.lights,
        smokemachines = station.smokemachines,
        lightControls = lightControls,
    }
    TriggerClientEvent('pickle_dj:registerDJStation', -1, id, stationData)
    return id
end

-- Load DJ stations from database
function LoadDJStationsFromDatabase()
    MySQL.Async.fetchAll("SELECT * FROM `pickle_dj_stations`", {}, function(stationResults)
        if not stationResults or #stationResults == 0 then
            -- Sync all stations with light controls included
            local stationsToSync = {}
            for gameId, station in pairs(DJStations) do
                stationsToSync[gameId] = {
                    name = station.name,
                    coords = station.coords,
                    heading = station.heading,
                    prop = station.prop,
                    speakers = station.speakers,
                    lights = station.lights,
                    smokemachines = station.smokemachines,
                    lightControls = station.lightControls or getStationLightControls(gameId),
                }
            end
            TriggerClientEvent('pickle_dj:registerDJStation', -1, stationsToSync)
            return
        end
        
        -- Load all entities for all stations
        MySQL.Async.fetchAll("SELECT * FROM `pickle_dj_entities`", {}, function(entityResults)
            -- Group entities by station_id and entity_type
            local entitiesByStation = {}
            if entityResults then
                for _, entity in ipairs(entityResults) do
                    if not entitiesByStation[entity.station_id] then
                        entitiesByStation[entity.station_id] = {}
                    end
                    if not entitiesByStation[entity.station_id][entity.entity_type] then
                        entitiesByStation[entity.station_id][entity.entity_type] = {}
                    end
                    
                    local coordsData = json.decode(entity.coords)
                    local coords = vector3(coordsData.x, coordsData.y, coordsData.z)
                    local data = entity.data and json.decode(entity.data) or {}
                    
                    local entityObj = {
                        id = entity.id, -- Database ID for deletion
                        coords = coords,
                        heading = entity.heading,
                        model = entity.model and tonumber(entity.model) or nil,
                        speakerType = data.speakerType,
                        rotation = data.rotation,
                        soundOffset = data.soundOffset,
                        data = data
                    }
                    
                    -- Extract light-specific fields for easier access
                    if entity.entity_type == "light" then
                        entityObj.lightType = data.lightType
                        entityObj.colorSpec = data.colorSpec
                    end
                    
                    table.insert(entitiesByStation[entity.station_id][entity.entity_type], entityObj)
                end
            end
            
            -- Load stations with their entities
            for _, row in ipairs(stationResults) do
                local coordsData = json.decode(row.coords)
                local coords = vector3(coordsData.x, coordsData.y, coordsData.z)
                
                -- Get entities for this station
                local stationEntities = entitiesByStation[row.id] or {}
                local speakers = stationEntities.speaker or nil
                local lights = stationEntities.light or nil
                local smokemachines = stationEntities.smokemachine or nil
                
                local streamId = CreateMusicInstance(row.name, coords, row.heading, speakers)
                
                -- Get default light controls
                local defaultLightControls = getStationLightControls(0) -- Use 0 as temp ID, will be replaced
                
                -- Register the station with default light controls
                local gameId = RegisterDJStation({
                    name = row.name,
                    coords = coords,
                    heading = row.heading,
                    prop = tonumber(row.prop),
                    speakers = speakers,
                    lights = lights,
                    smokemachines = smokemachines,
                    lightControls = defaultLightControls,
                    streamId = streamId,
                    identifier = row.identifier,
                }, true)
                -- Store mapping
                StationDBMapping[gameId] = row.id
                debugPrint(("^2[pickle_dj]^0 Loaded DJ station '%s' (ID: %s) from database"):format(row.name, row.id))
            end
            
            TriggerClientEvent('pickle_dj:registerDJStation', -1, DJStations)
        end)
    end)
end

CreateThread(function()
    -- Wait for MySQL to be ready
    MySQL.ready(function()
        -- Load from database first
        LoadDJStationsFromDatabase()
        -- Load whitelists
        LoadStationWhitelistOnStart()
        -- Sync all stations with light controls included (LoadDJStationsFromDatabase will handle the sync)
    end)
end)

RegisterServerEvent('pickle_dj:requestDJStations', function()
    local source = source
    -- Sync all stations with light controls included
    local stationsToSync = {}
    for gameId, station in pairs(DJStations) do
        stationsToSync[gameId] = {
            name = station.name,
            coords = station.coords,
            heading = station.heading,
            prop = station.prop,
            speakers = station.speakers,
            lights = station.lights,
            smokemachines = station.smokemachines,
            lightControls = station.lightControls or getStationLightControls(gameId),
        }
    end
    TriggerClientEvent('pickle_dj:registerDJStation', source, stationsToSync)
end)

-- Admin permission check callback
lib.callback.register('pickle_dj:checkAdmin', function(source)
    return IsPlayerAdmin(source) == true
end)

-- Check if player is owner or admin of a station
lib.callback.register('pickle_dj:canManageStation', function(source, gameId)
    local station = DJStations[gameId]
    if not station then
        return false
    end
    
    -- Admins can always manage
    if IsPlayerAdmin(source) then
        return true
    end
    
    -- Check if player is the owner
    local playerIdentifier = GetIdentifier(source)
    if playerIdentifier and station.identifier and station.identifier == playerIdentifier then
        return true
    end
    
    return false
end)

-- Save entity to database
local function SaveEntity(stationId, entityType, entityData, callback)
    local coordsJson = json.encode(entityData.coords)
    local dataJson = entityData.data and json.encode(entityData.data) or nil
    
    MySQL.Async.insert(
        "INSERT INTO `pickle_dj_entities` (`station_id`, `entity_type`, `coords`, `heading`, `model`, `data`) VALUES (@station_id, @entity_type, @coords, @heading, @model, @data)",
        {
            ['@station_id'] = stationId,
            ['@entity_type'] = entityType,
            ['@coords'] = coordsJson,
            ['@heading'] = entityData.heading or 0.0,
            ['@model'] = entityData.model and tostring(entityData.model) or nil,
            ['@data'] = dataJson
        },
        callback
    )
end

-- Save DJ station to database
RegisterServerEvent('pickle_dj:saveStation', function(stationData)
    local source = source
    
    -- Check admin permission
    if not IsPlayerAdmin(source) then
        TriggerClientEvent('pickle_dj:notify', source, "You don't have permission to create DJ stations", "error")
        return
    end
    
    local identifier = GetIdentifier(source)
    if not identifier then
        TriggerClientEvent('pickle_dj:notify', source, "Failed to get player identifier", "error")
        return
    end
    
    -- Prepare data for database
    local coordsJson = json.encode(stationData.coords)
    
    -- Insert station
    MySQL.Async.insert(
        "INSERT INTO `pickle_dj_stations` (`name`, `coords`, `heading`, `prop`, `created_by`, `identifier`) VALUES (@name, @coords, @heading, @prop, @created_by, @identifier)",
        {
            ['@name'] = stationData.name,
            ['@coords'] = coordsJson,
            ['@heading'] = stationData.heading,
            ['@prop'] = tostring(stationData.prop),
            ['@created_by'] = identifier,
            ['@identifier'] = identifier
        },
        function(stationInsertId)
            if not stationInsertId then
                TriggerClientEvent('pickle_dj:notify', source, "Failed to save DJ station to database", "error")
                return
            end
            
            -- Collect all entities to save
            local entitiesToSave = {}
            
            -- Collect speakers
            if stationData.speakers and type(stationData.speakers) == "table" then
                for _, speaker in ipairs(stationData.speakers) do
                    table.insert(entitiesToSave, {
                        type = "speaker",
                        data = {
                            coords = speaker.coords,
                            heading = speaker.heading,
                            model = speaker.model,
                            data = {
                                speakerType = speaker.speakerType,
                                rotation = speaker.rotation,
                                soundOffset = speaker.soundOffset
                            }
                        }
                    })
                end
            end
            
            -- Collect lights
            if stationData.lights and type(stationData.lights) == "table" then
                for _, light in ipairs(stationData.lights) do
                    table.insert(entitiesToSave, {
                        type = "light",
                        data = {
                            coords = light.coords,
                            heading = light.heading,
                            model = light.model,
                            data = light.data or {}
                        }
                    })
                end
            end
            
            -- Save all entities
            local entityCount = #entitiesToSave
            local savedCount = 0
            local completed = false
            
            local function checkComplete()
                if not completed and savedCount == entityCount then
                    completed = true
                    -- Create music instance
                    local streamId = CreateMusicInstance(stationData.name, stationData.coords, stationData.heading, stationData.speakers)
                    
                    -- Get default light controls
                    local lightControls = getStationLightControls(0) -- Use 0 as temp ID, will be replaced
                    
                    -- Register the station
                    local id = RegisterDJStation({
                        name = stationData.name,
                        coords = stationData.coords,
                        heading = stationData.heading,
                        prop = stationData.prop,
                        speakers = stationData.speakers,
                        lights = stationData.lights,
                        lightControls = lightControls,
                        streamId = streamId,
                    }, false)
                    
                    -- Store mapping
                    StationDBMapping[id] = stationInsertId
                    
                    TriggerClientEvent('pickle_dj:notify', source, "DJ station created successfully!", "success")
                    debugPrint(("^2[pickle_dj]^0 DJ station '%s' created by %s (DB ID: %s, Game ID: %s)"):format(stationData.name, identifier, stationInsertId, id))
                end
            end
            
            -- If no entities, complete immediately
            if entityCount == 0 then
                checkComplete()
            else
                -- Save each entity
                for _, entityInfo in ipairs(entitiesToSave) do
                    SaveEntity(stationInsertId, entityInfo.type, entityInfo.data, function()
                        savedCount = savedCount + 1
                        checkComplete()
                    end)
                end
            end
        end
    )
end)

-- Add entity to station
RegisterServerEvent('pickle_dj:addEntity', function(gameId, entityType, entityData)
    local source = source
    
    -- Check if player can manage this station (owner or admin)
    local canAccess, canManage, errorMessage = CanInteractWithStation(source, gameId)
    if not canManage then
        TriggerClientEvent('pickle_dj:notify', source, errorMessage or "You don't have permission to manage DJ entities", "error")
        return
    end
    
    -- Get database station ID
    local dbId = StationDBMapping[gameId]
    if not dbId then
        TriggerClientEvent('pickle_dj:notify', source, "Station not found in database", "error")
        return
    end
    
    SaveEntityToStation(source, dbId, gameId, entityType, entityData)
end)

function SaveEntityToStation(source, dbId, gameId, entityType, entityData)
    SaveEntity(dbId, entityType, entityData, function(entityInsertId)
        if entityInsertId then
            -- Reload the station with new entity
            local station = DJStations[gameId]
            if station then
                -- Reload entities for this station
                MySQL.Async.fetchAll("SELECT * FROM `pickle_dj_entities` WHERE station_id = @station_id", {
                    ['@station_id'] = dbId
                }, function(entityResults)
                    local entitiesByType = {}
                    if entityResults then
                        for _, entity in ipairs(entityResults) do
                            if not entitiesByType[entity.entity_type] then
                                entitiesByType[entity.entity_type] = {}
                            end
                            
                            local coordsData = json.decode(entity.coords)
                            local coords = vector3(coordsData.x, coordsData.y, coordsData.z)
                            local data = entity.data and json.decode(entity.data) or {}
                            
                            table.insert(entitiesByType[entity.entity_type], {
                                id = entity.id,
                                coords = coords,
                                heading = entity.heading,
                                model = entity.model and tonumber(entity.model) or nil,
                                speakerType = data.speakerType,
                                rotation = data.rotation,
                                soundOffset = data.soundOffset,
                                data = data
                            })
                        end
                    end
                    
                    -- Update station with new entities
                    station.speakers = entitiesByType.speaker or station.speakers
                    station.lights = entitiesByType.light or station.lights
                    station.smokemachines = entitiesByType.smokemachine or station.smokemachines
                    
                    -- Update music instance if speakers changed
                    if station.streamId and entityType == "speaker" then
                        UpdateMusicInstanceSpeakers(station.streamId, station.speakers)
                    end
                    
                    -- Sync to all clients (include light controls)
                    local stationData = {
                        name = station.name,
                        coords = station.coords,
                        heading = station.heading,
                        prop = station.prop,
                        speakers = station.speakers,
                        lights = station.lights,
                        smokemachines = station.smokemachines,
                        lightControls = station.lightControls or getStationLightControls(gameId),
                    }
                    TriggerClientEvent('pickle_dj:registerDJStation', -1, gameId, stationData)
                    TriggerClientEvent('pickle_dj:notify', source, "Entity added successfully!", "success")
                end)
            end
        else
            TriggerClientEvent('pickle_dj:notify', source, "Failed to save entity", "error")
        end
    end)
end

-- Update music instance speakers
function UpdateMusicInstanceSpeakers(musicInstanceId, speakers)
    if not musicInstanceId then return end
    -- Trigger event to update music instance speakers
    TriggerEvent('pickle_dj:updateMusicInstanceSpeakers', musicInstanceId, speakers)
end

-- Move DJ station
RegisterServerEvent('pickle_dj:moveStation', function(gameId, newCoords, newHeading)
    local source = source
    
    local station = DJStations[gameId]
    if not station then
        TriggerClientEvent('pickle_dj:notify', source, "Station not found", "error")
        return
    end
    
    -- Check if player can manage this station (owner or admin)
    local canAccess, canManage, errorMessage = CanInteractWithStation(source, gameId)
    if not canManage then
        TriggerClientEvent('pickle_dj:notify', source, errorMessage or "You don't have permission to move this station", "error")
        return
    end
    
    -- Get database station ID
    local dbId = StationDBMapping[gameId]
    if not dbId then
        TriggerClientEvent('pickle_dj:notify', source, "Station not found in database", "error")
        return
    end
    
    -- Calculate offset from old position to new position
    local oldCoords = station.coords
    local offset = vector3(
        newCoords.x - oldCoords.x,
        newCoords.y - oldCoords.y,
        newCoords.z - oldCoords.z
    )
    
    -- Update station coordinates in database
    local coordsJson = json.encode(newCoords)
    MySQL.Async.execute(
        "UPDATE `pickle_dj_stations` SET `coords` = @coords, `heading` = @heading WHERE `id` = @id",
        {
            ['@coords'] = coordsJson,
            ['@heading'] = newHeading,
            ['@id'] = dbId
        },
        function(affectedRows)
            if affectedRows > 0 then
                -- Update station in memory
                station.coords = newCoords
                station.heading = newHeading
                
                -- Update music instance position if it exists
                if station.streamId then
                    local MusicInstances = exports['pickle_dj']:GetMusicInstances() or {}
                    for instanceId, instance in pairs(MusicInstances) do
                        if instanceId == station.streamId then
                            instance.coords = newCoords
                            instance.heading = newHeading
                            -- Speakers will be updated when entities are reloaded
                            TriggerClientEvent("music:musicInstanceUpdated", -1, instanceId, instance)
                            break
                        end
                    end
                end
                
                -- Update all entity coordinates by the offset
                MySQL.Async.fetchAll(
                    "SELECT `id`, `coords` FROM `pickle_dj_entities` WHERE `station_id` = @station_id",
                    {
                        ['@station_id'] = dbId
                    },
                    function(entities)
                        if entities and #entities > 0 then
                            local updateCount = 0
                            local totalEntities = #entities
                            
                            for _, entity in ipairs(entities) do
                                local oldEntityCoords = json.decode(entity.coords)
                                local newEntityCoords = {
                                    x = oldEntityCoords.x + offset.x,
                                    y = oldEntityCoords.y + offset.y,
                                    z = oldEntityCoords.z + offset.z
                                }
                                local newEntityCoordsJson = json.encode(newEntityCoords)
                                
                                MySQL.Async.execute(
                                    "UPDATE `pickle_dj_entities` SET `coords` = @coords WHERE `id` = @id",
                                    {
                                        ['@coords'] = newEntityCoordsJson,
                                        ['@id'] = entity.id
                                    },
                                    function()
                                        updateCount = updateCount + 1
                                        if updateCount == totalEntities then
                                            -- All entities updated, sync station position to all clients
                                            local stationData = {
                                                name = station.name,
                                                coords = newCoords,
                                                heading = newHeading,
                                                prop = station.prop,
                                                speakers = station.speakers,
                                                lights = station.lights,
                                                smokemachines = station.smokemachines,
                                                lightControls = station.lightControls or getStationLightControls(gameId),
                                            }
                                            TriggerClientEvent('pickle_dj:registerDJStation', -1, gameId, stationData)
                                            TriggerClientEvent('pickle_dj:entityUpdated', -1, gameId)
                                            TriggerClientEvent('pickle_dj:notify', source, "DJ station moved successfully", "success")
                                            debugPrint(("^2[pickle_dj]^0 Station %s moved by %s"):format(gameId, playerIdentifier or "unknown"))
                                        end
                                    end
                                )
                            end
                        else
                            -- No entities to update, sync station position to all clients
                            local stationData = {
                                name = station.name,
                                coords = newCoords,
                                heading = newHeading,
                                prop = station.prop,
                                speakers = station.speakers,
                                lights = station.lights,
                                smokemachines = station.smokemachines,
                                lightControls = station.lightControls or getStationLightControls(gameId),
                            }
                            TriggerClientEvent('pickle_dj:registerDJStation', -1, gameId, stationData)
                            TriggerClientEvent('pickle_dj:entityUpdated', -1, gameId)
                            TriggerClientEvent('pickle_dj:notify', source, "DJ station moved successfully", "success")
                            debugPrint(("^2[pickle_dj]^0 Station %s moved by %s"):format(gameId, playerIdentifier or "unknown"))
                        end
                    end
                )
            else
                TriggerClientEvent('pickle_dj:notify', source, "Failed to update station", "error")
            end
        end
    )
end)

-- Remove entity from station
RegisterServerEvent('pickle_dj:removeEntity', function(entityId)
    local source = source
    
    -- Get entity info to find station first
    MySQL.Async.fetchAll("SELECT station_id, entity_type FROM `pickle_dj_entities` WHERE id = @id", {
        ['@id'] = entityId
    }, function(results)
        if not results or #results == 0 then
            TriggerClientEvent('pickle_dj:notify', source, "Entity not found", "error")
            return
        end
        
        local stationId = results[1].station_id
        
        -- Find game ID for this station
        local gameId = nil
        for gId, dbId in pairs(StationDBMapping) do
            if dbId == stationId then
                gameId = gId
                break
            end
        end
        
        if not gameId then
            TriggerClientEvent('pickle_dj:notify', source, "Station not found", "error")
            return
        end
        
        -- Check if player can manage this station (owner or admin)
        local canAccess, canManage, errorMessage = CanInteractWithStation(source, gameId)
        if not canManage then
            TriggerClientEvent('pickle_dj:notify', source, errorMessage or "You don't have permission to manage DJ entities", "error")
            return
        end
        
        -- Delete entity
        MySQL.Async.execute("DELETE FROM `pickle_dj_entities` WHERE id = @id", {
            ['@id'] = entityId
        }, function(affectedRows)
            if affectedRows > 0 then
                if gameId then
                    -- Reload entities for this station
                    MySQL.Async.fetchAll("SELECT * FROM `pickle_dj_entities` WHERE station_id = @station_id", {
                        ['@station_id'] = stationId
                    }, function(entityResults)
                        local entitiesByType = {}
                        if entityResults then
                            for _, entity in ipairs(entityResults) do
                                if not entitiesByType[entity.entity_type] then
                                    entitiesByType[entity.entity_type] = {}
                                end
                                
                                local coordsData = json.decode(entity.coords)
                                local coords = vector3(coordsData.x, coordsData.y, coordsData.z)
                                local data = entity.data and json.decode(entity.data) or {}
                                
                                local entityObj = {
                                    id = entity.id,
                                    coords = coords,
                                    heading = entity.heading,
                                    model = entity.model and tonumber(entity.model) or nil,
                                    speakerType = data.speakerType,
                                    rotation = data.rotation,
                                    soundOffset = data.soundOffset,
                                    data = data
                                }
                                
                                -- Extract light-specific fields for easier access
                                if entity.entity_type == "light" then
                                    entityObj.lightType = data.lightType
                                    entityObj.colorSpec = data.colorSpec
                                end
                                
                                table.insert(entitiesByType[entity.entity_type], entityObj)
                            end
                        end
                        
                        -- Update station
                        local station = DJStations[gameId]
                        if station then
                            station.speakers = entitiesByType.speaker or nil
                            station.lights = entitiesByType.light or nil
                            station.smokemachines = entitiesByType.smokemachine or nil
                            
                            -- Update music instance if speakers changed
                            if station.streamId and results[1].entity_type == "speaker" then
                                UpdateMusicInstanceSpeakers(station.streamId, station.speakers)
                            end
                            
                            -- Sync to all clients (include light controls)
                            local stationData = {
                                name = station.name,
                                coords = station.coords,
                                heading = station.heading,
                                prop = station.prop,
                                speakers = station.speakers,
                                lights = station.lights,
                                smokemachines = station.smokemachines,
                                lightControls = station.lightControls or getStationLightControls(gameId),
                            }
                            TriggerClientEvent('pickle_dj:registerDJStation', -1, gameId, stationData)
                            TriggerClientEvent('pickle_dj:notify', source, "Entity removed successfully!", "success")
                        end
                    end)
                else
                    TriggerClientEvent('pickle_dj:notify', source, "Entity removed, but could not update station", "warning")
                end
            else
                TriggerClientEvent('pickle_dj:notify', source, "Failed to remove entity", "error")
            end
        end)
    end)
end)

-- Update entity color spec
RegisterNetEvent('pickle_dj:updateEntityColorSpec', function(entityId, colorSpec)
    local source = source
    
    -- Validate colorSpec
    if colorSpec ~= "primary" and colorSpec ~= "secondary" then
        TriggerClientEvent('pickle_dj:notify', source, "Invalid color specification", "error")
        return
    end
    
    -- Get entity data
    MySQL.Async.fetchAll("SELECT * FROM `pickle_dj_entities` WHERE id = @id", {
        ['@id'] = entityId
    }, function(results)
        if not results or #results == 0 then
            TriggerClientEvent('pickle_dj:notify', source, "Entity not found", "error")
            return
        end
        
        local entity = results[1]
        local stationId = entity.station_id
        
        -- Find game ID for this station
        local gameId = nil
        for gId, dbId in pairs(StationDBMapping) do
            if dbId == stationId then
                gameId = gId
                break
            end
        end
        
        if not gameId then
            TriggerClientEvent('pickle_dj:notify', source, "Station not found", "error")
            return
        end
        
        -- Check if player can manage this station (owner or admin)
        local canAccess, canManage, errorMessage = CanInteractWithStation(source, gameId)
        if not canManage then
            TriggerClientEvent('pickle_dj:notify', source, errorMessage or "You don't have permission to manage DJ entities", "error")
            return
        end
        
        local data = entity.data and json.decode(entity.data) or {}
        
        -- Update colorSpec
        data.colorSpec = colorSpec
        
        -- Save updated data
        MySQL.Async.execute("UPDATE `pickle_dj_entities` SET data = @data WHERE id = @id", {
            ['@data'] = json.encode(data),
            ['@id'] = entityId
        }, function(rowsChanged)
            if rowsChanged > 0 then
                -- Find the station this entity belongs to
                local stationId = entity.station_id
                local gameId = nil
                -- Find gameId by looking up the database ID in StationDBMapping
                for gId, dbId in pairs(StationDBMapping) do
                    if dbId == stationId then
                        gameId = gId
                        break
                    end
                end
                
                if gameId then
                    -- Reload entities for this station
                    MySQL.Async.fetchAll("SELECT * FROM `pickle_dj_entities` WHERE station_id = @station_id", {
                        ['@station_id'] = stationId
                    }, function(entityResults)
                        local entitiesByType = {}
                        if entityResults then
                            for _, ent in ipairs(entityResults) do
                                if not entitiesByType[ent.entity_type] then
                                    entitiesByType[ent.entity_type] = {}
                                end
                                
                                local coordsData = json.decode(ent.coords)
                                local coords = vector3(coordsData.x, coordsData.y, coordsData.z)
                                local entData = ent.data and json.decode(ent.data) or {}
                                
                                table.insert(entitiesByType[ent.entity_type], {
                                    id = ent.id,
                                    coords = coords,
                                    heading = ent.heading,
                                    model = ent.model and tonumber(ent.model) or nil,
                                    speakerType = entData.speakerType,
                                    rotation = entData.rotation,
                                    soundOffset = entData.soundOffset,
                                    lightType = entData.lightType,
                                    colorSpec = entData.colorSpec,
                                    data = entData
                                })
                            end
                        end
                        
                        -- Update station
                        local station = DJStations[gameId]
                        if station then
                            station.speakers = entitiesByType.speaker or nil
                            station.lights = entitiesByType.light or nil
                            station.smokemachines = entitiesByType.smokemachine or nil
                            
                            -- Sync to all clients (include light controls)
                            local stationData = {
                                name = station.name,
                                coords = station.coords,
                                heading = station.heading,
                                prop = station.prop,
                                speakers = station.speakers,
                                lights = station.lights,
                                smokemachines = station.smokemachines,
                                lightControls = station.lightControls or getStationLightControls(gameId),
                            }
                            TriggerClientEvent('pickle_dj:registerDJStation', -1, gameId, stationData)
                            TriggerClientEvent('pickle_dj:notify', source, "Light color updated successfully!", "success")
                        end
                    end)
                else
                    TriggerClientEvent('pickle_dj:notify', source, "Station not found", "error")
                end
            else
                TriggerClientEvent('pickle_dj:notify', source, "Failed to update entity", "error")
            end
        end)
    end)
end)

-- Request light controls state for a station (kept for backwards compatibility, but not needed)
RegisterNetEvent('pickle_dj:requestLightControls', function(stationId)
    local source = source
    local controls = getStationLightControls(stationId)
    -- Send current state to requesting client
    TriggerClientEvent('pickle_dj:lightControlsState', source, stationId, controls)
end)

-- Update light controls for a station (networked to all clients)
RegisterNetEvent('pickle_dj:updateLightControls', function(stationId, lightType, property, value)
    local source = source
    local controls = getStationLightControls(stationId)
    
    if not controls or not controls.lights or not controls.lights[lightType] then
        return
    end
    
    -- Update the control value
    local numericValue = value
    if property == "enabled" then
        controls.lights[lightType].enabled = value == true
        numericValue = value == true
    elseif property == "rotateHorizontal" or property == "rotateVertical" then
        controls.lights[lightType][property] = value == true
        numericValue = value == true
    elseif property == "flash" then
        -- Use shared function to convert string to number
        numericValue = GetFlashValue(value)
        if numericValue then
            controls.lights[lightType].flash = numericValue
        end
    elseif property == "speed" then
        -- Use shared function to convert string to number
        numericValue = GetSpeedValue(value)
        if numericValue then
            controls.lights[lightType].speed = numericValue
        end
    elseif property == "primaryColor" or property == "secondaryColor" then
        -- Color is an array [r, g, b]
        if type(value) == "table" and #value == 3 then
            controls.lights[lightType][property] = {value[1], value[2], value[3]}
            numericValue = value
        end
    end
    
    -- Update station data
    if DJStations[stationId] then
        DJStations[stationId].lightControls = controls
    end
    
    -- Network the update to all clients with the numeric value from server
    TriggerClientEvent('pickle_dj:lightControlsUpdated', -1, stationId, lightType, property, numericValue)
end)

-- Update all light controls for a station (networked to all clients)
RegisterNetEvent('pickle_dj:updateAllLightControls', function(stationId, property, value)
    local source = source
    local controls = getStationLightControls(stationId)
    
    if not controls or not controls.lights then
        return
    end
    
    -- Update all light types with the same value
    local numericValue = value
    local lightTypes = { "ambient", "spotlight", "barlight" }
    
    for _, lightType in ipairs(lightTypes) do
        if not controls.lights[lightType] then
            goto continue_light
        end
        
        -- Update the control value
        if property == "enabled" then
            controls.lights[lightType].enabled = value == true
            numericValue = value == true
        elseif property == "rotateHorizontal" or property == "rotateVertical" then
            controls.lights[lightType][property] = value == true
            numericValue = value == true
        elseif property == "flash" then
            -- Use shared function to convert string to number
            numericValue = GetFlashValue(value)
            if numericValue then
                controls.lights[lightType].flash = numericValue
            end
        elseif property == "speed" then
            -- Use shared function to convert string to number
            numericValue = GetSpeedValue(value)
            if numericValue then
                controls.lights[lightType].speed = numericValue
            end
        end
        
        ::continue_light::
    end
    
    -- Update station data
    if DJStations[stationId] then
        DJStations[stationId].lightControls = controls
    end
    
    -- Network the update to all clients for each light type
    for _, lightType in ipairs(lightTypes) do
        if controls.lights[lightType] then
            TriggerClientEvent('pickle_dj:lightControlsUpdated', -1, stationId, lightType, property, numericValue)
        end
    end
end)

-- Load whitelist for a station (returns cached data)
function LoadStationWhitelist(dbId)
    return StationWhitelists[dbId] or {}
end

-- Check if player has whitelist access to station
function CheckWhitelistAccess(source, stationId)
    local dbId = StationDBMapping[stationId]
    if not dbId then return true end -- No mapping means allow
    
    local whitelist = LoadStationWhitelist(dbId)
    
    -- No whitelist entries means open access
    if not whitelist or #whitelist == 0 then
        return true
    end
    
    local playerIdentifier = GetIdentifier(source)
    if not playerIdentifier then return false end
    
    -- Get player job info
    local jobName = nil
    local jobRank = 0
    
    if GetResourceState('es_extended') == 'started' then
        local ESX = exports.es_extended:getSharedObject()
        local xPlayer = ESX.GetPlayerFromId(source)
        if xPlayer then
            jobName = xPlayer.job.name
            jobRank = xPlayer.job.grade
        end
    elseif GetResourceState('qb-core') == 'started' then
        local QBCore = exports['qb-core']:GetCoreObject()
        local xPlayer = QBCore.Functions.GetPlayer(source)
        if xPlayer and xPlayer.PlayerData then
            jobName = xPlayer.PlayerData.job.name
            jobRank = xPlayer.PlayerData.job.grade.level
        end
    end
    
    -- Check whitelist entries
    for _, entry in ipairs(whitelist) do
        if entry.type == 'player' and entry.value == playerIdentifier then
            return true
        elseif entry.type == 'job' and entry.value == jobName and jobRank >= entry.rank then
            return true
        elseif entry.type == 'ace' and IsPlayerAceAllowed(source, entry.value) then
            return true
        end
    end
    
    return false
end

-- Callback to check if player can access DJ station interaction (menu)
lib.callback.register('pickle_dj:canAccessStationInteraction', function(source, stationId)
    return CanInteractWithStation(source, stationId)
end)

-- Callback to check if player can access DJ controller
lib.callback.register('pickle_dj:canAccessController', function(source, stationId)
    local station = DJStations[stationId]
    if not station or not station.streamId then
        return false, "Station not found"
    end
    
    -- Check whitelist first (if whitelist exists, must be on it)
    local canAccess, canManage, errorMessage = CanInteractWithStation(source, stationId)
    if not canAccess then
        return false, errorMessage
    end
    
    -- Get the music instance for this station
    local musicInstanceId = station.streamId
    local MusicInstances = exports['pickle_dj']:GetMusicInstances() or {}
    local inst = MusicInstances[musicInstanceId]
    if not inst then
        return false, "Music instance not found"
    end
    
    -- If player is already broadcasting on this exact table, allow access
    if inst.broadcaster == source and inst.streamId ~= nil then
        return true
    end
    
    -- Only allow one broadcaster per instance; don't allow takeover if another player is broadcasting and in range
    if inst.broadcaster ~= nil and inst.broadcaster ~= source then
        -- Another player is already broadcasting, check if they're still valid
        local broadcasterPed = GetPlayerPed(inst.broadcaster)
        if broadcasterPed and broadcasterPed ~= 0 then
            -- Broadcaster is still connected, check if they're in range
            local broadcasterCoords = GetEntityCoords(broadcasterPed)
            if broadcasterCoords and broadcasterCoords.x ~= 0.0 then
                local inRange = false
                -- Check if broadcaster is in range of any speaker
                if inst.speakers and type(inst.speakers) == "table" and #inst.speakers > 0 then
                    for _, sp in ipairs(inst.speakers) do
                        if sp.coords then
                            local spec = (Config and Config.SpeakerProps and sp.speakerType and Config.SpeakerProps[sp.speakerType]) or nil
                            local r = (spec and spec.soundRadius) or 0.0
                            if r > 0.0 then
                                local d = #(broadcasterCoords - sp.coords)
                                if d <= r then
                                    inRange = true
                                    break
                                end
                            end
                        end
                    end
                elseif inst.coords then
                    -- Fallback to controller coords with default radius
                    local controllerRadius = Config.MusicRadius or 50.0
                    local d = #(broadcasterCoords - inst.coords)
                    if d <= controllerRadius then
                        inRange = true
                    end
                end
                
                if inRange then
                    -- Broadcaster is still in range, deny the request
                    return false, "Another player is already controlling this DJ station"
                else
                    -- Broadcaster is out of range, allow takeover
                    return true
                end
            else
                -- Invalid coords, allow takeover
                return true
            end
        else
            -- Broadcaster is no longer connected, allow takeover
            return true
        end
    end
    
    -- No broadcaster or player is allowed, return true
    return true
end)

-- Handle DJ controller opening - automatically assign broadcaster
RegisterNetEvent('pickle_dj:openController', function(stationId)
    local source = source
    local station = DJStations[stationId]
    if not station or not station.streamId then
        debugPrint(("[pickle_dj] ERROR: Cannot open controller - station %s not found or missing streamId"):format(tostring(stationId)))
        return
    end
    
    -- Get the music instance for this station
    local musicInstanceId = station.streamId
    local MusicInstances = exports['pickle_dj']:GetMusicInstances() or {}
    local inst = MusicInstances[musicInstanceId]
    if not inst then
        debugPrint(("[pickle_dj] ERROR: Cannot open controller - music instance %s not found"):format(tostring(musicInstanceId)))
        return
    end
    
    -- Ensure musicInstanceId is valid
    if not musicInstanceId or musicInstanceId == nil then
        debugPrint(("[pickle_dj] ERROR: Cannot open controller - invalid musicInstanceId: %s"):format(tostring(musicInstanceId)))
        return
    end
    
    -- If player is already broadcasting on this exact table, don't do anything
    -- The client is already broadcasting and connections are established
    -- No need to send the event which could reset connections
    if inst.broadcaster == source and inst.streamId ~= nil then
        -- Player is already broadcasting on this table, just return
        -- Client state should already be in sync
        return
    end
    
    -- Check if player is already broadcasting on another table
    for id, otherInst in pairs(MusicInstances) do
        if otherInst.broadcaster == source and id ~= musicInstanceId then
            -- Remove them from the other table
            otherInst.broadcaster = nil
            otherInst.streamId = nil
            TriggerClientEvent("music:musicInstanceUpdated", -1, id, otherInst)
            TriggerClientEvent('music:rtc:broadcastStopped', -1, json.encode({}))
        end
    end
    
    -- Only allow one broadcaster per instance; don't allow takeover if another player is broadcasting and in range
    if inst.broadcaster ~= nil and inst.broadcaster ~= source then
        -- Another player is already broadcasting, check if they're still valid
        local broadcasterPed = GetPlayerPed(inst.broadcaster)
        if broadcasterPed and broadcasterPed ~= 0 then
            -- Broadcaster is still connected, check if they're in range
            local broadcasterCoords = GetEntityCoords(broadcasterPed)
            if broadcasterCoords and broadcasterCoords.x ~= 0.0 then
                local inRange = false
                -- Check if broadcaster is in range of any speaker
                if inst.speakers and type(inst.speakers) == "table" and #inst.speakers > 0 then
                    for _, sp in ipairs(inst.speakers) do
                        if sp.coords then
                            local spec = (Config and Config.SpeakerProps and sp.speakerType and Config.SpeakerProps[sp.speakerType]) or nil
                            local r = (spec and spec.soundRadius) or 0.0
                            if r > 0.0 then
                                local d = #(broadcasterCoords - sp.coords)
                                if d <= r then
                                    inRange = true
                                    break
                                end
                            end
                        end
                    end
                elseif inst.coords then
                    -- Fallback to controller coords with default radius
                    local controllerRadius = Config.MusicRadius or 50.0
                    local d = #(broadcasterCoords - inst.coords)
                    if d <= controllerRadius then
                        inRange = true
                    end
                end
                
                if inRange then
                    -- Broadcaster is still in range, deny the request (shouldn't happen if callback worked correctly, but keep as safety check)
                    debugPrint(("[pickle_dj] Player %s tried to take over DJ station %s, but player %s is already broadcasting and in range"):format(source, stationId, inst.broadcaster))
                    return
                else
                    -- Broadcaster is out of range, clean them up and allow takeover
                    debugPrint(("[pickle_dj] Player %s taking over DJ station %s from out-of-range broadcaster %s (cleaning up)"):format(source, stationId, inst.broadcaster))
                    inst.broadcaster = nil
                    inst.streamId = nil
                    TriggerClientEvent("music:musicInstanceUpdated", -1, musicInstanceId, inst)
                    TriggerClientEvent('music:rtc:broadcastStopped', -1, json.encode({}))
                    TriggerClientEvent('pickle_dj:stopBroadcasting', broadcasterSrc)
                end
            else
                -- Invalid coords, allow takeover
                debugPrint(("[pickle_dj] Player %s taking over DJ station %s from broadcaster %s with invalid coords"):format(source, stationId, inst.broadcaster))
            end
        else
            -- Broadcaster is no longer connected, allow takeover
            debugPrint(("[pickle_dj] Player %s taking over DJ station %s from disconnected broadcaster %s"):format(source, stationId, inst.broadcaster))
        end
    end
    
    -- Generate streamId for this broadcaster
    local streamId = tostring(source) .. "_" .. tostring(math.random(100000, 999999))
    
    -- Pre-set the broadcaster and streamId so the instance is marked as active
    -- The client will then announce the broadcast when ready, which will confirm/update this
    inst.broadcaster = source
    inst.streamId = streamId
    
    -- Notify client to start broadcasting (client will announce via music:rtc:announceBroadcast when ready)
    TriggerClientEvent('pickle_dj:startBroadcasting', source, musicInstanceId, streamId)
    
    -- Push updated instance to clients
    TriggerClientEvent("music:musicInstanceUpdated", -1, musicInstanceId, inst)
    -- legacy: notify broadcast started
    -- TriggerClientEvent('music:rtc:broadcastStarted', -1, json.encode({ streamId = streamId, broadcaster = source }))
end)

-- Update particle effects for a station (networked to all clients)
RegisterNetEvent('pickle_dj:updateParticleEffect', function(stationId, effect, value)
    local source = source
    local effects = getStationParticleEffects(stationId)
    
    if not effects then
        return
    end
    
    if effect == "smoke" then
        effects.smoke = value == true
    elseif effect == "fire" then
        effects.fire = value == true
    end
    
    -- Network the update to all clients
    TriggerClientEvent('pickle_dj:particleEffectsUpdated', -1, stationId, effect, value)
end)

-- Load whitelist when station is loaded
function LoadStationWhitelistOnStart()
    MySQL.Async.fetchAll("SELECT * FROM `pickle_dj_whitelist`", {}, function(results)
        if results then
            for _, entry in ipairs(results) do
                if not StationWhitelists[entry.station_id] then
                    StationWhitelists[entry.station_id] = {}
                end
                table.insert(StationWhitelists[entry.station_id], {
                    id = entry.id,
                    type = entry.type,
                    value = entry.value,
                    name = entry.name,
                    rank = entry.rank or 0
                })
            end
        end
    end)
end

-- Reload whitelist for a specific station
function ReloadStationWhitelist(dbId)
    StationWhitelists[dbId] = nil
    MySQL.Async.fetchAll(
        "SELECT * FROM `pickle_dj_whitelist` WHERE `station_id` = @station_id",
        {
            ['@station_id'] = dbId
        },
        function(results)
            StationWhitelists[dbId] = {}
            if results then
                for _, entry in ipairs(results) do
                    table.insert(StationWhitelists[dbId], {
                        id = entry.id,
                        type = entry.type,
                        value = entry.value,
                        name = entry.name,
                        rank = entry.rank or 0
                    })
                end
            end
        end
    )
end

-- Get nearby players for whitelist
lib.callback.register('pickle_dj:getNearbyPlayers', function(source, coords, radius)
    local nearbyPlayers = {}
    local playerCoords = coords or GetEntityCoords(GetPlayerPed(source))
    local searchRadius = radius or 10.0
    
    for _, playerId in ipairs(GetPlayers()) do
        local targetId = tonumber(playerId)
        if targetId and targetId ~= source then
            local targetPed = GetPlayerPed(targetId)
            if targetPed and targetPed > 0 then
                local targetCoords = GetEntityCoords(targetPed)
                local distance = #(playerCoords - targetCoords)
                
                if distance <= searchRadius then
                    local identifier = GetIdentifier(targetId)
                    local name = GetPlayerCharacterName(targetId)
                    if identifier then
                        table.insert(nearbyPlayers, {
                            serverId = targetId,
                            identifier = identifier,
                            name = name or "Unknown",
                            distance = math.floor(distance)
                        })
                    end
                end
            end
        end
    end
    
    -- Sort by distance
    table.sort(nearbyPlayers, function(a, b) return a.distance < b.distance end)
    
    return nearbyPlayers
end)

-- Get whitelist for a station
lib.callback.register('pickle_dj:getWhitelist', function(source, gameId)
    local station = DJStations[gameId]
    if not station then return {} end
    
    local dbId = StationDBMapping[gameId]
    if not dbId then return {} end
    
    -- Check if player can manage whitelist
    local isAdmin = IsPlayerAdmin(source)
    local playerIdentifier = GetIdentifier(source)
    local isOwner = playerIdentifier and station.identifier and station.identifier == playerIdentifier
    
    if not isAdmin and not isOwner then
        return {}
    end
    
    return LoadStationWhitelist(dbId)
end)

-- Add to whitelist
RegisterServerEvent('pickle_dj:addWhitelist', function(gameId, whitelistType, value, name, rank)
    local source = source
    
    local station = DJStations[gameId]
    if not station then
        TriggerClientEvent('pickle_dj:notify', source, "Station not found", "error")
        return
    end
    
    local dbId = StationDBMapping[gameId]
    if not dbId then
        TriggerClientEvent('pickle_dj:notify', source, "Station not found in database", "error")
        return
    end
    
    -- Check permissions
    local isAdmin = IsPlayerAdmin(source)
    local playerIdentifier = GetIdentifier(source)
    local isOwner = playerIdentifier and station.identifier and station.identifier == playerIdentifier
    
    if not isAdmin and not isOwner then
        TriggerClientEvent('pickle_dj:notify', source, "You don't have permission to manage whitelist", "error")
        return
    end
    
    -- Non-admin owners can only add players
    if not isAdmin and isOwner and whitelistType ~= 'player' then
        TriggerClientEvent('pickle_dj:notify', source, "You can only add players to the whitelist", "error")
        return
    end
    
    -- Insert into database
    MySQL.Async.insert(
        "INSERT INTO `pickle_dj_whitelist` (`station_id`, `type`, `value`, `name`, `rank`) VALUES (@station_id, @type, @value, @name, @rank)",
        {
            ['@station_id'] = dbId,
            ['@type'] = whitelistType,
            ['@value'] = value,
            ['@name'] = name or nil,
            ['@rank'] = rank or 0
        },
        function(insertId)
            if insertId then
                -- Reload whitelist cache
                ReloadStationWhitelist(dbId)
                TriggerClientEvent('pickle_dj:notify', source, "Added to whitelist", "success")
            else
                TriggerClientEvent('pickle_dj:notify', source, "Failed to add to whitelist", "error")
            end
        end
    )
end)

-- Remove from whitelist
RegisterServerEvent('pickle_dj:removeWhitelist', function(gameId, whitelistId)
    local source = source
    
    local station = DJStations[gameId]
    if not station then
        TriggerClientEvent('pickle_dj:notify', source, "Station not found", "error")
        return
    end
    
    local dbId = StationDBMapping[gameId]
    if not dbId then
        TriggerClientEvent('pickle_dj:notify', source, "Station not found in database", "error")
        return
    end
    
    -- Check permissions
    local isAdmin = IsPlayerAdmin(source)
    local playerIdentifier = GetIdentifier(source)
    local isOwner = playerIdentifier and station.identifier and station.identifier == playerIdentifier
    
    if not isAdmin and not isOwner then
        TriggerClientEvent('pickle_dj:notify', source, "You don't have permission to manage whitelist", "error")
        return
    end
    
    -- Check if entry exists and get its type
    MySQL.Async.fetchAll(
        "SELECT `type` FROM `pickle_dj_whitelist` WHERE `id` = @id AND `station_id` = @station_id",
        {
            ['@id'] = whitelistId,
            ['@station_id'] = dbId
        },
        function(results)
            if not results or #results == 0 then
                TriggerClientEvent('pickle_dj:notify', source, "Whitelist entry not found", "error")
                return
            end
            
            -- Non-admin owners can only remove players
            if not isAdmin and isOwner and results[1].type ~= 'player' then
                TriggerClientEvent('pickle_dj:notify', source, "You can only remove players from the whitelist", "error")
                return
            end
            
            -- Delete from database
            MySQL.Async.execute(
                "DELETE FROM `pickle_dj_whitelist` WHERE `id` = @id",
                {
                    ['@id'] = whitelistId
                },
                function(affectedRows)
                    if affectedRows > 0 then
                        -- Reload whitelist cache
                        ReloadStationWhitelist(dbId)
                        TriggerClientEvent('pickle_dj:notify', source, "Removed from whitelist", "success")
                    else
                        TriggerClientEvent('pickle_dj:notify', source, "Failed to remove from whitelist", "error")
                    end
                end
            )
        end
    )
end)

-- Request particle effects state for a station
RegisterNetEvent('pickle_dj:requestParticleEffects', function(stationId)
    local source = source
    local effects = getStationParticleEffects(stationId)
    -- Send current state to requesting client
    TriggerClientEvent('pickle_dj:particleEffectsState', source, stationId, effects)
end)

-- Note: We no longer stop broadcasting when controller closes
-- Broadcasting continues until player leaves range of all speakers (handled by range check thread)

-- Check if broadcaster is in range of speakers (called periodically)
CreateThread(function()
    while true do
        Wait(5000) -- Check every 5 seconds
        
        local MusicInstances = exports['pickle_dj']:GetMusicInstances() or {}
        for instanceId, inst in pairs(MusicInstances) do
            if inst.broadcaster and inst.streamId then
                local broadcasterSrc = inst.broadcaster
                local broadcasterPed = GetPlayerPed(broadcasterSrc)
                if not broadcasterPed or broadcasterPed == 0 then
                    -- Player disconnected, remove broadcaster
                    inst.broadcaster = nil
                    inst.streamId = nil
                    TriggerClientEvent("music:musicInstanceUpdated", -1, instanceId, inst)
                    TriggerClientEvent('music:rtc:broadcastStopped', -1, json.encode({}))
                    goto continue_instance
                end
                
                local broadcasterCoords = GetEntityCoords(broadcasterPed)
                if not broadcasterCoords or broadcasterCoords.x == 0.0 then
                    -- Invalid coords, remove broadcaster
                    inst.broadcaster = nil
                    inst.streamId = nil
                    TriggerClientEvent("music:musicInstanceUpdated", -1, instanceId, inst)
                    TriggerClientEvent('music:rtc:broadcastStopped', -1, json.encode({}))
                    goto continue_instance
                end
                
                -- Check if broadcaster is in range of any speaker
                local inRange = false
                if inst.speakers and type(inst.speakers) == "table" and #inst.speakers > 0 then
                    for _, sp in ipairs(inst.speakers) do
                        if sp.coords then
                            local spec = (Config and Config.SpeakerProps and sp.speakerType and Config.SpeakerProps[sp.speakerType]) or nil
                            local r = (spec and spec.soundRadius) or 0.0
                            if r > 0.0 then
                                local d = #(broadcasterCoords - sp.coords)
                                if d <= r then
                                    inRange = true
                                    break
                                end
                            end
                        end
                    end
                elseif inst.coords then
                    -- Fallback to controller coords with default radius
                    local controllerRadius = Config.MusicRadius or 50.0
                    local d = #(broadcasterCoords - inst.coords)
                    if d <= controllerRadius then
                        inRange = true
                    end
                end
                
                -- If broadcaster is out of range, remove them
                if not inRange then
                    inst.broadcaster = nil
                    inst.streamId = nil
                    TriggerClientEvent("music:musicInstanceUpdated", -1, instanceId, inst)
                    TriggerClientEvent('music:rtc:broadcastStopped', -1, json.encode({}))
                    TriggerClientEvent('pickle_dj:stopBroadcasting', broadcasterSrc)
                end
                
                ::continue_instance::
            end
        end
    end
end)
