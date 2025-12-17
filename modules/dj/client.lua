local DJStations = {}
local LocalDJStations = {}
local stationControls = {}
local DJ_CAMERA = nil

function CreateDJCamera()
    local initialCamSettings = {
        coords = GetGameplayCamCoord(),
        rotation = GetGameplayCamRot(),
        fov = GetGameplayCamFov(),
    }
    DJ_CAMERA = CreateCamWithParams("DEFAULT_SCRIPTED_CAMERA", 
        initialCamSettings.coords.x, initialCamSettings.coords.y, initialCamSettings.coords.z, 
        initialCamSettings.rotation.x, initialCamSettings.rotation.y, initialCamSettings.rotation.z, initialCamSettings.fov
    )
    SetCamActive(DJ_CAMERA, true)
    RenderScriptCams(true, false, 0, true, true)
end

function ExitDJCamera(durationValue)
    local duration = durationValue
    if duration == nil then duration = 2000 end
    ClearFocus()
	DestroyAllCams()
    RenderScriptCams(false, true, duration, true, false) 
end

function UnregisterDJStation(id)
    if LocalDJStations[id] then
        DeleteScriptObject(LocalDJStations[id].entity)
        if LocalDJStations[id].speakerEntities then
            for _, ent in ipairs(LocalDJStations[id].speakerEntities) do
                DeleteScriptObject(ent)
            end
        end
        -- Clean up entity data entities
        if LocalDJStations[id].entityData then
            for _, speakerData in ipairs(LocalDJStations[id].entityData.speakers or {}) do
                if speakerData.entity and DoesEntityExist(speakerData.entity) then
                    DeleteScriptObject(speakerData.entity)
                end
            end
            for _, lightData in ipairs(LocalDJStations[id].entityData.lights or {}) do
                if lightData.entity and DoesEntityExist(lightData.entity) then
                    DeleteScriptObject(lightData.entity)
                end
            end
        end
        for k,v in pairs(LocalDJStations[id].vfxEntities) do
            DeleteScriptObject(v.lightProp)
            DeleteScriptObject(v.visualProp)
            DeleteScriptObject(v.lampProp)
        end
        LocalDJStations[id].vfxEntities = nil
    end
    LocalDJStations[id] = nil
end

