YouTube = {}

local MEMORY_MAX = 400
local RATINGS_MAX = 2000
local CACHE_KEY_MAX = 190
local CACHE_PRUNE_DAYS = 30
local REQUEST_TIMEOUT = 8000
local QUOTA_BACKOFF = 900

local memory = {}
local memoryCount = 0
local ratings = {}
local ratingCount = 0
local pending = {}
local quotaUntil = 0
local usedDay, usedUnits = nil, 0
local refusals = {}

local function isoDuration(text)
    if type(text) ~= 'string' then return 0 end
    local h = tonumber(text:match('(%d+)H')) or 0
    local m = tonumber(text:match('(%d+)M')) or 0
    local s = tonumber(text:match('(%d+)S')) or 0
    return h * 3600 + m * 60 + s
end

local function unescape(text)
    if type(text) ~= 'string' then return '' end
    return text:gsub('&amp;', '&'):gsub('&quot;', '"'):gsub('&#39;', "'"):gsub('&lt;', '<'):gsub('&gt;', '>')
end

local function request(url)
    local res = Core.httpGet(url, REQUEST_TIMEOUT)
    if res.status == 403 or res.status == 429 then quotaUntil = os.time() + QUOTA_BACKOFF end
    if res.status ~= 200 then
        local fine, data = pcall(json.decode, res.body or '')
        local reason = fine and type(data) == 'table' and type(data.error) == 'table' and data.error.message
        reason = type(reason) == 'string' and reason:gsub('<[^>]+>', '') or ('HTTP ' .. tostring(res.status))
        if not refusals[reason] then
            refusals[reason] = true
            print(('^1[bupa-music-source] YouTube refused the request: %s^0'):format(reason))
        end
    end
    return res
end

local SEPARATORS = { ' - ', ' – ', ' — ' }

