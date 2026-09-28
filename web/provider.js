(function () {
  const API_RETRY = 15000
  const RAMP = 700
  const FADE_STEP = 100

  const players = new Map()
  const apiWaiters = []
  const fading = []

  let apiReady = false
  let apiLoading = false
  let apiFailedUntil = 0
  let pending = null
  let drift = 1.5
  let crossfade = 0
  let normalise = true
  let fadeTimer = 0
  let shownFrame = null
  let shownCss = ''
  let post = () => {}

  function pool() {
    let host = document.getElementById('yt-pool')
    if (!host) {
      host = document.createElement('div')
      host.id = 'yt-pool'
      host.style.cssText = 'position:fixed;left:-10000px;top:-10000px;width:1px;height:1px;overflow:hidden;'
      document.body.appendChild(host)
    }
    return host
  }

  function loadApi() {
    if (apiReady || apiLoading || performance.now() < apiFailedUntil) return
    if (window.YT && window.YT.Player) {
      apiReady = true
      flush()
      return
    }
    apiLoading = true
    window.onYouTubeIframeAPIReady = () => {
      apiLoading = false
      apiReady = true
      flush()
    }
    const s = document.createElement('script')
    s.src = 'https://www.youtube.com/iframe_api'
    s.async = true
    s.onerror = () => {
      apiLoading = false
      apiFailedUntil = performance.now() + API_RETRY
      pending = null
      if (s.parentNode) s.parentNode.removeChild(s)
    }
    document.head.appendChild(s)
  }

  function flush() {
    while (apiWaiters.length) {
      try { apiWaiters.shift()() } catch {}
    }
    const list = pending
    pending = null
    if (list) sync(list)
  }

  function hideCaptions(player) {
    try {
      player.unloadModule('captions')
      player.unloadModule('cc')
    } catch {}
  }

  function makePlayer(id, videoId, position, volume, paused) {
    const host = document.createElement('div')
    pool().appendChild(host)
    const entry = { id, videoId, host, player: null, frame: null, ready: false, want: { position, volume, paused }, lastSeek: 0, errored: false, startedAt: performance.now() }
    players.set(id, entry)
    entry.player = new window.YT.Player(host, {
      width: 200,
      height: 120,
      videoId,
      host: 'https://www.youtube.com',
      playerVars: { autoplay: 0, controls: 0, disablekb: 1, fs: 0, iv_load_policy: 3, rel: 0, playsinline: 1, modestbranding: 1, cc_load_policy: 0, origin: window.location.origin },
      events: {
        onReady: () => {
          entry.ready = true
          entry.frame = entry.player.getIframe()
          hideCaptions(entry.player)
          apply(entry, true)
        },
        onError: () => {
          entry.errored = true
          post('playerError', { id, videoId: entry.videoId })
        },
      },
    })
    return entry
  }

  function apply(entry, force) {
    const p = entry.player
    if (!entry.ready || !p) return
    const { position, volume, paused } = entry.want
    try {
      let target = Math.max(0, Math.min(1, volume))
      if (normalise && entry.startedAt) {
        const since = performance.now() - entry.startedAt
        if (since < RAMP) target = target * (0.35 + 0.65 * (since / RAMP))
      }
      const vol = Math.round(target * 100)
      if (force || entry.lastVolume !== vol) {
        entry.lastVolume = vol
        p.setVolume(vol)
        if (vol > 0 && p.isMuted && p.isMuted()) p.unMute()
      }
      const state = p.getPlayerState ? p.getPlayerState() : -1
      const now = performance.now()
      if (paused) {
        if (entry.videoChanged) {
          entry.videoChanged = false
          p.cueVideoById({ videoId: entry.videoId, startSeconds: Math.max(0, position) })
          entry.lastSeek = now
          return
        }
        if (state === 1 || state === 3) p.pauseVideo()
        if (force || Math.abs((p.getCurrentTime() || 0) - position) > drift) {
          p.seekTo(position, true)
          p.pauseVideo()
        }
        return
      }
      if (force || entry.videoChanged) {
        entry.videoChanged = false
        p.loadVideoById({ videoId: entry.videoId, startSeconds: Math.max(0, position) })
        hideCaptions(p)
        entry.lastSeek = now
        entry.startedAt = now
        return
      }
      if (state !== 1 && state !== 3 && now - entry.lastSeek > 1500) {
        if (state === 0 && position < ((p.getDuration && p.getDuration()) || 1e9) - 2) {
          p.seekTo(position, true)
          entry.lastSeek = now
        }
        p.playVideo()
      }
      if (now - entry.lastSeek > 2000) {
        const cur = p.getCurrentTime ? p.getCurrentTime() : 0
        if (Math.abs(cur - position) > drift) {
          p.seekTo(position, true)
          entry.lastSeek = now
        }
      }
    } catch {}
  }

  function remove(entry) {
    if (players.get(entry.id) === entry) players.delete(entry.id)
    if (shownFrame && shownFrame === entry.frame) shownFrame = null
    try { entry.player && entry.player.destroy() } catch {}
    if (entry.host && entry.host.parentNode) entry.host.parentNode.removeChild(entry.host)
  }

  function detach(entry) {
    players.delete(entry.id)
    fading.push({ entry, started: performance.now(), from: entry.lastVolume || 0 })
    if (!fadeTimer) fadeTimer = setInterval(stepFades, FADE_STEP)
  }

  function stepFades() {
    if (!fading.length) {
      clearInterval(fadeTimer)
      fadeTimer = 0
      return
    }
    const now = performance.now()
    for (let i = fading.length - 1; i >= 0; i -= 1) {
      const f = fading[i]
      const passed = (now - f.started) / 1000
      const left = crossfade > 0 ? 1 - passed / crossfade : 0
      if (left <= 0) {
        fading.splice(i, 1)
        remove(f.entry)
        continue
      }
      try { f.entry.player.setVolume(Math.round(f.from * left)) } catch {}
    }
  }

  function sync(list) {
    const keep = new Set()
    for (const item of list) {
      keep.add(item.id)
      let entry = players.get(item.id)
      if (entry && entry.videoId !== item.videoId) {
        if (crossfade > 0 && entry.ready && !item.paused && entry.lastVolume > 0) {
          detach(entry)
          entry = makePlayer(item.id, item.videoId, item.position, item.volume, item.paused)
          continue
        }
        entry.videoId = item.videoId
        entry.videoChanged = true
        entry.errored = false
      }
      if (!entry) {
        entry = makePlayer(item.id, item.videoId, item.position, item.volume, item.paused)
        continue
      }
      entry.want = { position: item.position, volume: item.volume, paused: item.paused }
      apply(entry, false)
    }
    for (const [id, entry] of players) {
      if (!keep.has(id)) remove(entry)
    }
  }

  window.BupaMusicProvider = {
    init(opts) {
      if (opts && typeof opts.post === 'function') post = opts.post
    },

    configure(opts) {
      if (!opts) return
      if (typeof opts.drift === 'number') drift = opts.drift
      if (typeof opts.crossfade === 'number') crossfade = Math.max(0, Math.min(12, opts.crossfade))
      if (typeof opts.normalise === 'boolean') normalise = opts.normalise
    },

    update(list) {
      const next = list || []
      if (!apiReady) {
        pending = next
        loadApi()
        return
      }
      sync(next)
    },

    showVideo(id, rect) {
      const entry = rect && id !== null && id !== undefined ? players.get(id) : null
      const frame = entry && !entry.errored ? entry.frame : null
      if (shownFrame && shownFrame !== frame) {
        shownFrame.style.cssText = ''
        shownCss = ''
      }
      shownFrame = frame
      if (!frame) return false
      const width = Math.max(rect.width, (rect.height * 16) / 9)
      const height = Math.max(rect.height, (rect.width * 9) / 16)
      const left = rect.left - (width - rect.width) / 2
      const top = rect.top - (height - rect.height) / 2
      const cutX = (width - rect.width) / 2
      const cutY = (height - rect.height) / 2
      const css = `position:fixed;left:${left}px;top:${top}px;width:${width}px;height:${height}px;opacity:1;border:0;pointer-events:none;clip-path:inset(${cutY}px ${cutX}px);`
      if (css !== shownCss) {
        frame.style.cssText = css
        shownCss = css
      }
      return true
    },

    whenApi(fn) {
      if (window.YT && window.YT.Player) {
        apiReady = true
        fn()
        return
      }
      apiWaiters.push(fn)
      loadApi()
    },

    canvas(host, opts) {
      const on = (opts && opts.on) || {}
      let player = null
      let dead = false

      const state = () => {
        try {
          const s = player && player.getPlayerState ? player.getPlayerState() : -1
          if (s === window.YT.PlayerState.PLAYING) return 'playing'
          if (s === window.YT.PlayerState.ENDED) return 'ended'
        } catch {}
        return 'other'
      }

      this.whenApi(() => {
        if (dead) return
        player = new window.YT.Player(host, {
          width: opts.width,
          height: opts.height,
          videoId: opts.videoId,
          host: 'https://www.youtube.com',
          playerVars: { autoplay: 1, mute: 1, controls: 0, disablekb: 1, fs: 0, iv_load_policy: 3, rel: 0, playsinline: 1, modestbranding: 1, cc_load_policy: 0, start: opts.start, origin: window.location.origin },
          events: {
            onReady: (ev) => {
              if (dead) return
              try { ev.target.mute() } catch {}
              hideCaptions(ev.target)
              if (on.ready) on.ready()
            },
            onStateChange: (ev) => {
              if (dead) return
              if (ev.data === window.YT.PlayerState.PLAYING) {
                if (on.playing) on.playing()
              } else if (ev.data === window.YT.PlayerState.ENDED) {
                if (on.ended) on.ended()
              }
            },
            onError: () => {
              if (!dead && on.error) on.error()
            },
          },
        })
      })

      return {
        state,
        time() {
          try { return player && player.getCurrentTime ? player.getCurrentTime() : 0 } catch { return 0 }
        },
        seek(seconds) {
          try { player && player.seekTo(seconds, true) } catch {}
        },
        play() {
          try { player && player.playVideo() } catch {}
        },
        destroy() {
          dead = true
          try { player && player.destroy() } catch {}
          player = null
        },
      }
    },
  }
})()