function RegisterDJStation(id)
    if LocalDJStations[id] then UnregisterDJStation(id) end
	local station = DJStations[id]
	if not station then return end
	LocalDJStations[id] = {
		interact = CreateInteraction({
			label = station.name,
			coords = station.coords,
			heading = station.heading,
		}, function(selection, targetData)
            lib.registerContext({
                id = 'dj_station_' .. id,
                title = station.name,
                options = {
                    { 
                        title = 'Open DJ Controller', 
                        description = 'Open the DJ controller for this station.',
                        icon = 'music',
                        onSelect = function()
                            SetMusicController(station.streamId)
                            CreateThread(function()
                                local coords = GetEntityCoords(LocalDJStations[id].entity) + vector3(0.0, 0.0, 2.0)
                                coords = coords + GetEntityForwardVector(LocalDJStations[id].entity) * -1.0
                                SetNuiFocus(true, true)
                                CreateDJCamera()
                                SetCamParams(DJ_CAMERA, coords.x, coords.y, coords.z,
                                    -30.0, 0.0, station.heading + 0.0, 90.0, 
                                    2000, 0, 0, 2
                                )
                                -- Request latest light controls state from server when opening controller
                                -- This ensures we always have the correct state, even if client state is stale
                                TriggerServerEvent('pickle_dj:requestLightControls', id)
                                SendNUIMessage({
                                    type = 'music:setControllerVisible',
                                    visible = true,
                                    stationId = id
                                })
                            end)
                        end
                    },
                    { 
                        title = 'Manage DJ Objects', 
                        description = 'Place speakers, lights, and other objects for this station.',
                        icon = 'cog',
                        onSelect = function()
                            OpenEntityManagementMenu(id)
                        end
                    },
                }
            })
            lib.showContext('dj_station_' .. id)

		end),
        entity = nil,
        vfxEntities = {},
        speakerEntities = {},
	}
    LocalDJStations[id].entity = CreateProp(station.prop, station.coords.x, station.coords.y, station.coords.z, false, true, false)
    SetEntityRotation(LocalDJStations[id].entity, 0.0, 0.0, station.heading, 2, true)
    -- Initialize entity storage
    LocalDJStations[id].entityData = {
        speakers = {},
        lights = {},
        other = {}
    }
    
    -- Spawn configured speakers for this station (visuals only)
    if station.speakers and type(station.speakers) == "table" then
        for _, sp in ipairs(station.speakers) do
            local spec = (Config.SpeakerProps and sp.speakerType and Config.SpeakerProps[sp.speakerType]) or nil
            local model = (spec and spec.model) or (sp.model or `prop_speaker_06`)
            local offset = (spec and spec.soundOffset) or vector3(0.0, 0.0, 0.0)
            local sc = sp.coords or station.coords
            local pos = vector3(sc.x + offset.x, sc.y + offset.y, sc.z + offset.z)
            local ent = CreateProp(model, pos.x, pos.y, pos.z, false, true, false)
            local h = sp.heading or (spec and spec.heading) or station.heading or 0.0
            local rot = spec and spec.rotation or vector3(0.0, 0.0, 0.0)
            SetEntityRotation(ent, rot.x, rot.y, h + rot.z, 2, true)
            FreezeEntityPosition(ent, true)
            table.insert(LocalDJStations[id].speakerEntities, ent)
            -- Store entity data with database ID
            table.insert(LocalDJStations[id].entityData.speakers, {
                entity = ent,
                dbId = sp.id,
                data = sp
            })
        end
    end
    
    -- Spawn configured lights for this station
    if station.lights and type(station.lights) == "table" then
        for _, light in ipairs(station.lights) do
            local spec = (Config.LightTypes and light.data.lightType and Config.LightTypes[light.data.lightType]) or nil
            local model = (spec and spec.model) or (light.model or `stg_blinder`)
            local ent = CreateProp(model, light.coords.x, light.coords.y, light.coords.z, false, true, false)
            SetEntityCoordsNoOffset(ent, light.coords.x, light.coords.y, light.coords.z, 0.0, 0.0, 0.0)
            local rot = spec and spec.rotation or vector3(0.0, 0.0, 0.0)
            SetEntityRotation(ent, rot.x, rot.y, light.heading + rot.z, 2, true)
            FreezeEntityPosition(ent, true)
            local theme = {
                lights = {
                    ambient = {
                        color = {255, 0, 0},
                    },
                    spotlight = {
                        color = {0, 255, 0},
                    },
                    barlight = {
                        color = {0, 0, 255},
                    }
                }
            }
            table.insert(LocalDJStations[id].entityData.lights, {
                entity = ent,
                lightType = light.data.lightType,
                heading = light.heading + rot.z,
                dbId = light.id,
                color = theme.lights[light.data.lightType].color,
                data = light
            })
            SetObjectLightColor(ent, 1, theme.lights[light.data.lightType].color[1], theme.lights[light.data.lightType].color[2], theme.lights[light.data.lightType].color[3])
        end
    end
    -- Keep old VFX system for backwards compatibility (auto-generated lights)
    LocalDJStations[id].vfxEntities = {}
    -- Only create auto VFX if no lights are defined in station
    return station
end

-- Per-station light controls (stationId -> controls)
-- flash: 0 = off, 1 = high (every tick), 2 = low (every 2 ticks)
-- Controls are ONLY set from server, never initialized locally
local stationControls = {}

