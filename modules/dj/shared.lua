function GetFlashValue(value)
    if value == "off" then
        return 0
    elseif value == "low" then
        return 10
    elseif value == "high" then
        return 2
    end
end

function GetFlashString(value)
    if value == 0 then
        return "off"
    elseif value == 10 then
        return "low"
    elseif value == 2 then
        return "high"
    end
    return "off" -- default
end