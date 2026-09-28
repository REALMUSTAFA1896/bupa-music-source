Util = {}
Db = {}
Core = {}

function Util.clamp(value, low, high)
    if value < low then return low end
    if value > high then return high end
    return value
end

function Util.trim(text)
    if type(text) ~= 'string' then return '' end
    return (text:gsub('^%s+', ''):gsub('%s+$', ''))
end

function Util.urlEncode(text)
    return (tostring(text):gsub('[^%w%-_%.~]', function(c)
        return ('%%%02X'):format(c:byte())
    end))
end

function Core.httpGet(url, timeout)
    local p = promise.new()
    local done = false
    local function finish(status, body)
        if done then return end
        done = true
        p:resolve({ status = status, body = body })
    end
    PerformHttpRequest(url, finish, 'GET', '', { ['Accept'] = 'application/json' })
    SetTimeout(timeout, function() finish(0, '') end)
    return Citizen.Await(p)
end

Db.ready = false

function Db.query(query, params) return MySQL.query.await(query, params) end
function Db.single(query, params) return MySQL.single.await(query, params) end
function Db.scalar(query, params) return MySQL.scalar.await(query, params) end
function Db.insert(query, params) return MySQL.insert.await(query, params) end
function Db.update(query, params) return MySQL.update.await(query, params) end

local SCHEMA = {
    [[CREATE TABLE IF NOT EXISTS bupa_music_quota (
        day DATE NOT NULL PRIMARY KEY,
        units INT NOT NULL DEFAULT 0
    )]],

    [[CREATE TABLE IF NOT EXISTS bupa_music_search_cache (
        query_key VARCHAR(190) NOT NULL PRIMARY KEY,
        payload MEDIUMTEXT NOT NULL,
        cached_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
        INDEX cached_idx (cached_at)
    )]],

    [[CREATE TABLE IF NOT EXISTS bupa_music_genres (
        video_id VARCHAR(16) NOT NULL PRIMARY KEY,
        genre VARCHAR(48) NOT NULL,
        fetched_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
        INDEX genre_idx (genre)
    )]],
}

CreateThread(function()
    local waited = 0
    while GetResourceState('oxmysql') ~= 'started' do
        if waited >= 30000 then
            print('^1[bupa-music-source] oxmysql never started, search cache and quota tracking are off^0')
            return
        end
        waited = waited + 200
        Wait(200)
    end

    for tries = 1, 30 do
        if pcall(Db.scalar, 'SELECT 1') then
            for _, statement in ipairs(SCHEMA) do
                local fine, err = pcall(Db.query, statement)
                if not fine then
                    print(('^1[bupa-music-source] table setup failed: %s^0'):format(tostring(err)))
                    return
                end
            end
            Db.ready = true
            return
        end
        Wait(1000)
    end

    print('^1[bupa-music-source] database never answered, search cache and quota tracking are off^0')
end)