CreateThread(function()
    local speed = 2
    local maxRot = 90.0
    local maxHz = 45.0
    local rot = 0.0
    local dir = 1
    local hDir = 1
    local visibleLights = {} -- per station, per light type
    local flashGroupStates = {} -- per station, per flash value -> boolean state
    local ticks = 0
    while true do
        ticks = ticks + 1
        local updateLightColor = {}
        if dir == 1 and rot >= maxRot then
            dir = -1
            hDir = -hDir
        elseif dir == -1 and rot < 0.0 then
            dir = 1
        end
        rot = rot + speed * dir
        
        -- Process each station's controls separately
        for stationId, station in pairs(LocalDJStations) do
            -- Only process if we have controls from server
            local controls = stationControls[stationId]
            if not controls or not controls.lights then goto continue_station end
            
            if not visibleLights[stationId] then
                visibleLights[stationId] = {}
                for lightType, lightControls in pairs(controls.lights) do
                    visibleLights[stationId][lightType] = true
                end
            end
            
            if not flashGroupStates[stationId] then
                flashGroupStates[stationId] = {}
            end
            
            -- Group lights by flash value to ensure synchronized flashing
            local flashGroups = {} -- flashValue -> {lightTypes}
            for lightType, lightControls in pairs(controls.lights) do
                if lightControls.enabled ~= false and lightControls.flash > 0 then
                    local flashValue = lightControls.flash
                    if not flashGroups[flashValue] then
                        flashGroups[flashValue] = {}
                    end
                    table.insert(flashGroups[flashValue], lightType)
                    -- Initialize flash group state if not set
                    if flashGroupStates[stationId][flashValue] == nil then
                        flashGroupStates[stationId][flashValue] = true
                    end
                end
            end
            
            -- Check flash updates for this station - group by flash value for synchronization
            for flashValue, lightTypes in pairs(flashGroups) do
                if ticks % flashValue == 0 then
                    -- Toggle the state for this flash group (all lights with same flash value)
                    flashGroupStates[stationId][flashValue] = not flashGroupStates[stationId][flashValue]
                    -- Apply the same state to all lights in this group
                    if not updateLightColor[stationId] then updateLightColor[stationId] = {} end
                    for _, lightType in ipairs(lightTypes) do
                        local lightControls = controls.lights[lightType]
                        if lightControls and lightControls.enabled ~= false then
                            visibleLights[stationId][lightType] = flashGroupStates[stationId][flashValue]
                            updateLightColor[stationId][lightType] = true
                        end
                    end
                else
                    -- Ensure all lights in this group have the same state (sync check)
                    local groupState = flashGroupStates[stationId][flashValue]
                    if groupState ~= nil then
                        for _, lightType in ipairs(lightTypes) do
                            local lightControls = controls.lights[lightType]
                            if lightControls and lightControls.enabled ~= false then
                                if visibleLights[stationId][lightType] ~= groupState then
                                    if not updateLightColor[stationId] then updateLightColor[stationId] = {} end
                                    visibleLights[stationId][lightType] = groupState
                                    updateLightColor[stationId][lightType] = true
                                end
                            end
                        end
                    end
                end
            end
            
            -- Handle non-flashing lights (flash == 0) and disabled lights
            for lightType, lightControls in pairs(controls.lights) do
                if lightControls.enabled ~= false then
                    if lightControls.flash == 0 and not visibleLights[stationId][lightType] then
                        if not updateLightColor[stationId] then updateLightColor[stationId] = {} end
                        visibleLights[stationId][lightType] = true
                        updateLightColor[stationId][lightType] = true
                    end
                elseif visibleLights[stationId][lightType] then
                    if not updateLightColor[stationId] then updateLightColor[stationId] = {} end
                    visibleLights[stationId][lightType] = false
                    updateLightColor[stationId][lightType] = true
                end
            end
            
            -- Apply controls to lights for this station
            if not station.entityData or not station.entityData.lights then goto continue_station end
            for i=1, #station.entityData.lights do
                local light = station.entityData.lights[i]
                local lightControls = controls.lights[light.lightType]
                local tilt = 0.0
                local locHz = 0.0
                local locRot = 0.0
                
                if light.lightType == "spotlight" then
                    tilt = -20.0
                end
                if lightControls.rotateHorizontal then
                    local hz = (rot / maxRot) * maxHz
                    if hDir == 1 then
                        locHz = hz - maxHz
                    else
                        locHz = maxHz - hz
                    end
                end
                if lightControls.rotateVertical then
                    locRot = rot
                end
                if updateLightColor[stationId] and updateLightColor[stationId][light.lightType] then
                    if Config.LaggyButCoolLights then
                        if not visibleLights[stationId][light.lightType] then
                            SetObjectLightColor(light.entity, 1, 0, 0, 0)
                        else
                            SetObjectLightColor(light.entity, 1, light.color[1], light.color[2], light.color[3])
                        end
                    else
                        SetEntityVisible(light.entity, visibleLights[stationId][light.lightType], false)
                    end
                end
                SetEntityRotation(light.entity, locRot + tilt, 0.0, (light.heading) + (locHz), 2, true)
                ::continue::
            end
            ::continue_station::
        end
        Wait(0)
    end
end)