local function splitTitle(title, channel)
    local at, sep
    for _, candidate in ipairs(SEPARATORS) do
        local found = title:find(candidate, 1, true)
        if found and (not at or found < at) then at, sep = found, candidate end
    end
    if at then
        local track = title:sub(at + #sep):gsub('%s*[%(%[].-[%)%]]%s*', ' ')
        return Util.trim(title:sub(1, at - 1)), Util.trim(track)
    end
    local cleanChannel = (channel or ''):gsub('%s+%-%s+Topic$', ''):gsub('VEVO$', '')
    return Util.trim(cleanChannel), Util.trim((title:gsub('%s*[%(%[].-[%)%]]%s*', ' ')))
end

local function quotaDay()
    return os.date('!%Y-%m-%d', os.time() - 8 * 3600)
end

local function usedToday()
    if not Db.ready then return 0 end
    local day = quotaDay()
    if usedDay ~= day then
        usedDay = day
        usedUnits = tonumber(Db.scalar('SELECT units FROM bupa_music_quota WHERE day = ?', { day })) or 0
    end
    return usedUnits
end

local function spend(units)
    if not Db.ready then return end
    usedToday()
    usedUnits = usedUnits + units
    Db.update('INSERT INTO bupa_music_quota (day, units) VALUES (?, ?) ON DUPLICATE KEY UPDATE units = units + VALUES(units)',
        { usedDay, units })
end

function YouTube.quota()
    local limit = tonumber(Config.YouTube.dailyQuota) or 10000
    local used = usedToday()
    return {
        used = used,
        limit = limit,
        percent = limit > 0 and math.min(100, math.floor(used / limit * 100 + 0.5)) or 0,
        resets = '08:00 UTC',
        blocked = YouTube.quotaBlocked(),
    }
end

function YouTube.ready()
    return type(Config.YouTube.apiKey) == 'string' and #Config.YouTube.apiKey > 10
end

function YouTube.quotaBlocked()
    return os.time() < quotaUntil or usedToday() >= (tonumber(Config.YouTube.dailyQuota) or 10000)
end

local function validId(videoId)
    return type(videoId) == 'string' and #videoId == 11 and videoId:match('^[%w_%-]+$') ~= nil
end

local function normalise(query)
    local text = tostring(query or ''):lower():gsub('%p', ' '):gsub('%s+', ' ')
    return Util.trim(text):sub(1, 100)
end

local function cacheKey(query, page)
    return (('%s|%s'):format(normalise(query), page or '')):sub(1, CACHE_KEY_MAX)
end

local function pageToken(page)
    if type(page) ~= 'string' then return nil end
    page = page:sub(1, 64)
    if page == '' or not page:match('^[%w%-_=%.]+$') then return nil end
    return page
end

local function remember(key, at, data)
    if memoryCount >= MEMORY_MAX then
        memory = {}
        memoryCount = 0
    end
    if memory[key] == nil then memoryCount = memoryCount + 1 end
    memory[key] = { at = at, data = data }
end

local function rate(id, restricted)
    if ratingCount >= RATINGS_MAX then
        ratings = {}
        ratingCount = 0
    end
    if ratings[id] == nil then ratingCount = ratingCount + 1 end
    ratings[id] = restricted
end

local function fromCache(key, stale)
    if not Db.ready then return nil end
    local fresh = os.time() - (tonumber(Config.Search.cacheMinutes) or 360) * 60
    local hit = memory[key]
    if hit and (stale or hit.at > fresh) then return hit.data end

    local row = Db.single('SELECT payload, UNIX_TIMESTAMP(cached_at) AS at FROM bupa_music_search_cache WHERE query_key = ?', { key })
    if row and (stale or (tonumber(row.at) or 0) > fresh) then
        local fine, data = pcall(json.decode, row.payload)
        if fine and type(data) == 'table' then
            remember(key, tonumber(row.at) or 0, data)
            return data
        end
    end
    return nil
end

local function toCache(key, data)
    if not Db.ready then return end
    remember(key, os.time(), data)
    Db.update('INSERT INTO bupa_music_search_cache (query_key, payload) VALUES (?, ?) ON DUPLICATE KEY UPDATE payload = VALUES(payload), cached_at = CURRENT_TIMESTAMP', { key, json.encode(data) })
end

local genresKnown = {}
local genresCount = 0

local function genreOf(topics)
    if type(topics) ~= 'table' then return nil end
    for _, url in ipairs(topics) do
        local slug = tostring(url):match('/wiki/([^/]+)$')
        if slug then
            local name = slug:gsub('_', ' ')
            if name:lower():find('music', 1, true) and name ~= 'Music' then
                name = name:gsub('^Music of ', ''):gsub('%s*[Mm]usic$', '')
                name = Util.trim(name)
                if name ~= '' then return name:sub(1, 48) end
            end
        end
    end
    return nil
end

local function rememberGenres(rows)
    if not Db.ready or #rows == 0 then return end
    local marks, args = {}, {}
    for _, row in ipairs(rows) do
        if genresKnown[row[1]] == nil then
            if genresCount >= RATINGS_MAX then
                genresKnown = {}
                genresCount = 0
            end
            genresKnown[row[1]] = true
            genresCount = genresCount + 1
            marks[#marks + 1] = '(?, ?)'
            args[#args + 1] = row[1]
            args[#args + 1] = row[2]
        end
    end
    if #marks == 0 then return end
    Db.update('INSERT INTO bupa_music_genres (video_id, genre) VALUES ' .. table.concat(marks, ',') ..
        ' ON DUPLICATE KEY UPDATE genre = VALUES(genre), fetched_at = CURRENT_TIMESTAMP', args)
end

local function details(ids)
    local safe = {}
    for _, id in ipairs(ids) do
        if #safe < 50 and validId(id) then safe[#safe + 1] = id end
    end
    if #safe == 0 then return {} end
    local url = ('https://www.googleapis.com/youtube/v3/videos?part=contentDetails,status,topicDetails&id=%s&key=%s'):format(table.concat(safe, ','), Util.urlEncode(Config.YouTube.apiKey))
    spend(1)
    local res = request(url)
    if res.status ~= 200 then return {} end
    local fine, data = pcall(json.decode, res.body)
    if not fine or type(data) ~= 'table' then return {} end

    local out = {}
    local found = {}
    for _, item in ipairs(data.items or {}) do
        local cd = item.contentDetails or {}
        local st = item.status or {}
        if type(item.id) == 'string' then
            local genre = genreOf(item.topicDetails and item.topicDetails.topicCategories)
            out[item.id] = {
                duration = isoDuration(cd.duration),
                embeddable = st.embeddable ~= false,
                restricted = (cd.contentRating or {}).ytRating == 'ytAgeRestricted',
                genre = genre,
            }
            if genre then found[#found + 1] = { item.id, genre } end
        end
    end
    rememberGenres(found)
    return out
end

function YouTube.restricted(videoId)
    if not validId(videoId) then return nil end
    if ratings[videoId] ~= nil then return ratings[videoId] end
    if not YouTube.ready() or YouTube.quotaBlocked() then return nil end
    local extra = details({ videoId })
    local d = extra[videoId]
    if not d then return nil end
    rate(videoId, d.restricted == true)
    return ratings[videoId]
end

local function fetch(query, page, key)
    local params = {
        'part=snippet',
        'type=video',
        'videoEmbeddable=true',
        'videoSyndicated=true',
        'maxResults=' .. tostring(math.floor(Util.clamp(tonumber(Config.Search.pageSize) or 12, 1, 50))),
        'q=' .. Util.urlEncode(query),
        'key=' .. Util.urlEncode(Config.YouTube.apiKey),
    }
    local region, language = Config.YouTube.region, Config.YouTube.language
    if type(region) == 'string' and region ~= '' then params[#params + 1] = 'regionCode=' .. Util.urlEncode(region:upper()) end
    if type(language) == 'string' and language ~= '' then params[#params + 1] = 'relevanceLanguage=' .. Util.urlEncode(language:lower()) end
    if Config.Search.musicOnly then params[#params + 1] = 'videoCategoryId=10' end
    if page then params[#params + 1] = 'pageToken=' .. Util.urlEncode(page) end

    spend(100)
    local res = request('https://www.googleapis.com/youtube/v3/search?' .. table.concat(params, '&'))
    if res.status ~= 200 then
        local old = fromCache(key, true)
        if old then return { ok = true, data = old } end
        return { ok = false, error = (res.status == 403 or res.status == 429) and 'search_quota' or 'search_failed' }
    end

    local fine, data = pcall(json.decode, res.body)
    if not fine or type(data) ~= 'table' then
        local old = fromCache(key, true)
        if old then return { ok = true, data = old } end
        return { ok = false, error = 'search_failed' }
    end

    local ids = {}
    local items = {}
    for _, item in ipairs(data.items or {}) do
        local id = item.id and item.id.videoId
        local sn = item.snippet
        if validId(id) and sn then
            ids[#ids + 1] = id
            local artist, track = splitTitle(unescape(sn.title or ''), unescape(sn.channelTitle or ''))
            local thumbs = sn.thumbnails or {}
            local thumb = (thumbs.high or thumbs.medium or thumbs.default or {}).url
            items[#items + 1] = {
                videoId = id,
                title = track ~= '' and track or unescape(sn.title or ''),
                artist = artist,
                channel = unescape(sn.channelTitle or ''),
                thumb = thumb,
                duration = 0,
            }
        end
    end

    local extra = details(ids)
    for id, d in pairs(extra) do rate(id, d.restricted == true) end
    local filtered = {}
    for _, item in ipairs(items) do
        local d = extra[item.videoId]
        if not d or d.embeddable then
            item.duration = d and d.duration or 0
            item.genre = d and d.genre or nil
            filtered[#filtered + 1] = item
        end
    end

    local result = { items = filtered, next = data.nextPageToken, total = data.pageInfo and data.pageInfo.totalResults or #filtered }
    toCache(key, result)
    return { ok = true, data = result }
end

function YouTube.search(query, page)
    query = Util.trim(query):sub(1, 100)
    if query == '' then return { ok = false, error = 'search_empty' } end
    if not YouTube.ready() then return { ok = false, error = 'search_no_key' } end

    page = pageToken(page)
    local key = cacheKey(query, page)
    local cached = fromCache(key)
    if cached then return { ok = true, data = cached } end

    if YouTube.quotaBlocked() then
        local old = fromCache(key, true)
        if old then return { ok = true, data = old } end
        return { ok = false, error = 'search_quota' }
    end

    local waiting = pending[key]
    if waiting then return Citizen.Await(waiting) or { ok = false, error = 'search_failed' } end

    local p = promise.new()
    pending[key] = p
    local fine, result = pcall(fetch, query, page, key)
    pending[key] = nil
    if not fine then
        print(('^1[bupa-music-source] search failed:^7 %s^0'):format(tostring(result)))
        result = { ok = false, error = 'search_failed' }
    end
    p:resolve(result)
    return result
end

local function fetchVideo(videoId, key)
    local url = ('https://www.googleapis.com/youtube/v3/videos?part=snippet,contentDetails,status,topicDetails&id=%s&key=%s'):format(videoId, Util.urlEncode(Config.YouTube.apiKey))
    spend(1)
    local res = request(url)
    if res.status ~= 200 then return nil end
    local fine, data = pcall(json.decode, res.body)
    if not fine or type(data) ~= 'table' or not data.items or not data.items[1] then return nil end

    local item = data.items[1]
    local sn = item.snippet or {}
    local artist, track = splitTitle(unescape(sn.title or ''), unescape(sn.channelTitle or ''))
    local thumbs = sn.thumbnails or {}
    local result = {
        videoId = videoId,
        title = track ~= '' and track or unescape(sn.title or ''),
        artist = artist,
        channel = unescape(sn.channelTitle or ''),
        thumb = (thumbs.high or thumbs.medium or thumbs.default or {}).url,
        duration = isoDuration(item.contentDetails and item.contentDetails.duration),
        embeddable = not (item.status and item.status.embeddable == false),
    }
    local genre = genreOf(item.topicDetails and item.topicDetails.topicCategories)
    if genre then rememberGenres({ { videoId, genre } }) end
    toCache(key, result)
    return result
end

function YouTube.video(videoId)
    if not validId(videoId) then return nil end
    local key = ('id:%s'):format(videoId)
    local cached = fromCache(key)
    if cached then return cached end
    if not YouTube.ready() or YouTube.quotaBlocked() then return nil end

    local waiting = pending[key]
    if waiting then return Citizen.Await(waiting) end

    local p = promise.new()
    pending[key] = p
    local fine, result = pcall(fetchVideo, videoId, key)
    pending[key] = nil
    if not fine then result = nil end
    p:resolve(result)
    return result
end

CreateThread(function()
    while not Db.ready do Wait(1000) end
    while true do
        pcall(Db.update, 'DELETE FROM bupa_music_search_cache WHERE cached_at < DATE_SUB(NOW(), INTERVAL ? DAY)', { CACHE_PRUNE_DAYS })
        Wait(3600000)
    end
end)
