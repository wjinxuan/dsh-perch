/**
 * Perch (栖岛) — browser half of `@wjinxuan/dsh-perch`.
 *
 * This half owns no pixels. It aggregates the work running right now and posts
 * a presentation-ready snapshot to the screen-level helper
 * (`overlay/PerchOverlay.app`, port 47823), which draws the island in the
 * notch band.
 *
 * Where the work comes from — all existing Client projections, nothing new:
 *   - sessions whose turn is open (`running` on the Session list projection,
 *     the borrowed binding's own snapshot, and an open `turn/start` in the
 *     event window),
 *   - their open step and in-flight tool, folded from the binding's event
 *     window (`turn/start`, `step/start`, `tool/call`, `tool/result`),
 *   - background jobs from the `jobs` client service roster stream,
 *   - subagents, which are catalogued Session rows with `origin: 'subagent'`.
 *
 * No session event is ever appended and nothing is polled. All subscriptions,
 * timers and listeners live in `ctx.effect`, so disabling the plugin stops the
 * helper.
 */
window.__ModuleLoader__.load({
  id: '@wjinxuan/dsh-perch',
  factory() {
    /** Locale namespace shared by the registration and every UI string. */
    const NS = 'perch'

    /** Local endpoints of the screen-level overlay helper (see overlay/main.swift). */
    const OVERLAY_URL = 'http://127.0.0.1:47823/state'
    const OVERLAY_SETTINGS = 'http://127.0.0.1:47823/settings'

    /** Used until the helper answers `GET /settings` (or when it never does). */
    const DEFAULT_SETTINGS = {
      notify: { system: true, voice: true },
      text: { zh: '任务完成', en: 'Task complete' },
    }

    // ------------------------------------------------------------------
    // Tuning constants. The Client half of a bundle is created without the
    // row's config, so a Config schema needs a Host projection to reach here.
    // ------------------------------------------------------------------
    const SETTINGS = {
      mergeWindowMs: 2000,
      maxRows: 5,
      /** Upper bound on borrowed Session event windows and job rosters. */
      maxWatched: 8,
      /** Coalescing window for source-driven recomputation. */
      settleMs: 80,
      doneHoldMs: 2500,
      doneFlashMs: 800,
    }

    const DICT_EN = {
      'pill.runningOne': '1 task running',
      'pill.running': '{count} tasks running',
      'pill.idle': 'Idle',
      'done.title': 'Task complete',
      'done.many': '{count} tasks complete',
      'done.summary': 'Finished just now',
      'kind.session': 'Session',
      'kind.job': 'Job',
      'kind.subagent': 'Subagent',
      'action.step': 'step {step}',
      'action.working': 'working',
      'action.waiting': 'waiting',
      'foot.all': 'View all',
      'a11y.label': 'Perch task island',
      'row.untitled': 'Untitled session',
      'row.job': 'Background task',
    }

    const DICT_ZH = {
      'pill.runningOne': '1 个任务进行中',
      'pill.running': '{count} 个任务进行中',
      'pill.idle': '空闲',
      'done.title': '任务完成',
      'done.many': '{count} 个任务完成',
      'done.summary': '刚刚完成',
      'kind.session': '会话',
      'kind.job': '后台任务',
      'kind.subagent': '子 agent',
      'action.step': '第 {step} 步',
      'action.working': '进行中',
      'action.waiting': '等待中',
      'foot.all': '查看全部',
      'a11y.label': '栖岛任务浮层',
      'row.untitled': '未命名会话',
      'row.job': '后台任务',
    }

    // ------------------------------------------------------------------
    // small helpers
    // ------------------------------------------------------------------

    /** Run a reader that belongs to another package; never let it break the island. */
    function safe(read, fallback) {
      try {
        const value = read()
        return value === undefined ? fallback : value
      } catch {
        return fallback
      }
    }

    /** Last path segment of a workspace directory, for a readable fallback title. */
    function baseName(path) {
      if (typeof path !== 'string' || path === '') return ''
      const parts = path.split('/').filter((part) => part !== '')
      return parts.length === 0 ? '' : parts[parts.length - 1]
    }

    function isJobLive(status) {
      return status === 'running' || status === 'stopping'
    }

    /**
     * Fold one Session event window into the facts the island shows.
     *
     * The window carries durable `turn/start` / `step/start` / `tool/call`
     * events plus transient `assistant/live-chunk` presentations, so one
     * forward pass tells us the open turn, the open step and any tool call
     * still waiting for its `tool/result`.
     */
    function foldWindow(entries) {
      let turnStartedAt = 0
      let openStep = 0
      const calls = new Map()

      for (let index = 0; index < entries.length; index += 1) {
        const entry = entries[index]
        const event = entry && entry.event
        if (!event) continue
        if (entry.type === 'transient') continue
        const data = event.data || {}
        switch (event.type) {
          case 'turn/start':
            turnStartedAt = event.time || 0
            openStep = 0
            calls.clear()
            break
          case 'turn/end':
            turnStartedAt = 0
            openStep = 0
            calls.clear()
            break
          case 'step/start':
            openStep = data.step || 0
            break
          case 'step/end':
            openStep = 0
            break
          case 'tool/call':
            if (data.callId) calls.set(data.callId, { name: data.name || '', at: event.time || 0 })
            break
          case 'tool/result': {
            const callId = data.message && data.message.toolCallId
            if (callId) calls.delete(callId)
            break
          }
          default:
            break
        }
      }

      let toolName = ''
      let toolAt = -1
      for (const call of calls.values()) {
        if (call.at >= toolAt) {
          toolAt = call.at
          toolName = call.name
        }
      }
      return { turnStartedAt, openStep, toolName }
    }

    // ------------------------------------------------------------------
    // model
    // ------------------------------------------------------------------

    function emptySnapshot() {
      return {
        tasks: [],
        currentSessionId: '',
        completion: { seq: 0, count: 0, title: '', titleKey: '', current: false, expiresAt: 0 },
      }
    }

    /**
     * Aggregates the running work off the Client projections and hands one
     * immutable snapshot to `onSurface` after every change. Every fold happens
     * here, once, on a coalesced schedule.
     */
    function createModel(ctx, t, onSurface, locale) {
      let sessions = null
      let jobs = null

      const jobStops = new Map()
      const bindingStops = new Map()
      const foldCache = new Map()
      const stickyOwners = new Set()

      let snapshot = emptySnapshot()
      let signature = ''
      let previousActive = new Map()
      let completionCount = 0
      let completionAt = 0
      let scheduled = 0
      let disposed = false

      function schedule() {
        if (disposed || scheduled !== 0) return
        scheduled = setTimeout(() => {
          scheduled = 0
          recompute()
        }, SETTINGS.settleMs)
      }

      /**
       * The folded detail for one borrowed binding. The fold is cached by the
       * event window's revision; the live `running` flag is read fresh, because
       * it can flip without a new window revision.
       */
      function detailOf(sessionId, binding) {
        const window = safe(() => binding.eventSource.getSnapshot(), undefined)
        if (!window) return null
        const cached = foldCache.get(sessionId)
        const folded = cached && cached.revision === window.revision
          ? cached.value
          : foldWindow(window.entries || [])
        if (!cached || cached.revision !== window.revision) {
          foldCache.set(sessionId, { revision: window.revision, value: folded })
        }
        const live = safe(() => binding.session.getSnapshot(), undefined)
        return { turnStartedAt: folded.turnStartedAt, openStep: folded.openStep, toolName: folded.toolName, running: live ? live.running === true : false }
      }

      function subagentLabelOf(binding) {
        const identity = safe(() => binding.session.projections.faceOf('subagent').getSnapshot(), undefined)
        if (identity && typeof identity.label === 'string' && identity.label !== '') return identity.label
        return ''
      }

      function subagentSinceOf(binding) {
        const timing = safe(() => binding.session.projections.faceOf('subagentTiming').getSnapshot(), undefined)
        const since = timing && timing.active && timing.active.since
        return typeof since === 'number' ? since : 0
      }

      function findCurrentSessionId(list) {
        if (!list || !list.byId) return ''
        for (const row of Object.values(list.byId)) {
          if (!row) continue
          const counts = row.retainedBy
          if (counts && (counts.mainView || 0) > 0) return String(row.id)
        }
        return ''
      }

      function noteCompletion(task, currentSessionId) {
        const now = Date.now()
        const current = task.kind === 'session' && task.sessionId === currentSessionId
        completionCount = now - completionAt <= SETTINGS.mergeWindowMs ? completionCount + 1 : 1
        completionAt = now
        snapshot = {
          ...snapshot,
          completion: {
            seq: snapshot.completion.seq + 1,
            count: completionCount,
            title: task.title || '',
            titleKey: task.titleKey || 'done.summary',
            current,
            // The notice owns its own lifetime here: a heartbeat after this
            // instant carries `done: null`, so nothing can replay it.
            expiresAt: now + (current ? SETTINGS.doneFlashMs : SETTINGS.doneHoldMs),
          },
        }
      }

      function recompute() {
        if (disposed) return
        const list = sessions ? safe(() => sessions.list.getSnapshot(), null) : null
        const currentSessionId = findCurrentSessionId(list)
        const byId = (list && list.byId) || {}
        const ids = (list && list.ids) || []
        const jobSnapshot = jobs ? safe(() => jobs.state.getSnapshot(), null) : null
        const rosters = (jobSnapshot && jobSnapshot.rows) || {}

        const tasks = []
        const nextActive = new Map()
        const interest = new Set()

        if (currentSessionId !== '') interest.add(currentSessionId)

        // Sessions and subagents: catalogued rows that are running.
        for (const rawId of ids) {
          const sessionId = String(rawId)
          const row = byId[sessionId] || byId[rawId]
          if (!row) continue
          const binding = sessions ? safe(() => sessions.binding(rawId), undefined) : undefined
          const detail = binding ? detailOf(sessionId, binding) : null
          // Three independent signals, weakest last: the Host list projection,
          // the borrowed binding's own snapshot, and the log itself (an open
          // `turn/start` with no matching `turn/end` is a running turn).
          const running = row.running === true
            || (detail !== null && (detail.running || detail.turnStartedAt > 0))
          if (!running) continue

          const isSubagent = row.origin === 'subagent'
          const kind = isSubagent ? 'subagent' : 'session'
          const label = isSubagent && binding ? subagentLabelOf(binding) : ''
          const title = label || row.title || baseName(row.cwd) || ''
          const titleKey = title !== ''
            ? ''
            : isSubagent ? 'kind.subagent' : 'row.untitled'

          let actionText = ''
          let actionKey = ''
          let actionParams
          let startedAt = detail ? detail.turnStartedAt : 0
          if (isSubagent && startedAt === 0 && binding) startedAt = subagentSinceOf(binding)
          if (detail && detail.toolName) {
            actionText = detail.toolName
          } else if (detail && detail.openStep > 0) {
            actionKey = 'action.step'
            actionParams = { step: detail.openStep }
          } else {
            actionKey = 'action.working'
          }

          const task = {
            key: 'session:' + sessionId,
            kind,
            sessionId,
            title,
            titleKey,
            actionText,
            actionKey,
            actionParams,
            startedAt,
            updatedAt: row.updatedAt || 0,
          }
          tasks.push(task)
          nextActive.set(task.key, task)
          interest.add(sessionId)
        }

        // Background jobs from the watched rosters; a job visible in several
        // rosters (unowned jobs are) is one row.
        for (const rawId of Object.keys(rosters)) {
          const owner = String(rawId)
          const roster = rosters[rawId] || []
          for (const job of roster) {
            if (!job || !isJobLive(job.status)) continue
            const key = 'job:' + String(job.id)
            if (nextActive.has(key)) continue
            const task = {
              key,
              kind: 'job',
              rosterOwner: owner,
              sessionId: job.owner ? String(job.owner) : owner,
              title: typeof job.label === 'string' && job.label !== ''
                ? job.label.replace(/\s+/g, ' ').trim()
                : '',
              titleKey: typeof job.label === 'string' && job.label !== '' ? '' : 'row.job',
              actionText: '',
              actionKey: job.status === 'stopping' ? 'action.waiting' : 'action.working',
              actionParams: undefined,
              startedAt: job.startedAt || 0,
              updatedAt: job.startedAt || 0,
            }
            if (task.sessionId !== '') interest.add(task.sessionId)
            tasks.push(task)
            nextActive.set(key, task)
          }
          if (roster.some((job) => job && isJobLive(job.status))) stickyOwners.add(owner)
        }

        // Completion detection, before the rosters are released.
        for (const [key, task] of previousActive) {
          if (nextActive.has(key)) continue
          if (key.indexOf('session:') === 0) {
            const sessionId = key.slice('session:'.length)
            // A row that left the catalog was archived, not finished.
            if (!byId[sessionId]) continue
            noteCompletion(task, currentSessionId)
            continue
          }
          const jobId = key.slice('job:'.length)
          let settled = false
          for (const rawId of Object.keys(rosters)) {
            for (const job of rosters[rawId] || []) {
              if (job && String(job.id) === jobId && !isJobLive(job.status)) settled = true
            }
          }
          // A roster frame replaces the whole set, so a job that vanishes from
          // a roster we still hold has settled and been pruned. Without this
          // the notice never fires, because the terminal row is not kept.
          if (!settled) {
            const roster = rosters[task.rosterOwner]
            if (Array.isArray(roster) && !roster.some((job) => job && String(job.id) === jobId)) {
              settled = true
            }
          }
          if (settled) noteCompletion(task, currentSessionId)
        }
        previousActive = nextActive

        // Watch set: running rows, the viewed session, and owners of live jobs.
        tasks.sort((left, right) => (right.updatedAt || right.startedAt) - (left.updatedAt || left.startedAt))

        if (jobs) {
          for (const owner of Array.from(stickyOwners)) {
            const roster = rosters[owner] || []
            const live = roster.some((job) => job && isJobLive(job.status))
            const row = byId[owner]
            if (!live && !(row && row.running === true)) stickyOwners.delete(owner)
          }
          // Running rows and owners of live jobs are the only reasons to hold a
          // roster stream; an idle island opens none.
          const desired = new Set(stickyOwners)
          for (const rawId of ids) {
            const row = byId[String(rawId)] || byId[rawId]
            if (row && row.running === true) desired.add(String(rawId))
          }
          const wanted = Array.from(desired).slice(0, SETTINGS.maxWatched)
          for (const sessionId of wanted) {
            if (jobStops.has(sessionId)) continue
            const stop = safe(() => jobs.watchRows(sessionId), undefined)
            if (typeof stop === 'function') jobStops.set(sessionId, stop)
          }
          for (const [sessionId, stop] of Array.from(jobStops)) {
            if (wanted.indexOf(sessionId) !== -1) continue
            try {
              stop()
            } catch {
              // The roster stream is already gone.
            }
            jobStops.delete(sessionId)
          }
        }

        // Borrow event windows only for the tasks on screen (bounded).
        if (sessions) {
          const wanted = Array.from(interest).slice(0, SETTINGS.maxWatched)
          for (const sessionId of wanted) {
            const binding = safe(() => sessions.binding(sessionId), undefined)
            const existing = bindingStops.get(sessionId)
            if (binding && (!existing || existing.binding !== binding)) {
              if (existing) {
                try {
                  existing.stop()
                } catch {
                  // The generation is already disposed.
                }
              }
              const stop = binding.eventSource.subscribe(schedule)
              bindingStops.set(sessionId, { binding, stop })
            } else if (!binding && existing) {
              try {
                existing.stop()
              } catch {
                // The generation is already disposed.
              }
              bindingStops.delete(sessionId)
            }
          }
          for (const [sessionId, entry] of Array.from(bindingStops)) {
            if (wanted.indexOf(sessionId) !== -1) continue
            try {
              entry.stop()
            } catch {
              // The generation is already disposed.
            }
            bindingStops.delete(sessionId)
            foldCache.delete(sessionId)
          }
        }

        const nextSignature = JSON.stringify({
          currentSessionId,
          completion: snapshot.completion.seq,
          tasks: tasks.map((task) => [
            task.key, task.kind, task.sessionId, task.title, task.titleKey,
            task.actionText, task.actionKey, task.actionParams, task.startedAt,
          ]),
        })
        if (nextSignature === signature) return
        signature = nextSignature
        snapshot = {
          tasks,
          currentSessionId,
          completion: snapshot.completion,
        }
        onSurface(surfacePayload(snapshot, t, locale()))
      }

      const model = {
        /** Re-derive the payload (used by the heartbeat, not by changes). */
        surface() {
          return surfacePayload(snapshot, t, locale())
        },

        attachSessions(scope) {
          sessions = scope.get('sessions') || scope.sessions || null
          if (!sessions) return () => {}
          const stop = sessions.list.subscribe(schedule)
          schedule()
          return () => {
            stop()
            sessions = null
          }
        },

        attachJobs(scope) {
          jobs = scope.get('jobs') || scope.jobs || null
          if (!jobs) return () => {}
          const stop = jobs.state.subscribe(schedule)
          schedule()
          return () => {
            stop()
            jobs = null
          }
        },

        dispose() {
          if (disposed) return
          disposed = true
          if (scheduled !== 0) {
            clearTimeout(scheduled)
            scheduled = 0
          }
          for (const stop of bindingStops.values()) {
            try {
              stop.stop()
            } catch {
              // The generation is already disposed.
            }
          }
          bindingStops.clear()
          for (const stop of jobStops.values()) {
            try {
              stop()
            } catch {
              // The roster stream is already gone.
            }
          }
          jobStops.clear()
          foldCache.clear()
          stickyOwners.clear()
          previousActive = new Map()
        },
      }

      return model
    }

    /**
     * Presentation-only payload for the screen-level helper. Every visible
     * string is localized here, so the helper never needs a dictionary. Idle
     * still renders: the helper keeps the notch band alive so the island can be
     * woken at any time. Only teardown sends `clear`.
     */
    function surfacePayload(snapshot, t, locale) {
      const completion = snapshot.completion
      const done = completion.seq > 0 && Date.now() < completion.expiresAt
        ? {
            seq: completion.seq,
            title: completion.count > 1
              ? t('done.many', { count: completion.count })
              : t('done.title'),
            summary: completion.title || (completion.titleKey ? t(completion.titleKey) : t('done.summary')),
            current: completion.current === true,
          }
        : null

      if (snapshot.tasks.length === 0) {
        return {
          headline: t('pill.idle'),
          headAction: '',
          footer: t('foot.all'),
          rows: [],
          done,
          clear: false,
          locale,
        }
      }

      const visible = snapshot.tasks.slice(0, SETTINGS.maxRows)
      return {
        headline: visible.length === 1
          ? t('pill.runningOne')
          : t('pill.running', { count: visible.length }),
        headAction: actionLabelOf(visible[0], t),
        footer: t('foot.all'),
        rows: visible.map((task) => ({
          key: task.key,
          kind: task.kind,
          title: task.title || (task.titleKey ? t(task.titleKey) : ''),
          tag: t('kind.' + task.kind),
          action: actionLabelOf(task, t),
          startedAt: task.startedAt || 0,
        })),
        done,
        clear: false,
        locale,
      }
    }

    /** Teardown tells the helper to hide the notch band entirely. */
    const CLEAR_PAYLOAD = { headline: '', headAction: '', footer: '', rows: [], done: null, clear: true }

    /** The row's current action: a bare tool name, or a translated fallback. */
    function actionLabelOf(task, t) {
      if (!task) return ''
      if (task.actionText) return task.actionText
      if (task.actionKey) return t(task.actionKey, task.actionParams)
      return ''
    }

    // ------------------------------------------------------------------
    // plugin
    // ------------------------------------------------------------------

    return {
      inject: ['locale'],

      apply(ctx) {
        ctx.effect(() => ctx.locale.register(NS, { zh: DICT_ZH, en: DICT_EN }), 'perch: dictionaries')

        // `bind` reads the active locale at call time, so a language switch
        // reaches the next heartbeat without re-registering anything. The
        // helper uses the same id to pick the custom notification text.
        const t = ctx.locale.bind(NS)
        const activeLocale = () => {
          try {
            const snapshot = ctx.locale.getSnapshot()
            const id = snapshot && typeof snapshot.active === 'string' ? snapshot.active : 'en'
            return id.toLowerCase().startsWith('zh') ? 'zh' : 'en'
          } catch {
            return 'en'
          }
        }

        let latest = null
        let sentAt = 0
        let timer = 0

        const post = (payload) => {
          try {
            void fetch(OVERLAY_URL, {
              method: 'POST',
              headers: { 'Content-Type': 'text/plain' },
              body: JSON.stringify(payload),
              keepalive: true,
            }).catch(() => {})
          } catch {
            // The helper may not be running; nothing else depends on this.
          }
        }

        const flush = () => {
          timer = 0
          if (latest === null) return
          sentAt = Date.now()
          post(latest)
        }

        // --- completion banner -------------------------------------------------
        // macOS refuses notifications from the ad-hoc signed helper, so the
        // banner comes from this page instead: DSH is a signed app and its
        // permission handler approves everything but the microphone.
        let remoteSettings = null
        let settingsAt = 0
        let permissionAt = 0
        let notifiedSeq = 0

        const readSettings = async () => {
          if (remoteSettings !== null && Date.now() - settingsAt < 5_000) return remoteSettings
          try {
            const response = await fetch(OVERLAY_SETTINGS)
            if (response.ok) {
              remoteSettings = await response.json()
              settingsAt = Date.now()
            }
          } catch {
            // The helper may not be running yet; defaults are good enough.
          }
          return remoteSettings || DEFAULT_SETTINGS
        }

        const announce = (payload) => {
          const done = payload.done
          if (!done || done.current || done.seq === notifiedSeq) return
          if (typeof Notification === 'undefined') return
          if (Notification.permission === 'denied') return
          notifiedSeq = done.seq
          void readSettings().then((config) => {
            const notify = (config && config.notify) || DEFAULT_SETTINGS.notify
            const text = (config && config.text) || DEFAULT_SETTINGS.text
            if (notify.system === false) return
            const language = payload.locale === 'zh' ? 'zh' : 'en'
            const message = typeof text[language] === 'string' && text[language] !== ''
              ? text[language]
              : DEFAULT_SETTINGS.text[language]
            const body = done.summary || done.title
            const show = () => {
              try {
                new Notification(message, { body })
              } catch {
                // A blocked notification must stay silent.
              }
            }
            if (Notification.permission === 'granted') {
              show()
              return
            }
            // One prompt per minute at most; never nag.
            if (Date.now() - permissionAt < 60_000) return
            permissionAt = Date.now()
            try {
              Notification.requestPermission().then((permission) => {
                if (permission === 'granted') show()
              }).catch(() => {})
            } catch {
              // requestPermission can throw outside a user gesture.
            }
          })
        }

        const push = (payload) => {
          announce(payload)
          latest = payload
          if (timer !== 0) return
          timer = setTimeout(flush, Math.max(0, 120 - (Date.now() - sentAt)))
        }

        const model = createModel(ctx, t, push, activeLocale)
        ctx.effect(() => () => model.dispose(), 'perch: model')

        // The heartbeat re-derives the payload, so a completion notice expires
        // on its own and an idle island still proves it is alive.
        ctx.effect(() => {
          const heartbeat = setInterval(() => push(model.surface()), 4000)
          return () => {
            clearInterval(heartbeat)
            if (timer !== 0) clearTimeout(timer)
            latest = null
            post(CLEAR_PAYLOAD)
          }
        }, 'perch: overlay surface')

        ctx.inject(['sessions'], (scope) => {
          scope.effect(() => model.attachSessions(scope), 'perch: sessions')
        })
        ctx.inject(['jobs'], (scope) => {
          scope.effect(() => model.attachJobs(scope), 'perch: jobs')
        })
      },
    }
  },
})