RegisterNetEvent('pickle_dj:registerDJStation', function(id, station)
    if type(id) == 'table' then
        for id, station in pairs(id) do
            DJStations[id] = station
            RegisterDJStation(id)
        end
        return
    end
    DJStations[id] = station
    RegisterDJStation(id)
    
    -- If viewing entities for this station, refresh view
    if viewingEntities and viewingStationId == id then
        -- Viewing will automatically update as entities are re-registered
    end
end)

AddEventHandler('onResourceStart', function(resource)
    if resource == GetCurrentResourceName() then
        TriggerServerEvent('pickle_dj:requestDJStations')
    end
end)

AddEventHandler('onResourceStop', function(resource)
    if resource == GetCurrentResourceName() then
        for id, station in pairs(DJStations) do
            UnregisterDJStation(id)
        end
    end
end)

RegisterNUICallback('setVisible', function(data, cb)
    if not data.visible then
        ExitDJCamera()
    end
    SetNuiFocus(data.visible, data.visible)
    cb(true)
end)

RegisterNUICallback('updateLightControls', function(data, cb)
    local stationId = data.stationId
    local lightType = data.lightType
    local property = data.property
    local value = data.value
    
    if not stationId or not lightType or not property then
        cb(false)
        return
    end
    
    -- Send update to server to network it
    TriggerServerEvent('pickle_dj:updateLightControls', stationId, lightType, property, value)
    
    cb(true)
end)

RegisterNUICallback('updateAllLightControls', function(data, cb)
    local stationId = data.stationId
    local property = data.property
    local value = data.value
    
    if not stationId or not property then
        cb(false)
        return
    end
    
    -- Send batch update to server to network it
    TriggerServerEvent('pickle_dj:updateAllLightControls', stationId, property, value)
    
    cb(true)
end)

-- Receive networked control updates from server
-- Client only stores what server sends, no mapping or conversion
RegisterNetEvent('pickle_dj:lightControlsUpdated', function(stationId, lightType, property, value)
    -- Only update if we have controls from server (initial state must be received first)
    if not stationControls[stationId] or not stationControls[stationId].lights or not stationControls[stationId].lights[lightType] then
        return
    end
    
    -- Store exactly what server sends - no mapping or conversion
    stationControls[stationId].lights[lightType][property] = value
    
    -- Convert flash number to string for UI using shared function
    local uiValue = value
    if property == "flash" then
        uiValue = GetFlashString(value)
    end
    
    -- Send to NUI for UI updates
    SendNUIMessage({
        type = 'music:lightControlsUpdated',
        data = {
            stationId = stationId,
            lightType = lightType,
            property = property,
            value = uiValue
        }
    })
end)

-- Receive initial control state when opening controller
RegisterNetEvent('pickle_dj:lightControlsState', function(stationId, controlsData)
    if controlsData then
        stationControls[stationId] = controlsData
        -- Convert flash numeric values to strings for UI (deep copy with conversion)
        local uiControls = {}
        if controlsData.lights then
            uiControls.lights = {}
            for lightType, lightControl in pairs(controlsData.lights) do
                -- Ensure all boolean values are explicitly set (nil defaults: enabled=true, others=false)
                uiControls.lights[lightType] = {
                    enabled = (lightControl.enabled ~= false), -- nil or true = true, false = false
                    rotateHorizontal = (lightControl.rotateHorizontal == true), -- explicit true check
                    rotateVertical = (lightControl.rotateVertical == true), -- explicit true check
                    flash = GetFlashString(lightControl.flash) or "off"
                }
            end
        end
        -- Send to NUI with converted values
        SendNUIMessage({
            type = 'music:lightControlsState',
            data = {
                stationId = stationId,
                controls = uiControls
            }
        })
    end
end)

-- DJ Station Creation System
local isPlacingDJ = false
local previewEntity = nil
local defaultProp = `sf_prop_sf_dj_desk_01a`

-- Raycast function
local function RaycastFromCamera()
    local camRot = GetGameplayCamRot(2)
    local camCoord = GetGameplayCamCoord()
    local distance = 50.0
    
    local raycast = StartExpensiveSynchronousShapeTestLosProbe(
        camCoord.x, camCoord.y, camCoord.z,
        camCoord.x + (-math.sin(math.rad(camRot.z)) * math.cos(math.rad(camRot.x)) * distance),
        camCoord.y + (math.cos(math.rad(camRot.z)) * math.cos(math.rad(camRot.x)) * distance),
        camCoord.z + (math.sin(math.rad(camRot.x)) * distance),
        -1, -- flags (all entities)
        PlayerPedId(),
        7 -- flags
    )
    
    local retval, hit, endCoords, surfaceNormal, entityHit = GetShapeTestResult(raycast)
    return hit == 1, endCoords, surfaceNormal, entityHit
