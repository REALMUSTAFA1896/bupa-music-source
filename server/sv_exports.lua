local ASK = {
    search = function(query, page) return YouTube.search(query, page) end,
    video = function(videoId) return YouTube.video(videoId) end,
    restricted = function(videoId) return YouTube.restricted(videoId) end,
}

AddEventHandler('bupa-music-source:ask', function(kind, id, ...)
    local fn = ASK[kind]
    if not fn then
        TriggerEvent('bupa-music-source:result', id, nil)
        return
    end

    local args = table.pack(...)
    CreateThread(function()
        local fine, result = pcall(fn, table.unpack(args, 1, args.n))
        if fine then
            TriggerEvent('bupa-music-source:result', id, result)
        else
            print(('^1[bupa-music-source] %s failed:^7 %s^0'):format(kind, tostring(result)))
            TriggerEvent('bupa-music-source:result', id, nil)
        end
    end)
end)

exports('ready', function()
    return YouTube.ready()
end)

exports('quota', function()
    return YouTube.quota()
end)

exports('thumbTemplate', function()
    return 'https://i.ytimg.com/vi/%s/%s.jpg'
end)

exports('watchTemplate', function()
    return 'https://youtu.be/%s'
end)

exports('imageHosts', function()
    return { 'i.ytimg.com' }
end)

exports('pageSize', function()
    return Config.Search.pageSize
end)

CreateThread(function()
    Wait(2000)
    if not YouTube.ready() then
        print('^3[bupa-music-source] no API key in config.lua — search is off until you add one^0')
    end
end)
