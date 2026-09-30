Config = Config or {}

--[[ ─────────────────────────────────────────────────────────────────────────
     bupa-music-source
     Everything this add-on needs lives here. The values never reach a player.
     ───────────────────────────────────────────────────────────────────────── ]]

Config.YouTube = {
    dailyQuota = 10000,
    -- YouTube Data API v3 key. Get one at console.cloud.google.com:
    --   1. New project (any name)
    --   2. APIs & Services -> Library -> "YouTube Data API v3" -> Enable
    --   3. APIs & Services -> Credentials -> Create credentials -> API key
    --   4. Restrict the key to the YouTube Data API v3 so a leak is harmless
    -- The free quota is 10,000 units a day. A search costs 100, fetching
    -- details for a page of results costs 1, so the cache below matters: with
    -- it, a busy server stays well under the limit.
    apiKey = '',

    -- Hints that change which videos rank first, not what you can find.
    -- region is a two-letter COUNTRY code (US, GB, TR, DE), not a language;
    -- 'EN' is not a country and makes every search fail. Empty sends none.
    -- language is a two-letter language code (en, tr, de).
    region   = 'US',
    language = 'en',
}

Config.Search = {
    -- Results asked for per page. While this add-on is running the tablet
    -- follows this number, so it is the only place to change it. 12 fills the
    -- screen.
    pageSize   = 12,
    -- Results that come from YouTube are reused for this long, in minutes.
    cacheMinutes = 4320,
    -- Only music videos. Turning this off returns everything YouTube has.
    musicOnly  = true,
}