end

-- Register notification event (defined before ShowNotification function)
RegisterNetEvent('pickle_dj:notify', function(message, type)
    if lib then
        lib.notify({
            title = 'DJ Station',
            description = message,
            type = type or 'info'
        })
    end
end)

-- Draw 3D text helper
function DrawText3D(x, y, z, text)
    local onScreen, _x, _y = World3dToScreen2d(x, y, z)
    local camCoords = GetGameplayCamCoord()
    local distance = #(vector3(x, y, z) - camCoords)
    
    local scale = (1 / distance) * 2
    local fov = (1 / GetGameplayCamFov()) * 100
    scale = scale * fov
    
    if onScreen then
        SetTextScale(0.0 * scale, 0.55 * scale)
        SetTextFont(0)
        SetTextProportional(1)
        SetTextColour(255, 255, 255, 215)
        SetTextDropshadow(0, 0, 0, 0, 255)
        SetTextEdge(2, 0, 0, 0, 150)
        SetTextDropShadow()
        SetTextOutline()
        SetTextEntry("STRING")
        SetTextCentre(1)
        AddTextComponentString(text)
        DrawText(_x, _y)
    end
end

-- Command handler
RegisterCommand('createdj', function()
    if isPlacingDJ then
        ShowNotification("You are already placing a DJ station. Press Q to cancel.", "error")
        return
    end
    
    -- Check if player has admin permission (server will also check)
    lib.callback('pickle_dj:checkAdmin', false, function(isAdmin)
        if not isAdmin then
            ShowNotification("You don't have permission to use this command", "error")
            return
        end
        local options = {}
        for k,v in pairs(Config.DJStations) do
            table.insert(options, {label = k, value = v.prop})
        end
        print(json.encode(options))
        local input = lib.inputDialog('Create DJ Station', {
            {type = 'input', label = 'Station Name', description = 'Enter a name for this DJ station', required = true, min = 1, max = 50},
            {type = 'select', label = 'Prop', description = 'Select a prop for the DJ station', options = options, required = true, default = options[1].value}
        })
        if not input or not input[1] or not input[2] then
            ShowNotification("No DJ station selected", "error")
            return
        end
        local result = StartGizmoEditor({
            model = input[2],
            coords = GetEntityCoords(PlayerPedId()),
            rotation = GetEntityRotation(PlayerPedId()),
            enableCancel = true
        })
        ShowNotification("Look where you want to place the DJ station. Press E to place, Q to cancel, A/D to rotate", "info")
        
        if result and result.position then
            local stationName = input[1]
            local prop = input[2]
            isPlacingDJ = false
            
            -- Send to server
            TriggerServerEvent('pickle_dj:saveStation', {
                name = stationName,
                coords = result.position,
                heading = result.rotation.z,
                prop = prop,
                speakers = {}, -- Empty initially, can be added later
                lights = {} -- Empty initially, lights are auto-generated
            })
        else
            isPlacingDJ = false
            ShowNotification("DJ station creation cancelled", "error")
        end
    end)
end, false)

-- Entity Management System
local isPlacingEntity = false
local viewingEntities = false
local viewingStationId = nil

-- Entity type definitions
local EntityTypes = {
    speaker = {
        label = "Speaker",
        icon = "volume-high",
        defaultModel = `h4_prop_battle_club_speaker_med`,
        configKey = "speaker_1"
    },
    light = {
        label = "Light",
        icon = "lightbulb",
        defaultModel = `stg_blinder`,
    }
}

-- Show notification helper
function ShowNotification(message, type)
    if lib then
        lib.notify({
            title = 'DJ Station',
            description = message,
            type = type or 'info'
        })
    end
end

-- Open entity management menu
function OpenEntityManagementMenu(stationId)
    local station = DJStations[stationId]
    if not station then return end
    
    local localStation = LocalDJStations[stationId]
    if not localStation then return end
    
    -- Check admin permission
    lib.callback('pickle_dj:checkAdmin', false, function(isAdmin)
        if not isAdmin then
            ShowNotification("You don't have permission to manage DJ entities", "error")
            return
        end
        
        local options = {
            {
                title = "Place Entity",
                description = "Place a new speaker, light, or other object",
                icon = "plus",
                onSelect = function()
                    OpenEntityTypeMenu(stationId)
                end
            },
            {
                title = "View Entities",
                description = "View all entities for this station",
                icon = "eye",
                onSelect = function()
                    ToggleEntityViewing(stationId)
                end
            },
            {
                title = "Remove Entity",
                description = "Remove an entity from this station",
                icon = "trash",
                onSelect = function()
                    OpenEntityRemoveMenu(stationId)
                end
            }
        }
        
        lib.registerContext({
            id = 'dj_entity_manage_' .. stationId,
            title = station.name .. " - Entity Management",
            options = options
        })
        lib.showContext('dj_entity_manage_' .. stationId)
    end)
end

-- Open entity type selection menu
function OpenEntityTypeMenu(stationId)
    local options = {}
    
    for entityType, entityInfo in pairs(EntityTypes) do
        table.insert(options, {
            title = entityInfo.label,
            description = "Place a " .. entityInfo.label:lower(),
            icon = entityInfo.icon,
            onSelect = function()
                -- Show variant selection for speakers and lights
                if entityType == "speaker" or entityType == "light" then
                    OpenEntityVariantMenu(stationId, entityType)
                else
                    StartEntityPlacement(stationId, entityType, nil)
                end
            end
        })
    end
    
    lib.registerContext({
        id = 'dj_entity_type_' .. stationId,
        title = "Select Entity Type",
        menu = 'dj_entity_manage_' .. stationId,
        options = options
    })
    lib.showContext('dj_entity_type_' .. stationId)
end

-- Open variant selection menu for speakers or lights
function OpenEntityVariantMenu(stationId, entityType)
    local options = {}
    local configTable = nil
    local title = ""
    
    if entityType == "speaker" then
        configTable = Config.SpeakerProps
        title = "Select Speaker Type"
    elseif entityType == "light" then
        configTable = Config.LightTypes
        title = "Select Light Type"
    end
    
    if not configTable then
        ShowNotification("No variants available for this entity type", "error")
        return
    end
    
    -- Build options from config
    for variantKey, variantData in pairs(configTable) do
        local label = variantData.label or variantKey
        local description = "Place a " .. label:lower()
        
        table.insert(options, {
            title = label,
            description = description,
            icon = entityType == "speaker" and "volume-high" or "lightbulb",
            onSelect = function()
                StartEntityPlacement(stationId, entityType, variantKey)
            end
        })
    end
    
    if #options == 0 then
        ShowNotification("No variants configured for this entity type", "error")
        return
    end
    
    lib.registerContext({
        id = 'dj_entity_variant_' .. stationId .. '_' .. entityType,
        title = title,
        menu = 'dj_entity_type_' .. stationId,
        options = options
    })
    lib.showContext('dj_entity_variant_' .. stationId .. '_' .. entityType)
end

-- Start entity placement
function StartEntityPlacement(stationId, entityType, variantKey)
    if isPlacingEntity then
        ShowNotification("You are already placing an entity", "error")
        return
    end
    
    local entityInfo = EntityTypes[entityType]
    if not entityInfo then return end
    
    local station = DJStations[stationId]
    if not station then return end
    
    -- Get model and variant data based on entity type
    local model = entityInfo.defaultModel
    local variantData = nil
    local variantLabel = entityInfo.label
    
    if entityType == "speaker" then
        if variantKey and Config.SpeakerProps and Config.SpeakerProps[variantKey] then
            variantData = Config.SpeakerProps[variantKey]
            model = variantData.model
            variantLabel = variantData.label or variantKey
        elseif Config.SpeakerProps then
            -- If no variant selected but config exists, use first one
            for key, data in pairs(Config.SpeakerProps) do
                variantData = data
                model = data.model
                variantKey = key
                variantLabel = data.label or key
                break
            end
        end
    elseif entityType == "light" then
        if variantKey and Config.LightTypes and Config.LightTypes[variantKey] then
            variantData = Config.LightTypes[variantKey]
            model = variantData.model
            variantLabel = variantData.label or variantKey
        elseif Config.LightTypes then
            -- If no variant selected but config exists, use first one
            for key, data in pairs(Config.LightTypes) do
                variantData = data
                model = data.model
                variantKey = key
                variantLabel = data.label or key
                break
            end
        end
    end
    
    -- Start gizmo editor
    local result = StartGizmoEditor({
        model = model,
        coords = GetEntityCoords(PlayerPedId()),
        rotation = vector3(0.0, 0.0, GetEntityHeading(PlayerPedId())),
        lightColor = {255, 255, 255},
        enableCancel = true,
        deleteEntity = true
    })
    
    if result and result.position then
        -- Prepare entity data
        local entityData = {
            coords = result.position,
            heading = result.rotation.z,
            model = model
        }
        
        -- Add entity-specific data
        if entityType == "speaker" and variantData then
            entityData.data = {
                speakerType = variantKey,
                rotation = variantData.rotation or vector3(0.0, 0.0, 0.0),
                soundOffset = variantData.soundOffset or vector3(0.0, 0.0, 0.0),
                soundRadius = variantData.soundRadius
            }
        elseif entityType == "light" and variantData then
            entityData.data = {
                lightType = variantKey,
                strobeModel = variantData.strobeModel
            }
        end
        
        -- Send to server
        TriggerServerEvent('pickle_dj:addEntity', stationId, entityType, entityData)
        ShowNotification(variantLabel .. " placed successfully!", "success")
    else
        ShowNotification("Entity placement cancelled", "error")
    end
    OpenEntityTypeMenu(stationId)
end

-- Toggle entity viewing
function ToggleEntityViewing(stationId)
    if viewingEntities and viewingStationId == stationId then
        viewingEntities = false
        viewingStationId = nil
        ShowNotification("Entity viewing disabled", "info")
    else
        viewingEntities = true
        viewingStationId = stationId
        ShowNotification("Entity viewing enabled - Look at entities to see their info", "info")
    end
end

-- Open entity removal menu
function OpenEntityRemoveMenu(stationId)
    local localStation = LocalDJStations[stationId]
    if not localStation or not localStation.entityData then
        ShowNotification("No entities found", "error")
        return
    end
    
    local options = {}
    
    -- Add speakers
    for i, speakerData in ipairs(localStation.entityData.speakers or {}) do
        local variantLabel = "Speaker"
        if speakerData.data and speakerData.data.speakerType and Config.SpeakerProps and Config.SpeakerProps[speakerData.data.speakerType] then
            variantLabel = Config.SpeakerProps[speakerData.data.speakerType].label or speakerData.data.speakerType
        end
        table.insert(options, {
            title = variantLabel .. " #" .. (speakerData.dbId or i),
            description = "Remove this speaker",
            icon = "volume-high",
            onSelect = function()
                if speakerData.dbId then
                    TriggerServerEvent('pickle_dj:removeEntity', speakerData.dbId)
                else
                    ShowNotification("Entity ID not found", "error")
                end
                SetTimeout(100, function()
                    OpenEntityRemoveMenu(stationId)
                end)
            end
        })
    end
    
    -- Add lights
    for i, lightData in ipairs(localStation.entityData.lights or {}) do
        local variantLabel = "Light"
        if Config.LightTypes and Config.LightTypes[lightData.lightType] then
            variantLabel = Config.LightTypes[lightData.lightType].label or lightData.lightType
        end
        table.insert(options, {
            title = variantLabel .. " #" .. (lightData.dbId or i),
            description = "Remove this light",
            icon = "lightbulb",
            onSelect = function()
                if lightData.dbId then
                    TriggerServerEvent('pickle_dj:removeEntity', lightData.dbId)
                else
                    ShowNotification("Entity ID not found", "error")
                end
                SetTimeout(500, function()
                    OpenEntityRemoveMenu(stationId)
                end)
            end
        })
    end
    
    if #options == 0 then
        ShowNotification("No entities to remove", "info")
        return
    end
    
    lib.registerContext({
        id = 'dj_entity_remove_' .. stationId,
        title = "Remove Entity",
        menu = 'dj_entity_manage_' .. stationId,
        options = options
    })
    lib.showContext('dj_entity_remove_' .. stationId)
end

-- Update entity data when station is updated
RegisterNetEvent('pickle_dj:entityUpdated', function(stationId)
    -- Reload the station
    if DJStations[stationId] then
        RegisterDJStation(stationId)
    end
end)