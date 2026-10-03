// NotchNerd bridge for Claude Code.
//
// Notepad: gives the model four tools over the always-open notch notepad and
// adds `/notch [text]`. Reads go straight to NotchNerd's on-disk store; writes are
// dropped into its inbox folder as small JSON requests, which the running app
// applies through NotesStore (so they never race its debounced autosave and
// show up live in the notch). If NotchNerd is not running, the request waits
// in the inbox and is applied at its next launch.
//
//   ~/Library/Application Support/NotchNerd/Notepad/
//     index.json        ordered note metadata + selectedID
//     notes/<UUID>.md   one body per note
//     inbox/*.json      { version, op: "append" | "new", noteID, text, title, source }
//
// Reply from the notch: NotchNerd (Settings → Agent → Reply from the notch)
// writes what you type in the notch for a session to its outbox; this mod polls
// its own session's folder, removes each reply and submits it as your prompt
// (queued until the session is idle). A presence file tells NotchNerd which
// sessions have a mod listening, so it only offers Reply where it will arrive.
//
//   ~/Library/Application Support/NotchNerd/Agent/
//     mod-sessions/<sessionId>.json       { sessionId, cwd, surface, updatedAt, ended? }
//     outbox/<sessionId>/<ms>-<rand>.json { version: 1, text }
//
// Notch toasts: `notch_notify` flashes a short message in the closed notch by
// dropping a request into NotchNerd's event inbox, which any mod may write to.
//
//   ~/Library/Application Support/NotchNerd/Events/inbox/<ms>-<rand>.json
//     { version: 1, type: "toast", message, title?, style?, icon?, duration?, sound?, createdAt }
//     { version: 1, type: "timer", op: "start", minutes, label } | { version: 1, type: "timer", op: "stop" }
//   Events/timer.json   { endsAt, minutes, label } while a focus timer runs (written by NotchNerd)

import type { EngineInterface, Register } from 'claude-code'

type NoteMeta = {
  id: string
  explicitTitle?: string | null
  createdAt?: string
  modifiedAt?: string
}

type NotesIndex = { order: NoteMeta[]; selectedID?: string | null }

type Note = {
  id: string
  title: string
  modifiedAt?: string
  isSelected: boolean
  body: string
}

type InboxRequest = {
  version: 1
  op: 'append' | 'new'
  noteID: string | null
  text: string
  title: string | null
  source: string
}


// How long a write waits to see NotchNerd pick its request up before
// reporting it as queued instead of applied.
const APPLY_WAIT_MS = 1_500
const APPLY_POLL_MS = 150
const MAX_READ_CHARS = 100_000

class NotepadError extends Error {}

type ToastRequest = {
  version: 1
  type: 'toast'
  message: string
  title: string | null
  style: 'info' | 'success' | 'warning' | 'error'
  icon: string | null
  duration: number | null
  sound: boolean
  createdAt: number
  source: string
}

const TOAST_STYLES = ['info', 'success', 'warning', 'error'] as const
const NOT_RUNNING = "NotchNerd didn't pick it up (it may not be running)."

async function readTimer($: EngineInterface): Promise<TimerState | undefined> {
  try {
    const state = JSON.parse(await $.fs.read(`${await eventsRoot($)}/timer.json`)) as TimerState
    return state.endsAt > (await $.clock.now()) ? state : undefined
  } catch {
    return undefined
  }
}

function remaining(state: TimerState, now: number): string {
  const minutes = Math.max(1, Math.ceil((state.endsAt - now) / 60_000))
  return minutes === 1 ? 'under a minute' : `${minutes} minutes`
}

// "25", "25m", "1h", "1.5h" → minutes; anything else is undefined.
function parseMinutes(token: string | undefined): number | undefined {
  const match = /^(\d+(?:\.\d+)?)(m|min|h|hr)?$/i.exec(token ?? '')
  if (!match) return undefined
  const value = Number(match[1])
  return /^h/i.test(match[2] ?? '') ? value * 60 : value
}

async function startTimer($: EngineInterface, minutes: number, label: string): Promise<string> {
  const clamped = Math.min(Math.max(minutes, 1), 240)
  const isApplied = await postEvent($, { version: 1, type: 'timer', op: 'start', minutes: clamped, label: label || null })
  const what = `${label || 'Focus'}: ${clamped} minute${clamped === 1 ? '' : 's'}`
  return isApplied ? `Timer started in the notch (${what}).` : `${NOT_RUNNING} Timer not started.`
}

async function stopTimer($: EngineInterface): Promise<string> {
  const running = await readTimer($)
  if (!running) return 'No timer is running.'
  const isApplied = await postEvent($, { version: 1, type: 'timer', op: 'stop' })
  return isApplied ? `Stopped "${running.label}".` : `${NOT_RUNNING} Timer not stopped.`
}

type TimerRequest =
  | { version: 1; type: 'timer'; op: 'start'; minutes: number; label: string | null }
  | { version: 1; type: 'timer'; op: 'stop' }

type TimerState = { endsAt: number; minutes: number; label: string }

async function eventsRoot($: EngineInterface): Promise<string> {
  const home = await $.env.get('HOME')
  if (!home) throw new NotepadError('HOME is not set, so NotchNerd cannot be located.')
  return `${home}/Library/Application Support/NotchNerd/Events`
}

// Drops a request into NotchNerd's event inbox; true once the app has picked it up.
async function postEvent($: EngineInterface, request: ToastRequest | TimerRequest): Promise<boolean> {
  const name = `${Date.now()}-${Math.random().toString(36).slice(2, 10)}.json`
  const path = `${await eventsRoot($)}/inbox/${name}`
  await $.fs.write(path, JSON.stringify(request))
  for (let waited = 0; waited < APPLY_WAIT_MS; waited += APPLY_POLL_MS) {
    await $.clock.sleep(APPLY_POLL_MS)
    if (!(await $.fs.exists(path))) return true
  }
  return false
}

async function notepadRoot($: EngineInterface): Promise<string> {
  const home = await $.env.get('HOME')
  if (!home) throw new NotepadError('HOME is not set, so the NotchNerd notepad cannot be located.')
  return `${home}/Library/Application Support/NotchNerd/Notepad`
}

// Mirrors Note.displayTitle in NotchNerd/Notepad/NotesStore.swift.
function displayTitle(meta: NoteMeta, body: string): string {
  if (meta.explicitTitle) return meta.explicitTitle
  const firstLine = body.split(/\r\n|\r|\n/).find(line => line.length > 0)?.trim() ?? ''
  return firstLine === '' ? 'Untitled' : firstLine.slice(0, 40)
}

async function loadNotes($: EngineInterface): Promise<{ root: string; notes: Note[] }> {
  const root = await notepadRoot($)
  let index: NotesIndex
  try {
    index = JSON.parse(await $.fs.read(`${root}/index.json`)) as NotesIndex
  } catch {
    throw new NotepadError(
      "NotchNerd's notepad isn't set up on this Mac yet (no Notepad/index.json). Open NotchNerd once, then try again.",
    )
  }
  const selected = index.selectedID ?? index.order[0]?.id
  const notes = await Promise.all(
    index.order.map(async meta => {
      const body = await $.fs.read(`${root}/notes/${meta.id}.md`).catch(() => '')
      return {
        id: meta.id,
        title: displayTitle(meta, body),
        modifiedAt: meta.modifiedAt,
        isSelected: meta.id === selected,
        body,
      }
    }),
  )
  return { root, notes }
}

// `query` is empty / "selected" / "current" for the note open in the notch, a
// note id or an id prefix of 4+ characters, or a title (exact, then contains).
function findNote(notes: Note[], query: unknown): Note {
  const q = typeof query === 'string' ? query.trim() : ''
  if (q === '' || /^(selected|current|open)$/i.test(q)) {
    const note = notes.find(n => n.isSelected) ?? notes[0]
    if (!note) throw new NotepadError('The NotchNerd notepad has no notes.')
    return note
  }
  const lower = q.toLowerCase()
  const byID =
    notes.find(n => n.id.toLowerCase() === lower) ??
    (lower.length >= 4 ? notes.find(n => n.id.toLowerCase().startsWith(lower)) : undefined)
  if (byID) return byID
  const exact = notes.filter(n => n.title.toLowerCase() === lower)
  const [onlyExact] = exact
  if (exact.length === 1 && onlyExact) return onlyExact
  const partial = exact.length > 1 ? exact : notes.filter(n => n.title.toLowerCase().includes(lower))
  const [onlyPartial] = partial
  if (partial.length === 1 && onlyPartial) return onlyPartial
  if (partial.length === 0) {
    throw new NotepadError(`No note matches "${q}". Notes:\n${listing(notes)}`)
  }
  throw new NotepadError(`"${q}" matches several notes; pass an id instead:\n${listing(partial)}`)
}

function listing(notes: Note[]): string {
  return notes
    .map(n => `- ${n.id.slice(0, 8)}  ${n.title}${n.isSelected ? '  (open in the notch)' : ''}`)
    .join('\n')
}

async function enqueue($: EngineInterface, root: string, request: InboxRequest): Promise<boolean> {
  const name = `${Date.now()}-${Math.random().toString(36).slice(2, 10)}.json`
  const path = `${root}/inbox/${name}`
  await $.fs.write(path, JSON.stringify(request))
  // NotchNerd deletes the file once applied; give it a moment to do so.
  for (let waited = 0; waited < APPLY_WAIT_MS; waited += APPLY_POLL_MS) {
    await $.clock.sleep(APPLY_POLL_MS)
    if (!(await $.fs.exists(path))) return true
  }
  return false
}

const QUEUED_NOTE =
  "NotchNerd didn't pick it up yet (it may not be running), so it will be applied the next time NotchNerd starts."

function outcome(isApplied: boolean, applied: string, queued: string): string {
  return isApplied ? applied : `${queued} ${QUEUED_NOTE}`
}

function asText(value: unknown): string {
  return typeof value === 'string' ? value : ''
}

// Reply polling. Each tick is three host calls (id, clock, list), so a
// second keeps a reply snappy without real cost; presence is refreshed far
// less often and NotchNerd treats one older than a minute as gone.
const REPLY_POLL_MS = 1_000
const PRESENCE_EVERY_MS = 20_000

type Presence = {
  sessionId: string
  cwd: string
  surface: string | null
  updatedAt: number
  ended?: true
}

async function agentRoot($: EngineInterface): Promise<string | undefined> {
  const home = await $.env.get('HOME')
  return home ? `${home}/Library/Application Support/NotchNerd/Agent` : undefined
}

// Claude Code session ids are UUIDs; refuse anything that could leave the folder.
const isSafeID = (id: string) => /^[A-Za-z0-9][A-Za-z0-9._-]*$/.test(id)

async function writePresence($: EngineInterface, root: string, presence: Presence): Promise<void> {
  if (!isSafeID(presence.sessionId)) return
  await $.fs.write(`${root}/mod-sessions/${presence.sessionId}.json`, JSON.stringify(presence))
}

// Starts the reply loop for this session: lives until the module reloads or
// the process exits. Never throws; a failed tick is retried on the next.
function startReplyLoop($: EngineInterface, cwd: string, surface: string | null): void {
  let isBusy = false
  let presenceID: string | undefined
  let presenceAt = 0

  const tick = async () => {
    if (isBusy) return
    isBusy = true
    try {
      const root = await agentRoot($)
      if (!root) return
      const id = await $.session.id()
      if (!isSafeID(id)) return
      const now = await $.clock.now()
      if (id !== presenceID || now - presenceAt >= PRESENCE_EVERY_MS) {
        // A /clear goes on under a new id without a session.start: retire the old one.
        if (presenceID && presenceID !== id) {
          await writePresence($, root, { sessionId: presenceID, cwd, surface, updatedAt: now, ended: true })
        }
        await writePresence($, root, { sessionId: id, cwd, surface, updatedAt: now })
        presenceID = id
        presenceAt = now
      }

      const dir = `${root}/outbox/${id}`
      const entries = await $.fs.list(dir).catch(() => [])
      const replies = entries
        .filter(entry => entry.kind === 'file' && entry.name.endsWith('.json'))
        .map(entry => entry.name)
        .sort()
      for (const name of replies) {
        const path = `${dir}/${name}`
        const raw = await $.fs.read(path).catch(() => undefined)
        // Take it off the queue before submitting, so a reload mid-way can't send it twice.
        const removed = await $.process.run(['/bin/rm', '-f', path]).catch(() => undefined)
        if (removed?.exitCode !== 0) continue
        let text = ''
        try {
          const reply = JSON.parse(raw ?? '') as { text?: unknown }
          text = typeof reply.text === 'string' ? reply.text.trim() : ''
        } catch {
          $.ui.toast('NotchNerd: skipped a reply it could not read.')
        }
        if (text === '') continue
        // Resolves only once the turn starts, so it is not awaited: a long turn
        // must not stall the presence refresh above.
        void $.prompt.submit({ text, asUser: true }).then(
          result => {
            if (result.drop !== undefined) $.ui.toast(`NotchNerd reply not sent: ${result.drop}`)
          },
          () => $.ui.toast('NotchNerd reply could not be submitted.'),
        )
      }
    } catch {
      // Host call failed (file system busy, session ending): next tick retries.
    } finally {
      isBusy = false
    }
  }

  $.clock.every(REPLY_POLL_MS, () => void tick())
  void tick()
}

export const register: Register = on => {
  on('session.start', async ($, e, next) => {
    await $.tool.register({
      name: 'notepad_list',
      description:
        "List the notes in the user's NotchNerd notepad: an always-open scratchpad that lives in their Mac's notch, where they keep TODOs and working notes. Returns each note's id, title and last-modified time, and marks the note currently open in the notch. Use notepad_read to get a note's text.",
      inputSchema: { type: 'object', properties: {} },
    })
    await $.tool.register({
      name: 'notepad_read',
      description:
        "Read a note from the user's NotchNerd notepad (their always-open notch scratchpad). With no `note`, reads the note currently open in the notch. Use when the user refers to 'my notes', 'the notch', or 'what I jotted down'.",
      inputSchema: {
        type: 'object',
        properties: {
          note: {
            type: 'string',
            description:
              'Which note: an id (or its first 8 characters) or a title. Omit for the note open in the notch.',
          },
        },
      },
    })
    await $.tool.register({
      name: 'notepad_append',
      description:
        "Append text to a note in the user's NotchNerd notepad (default: the note open in the notch). Only appends, never overwrites. Use when the user asks you to jot something down, note a follow-up or TODO, or leave them a summary in the notch.",
      inputSchema: {
        type: 'object',
        properties: {
          text: { type: 'string', description: 'The text to add, appended on a new line.' },
          note: {
            type: 'string',
            description:
              'Which note: an id (or its first 8 characters) or a title. Omit for the note open in the notch.',
          },
        },
        required: ['text'],
      },
    })
    await $.tool.register({
      name: 'notepad_new',
      description:
        "Create a new note in the user's NotchNerd notepad; it becomes the note open in the notch. Use when the user asks for a separate note rather than adding to the current one.",
      inputSchema: {
        type: 'object',
        properties: {
          text: { type: 'string', description: "The new note's text." },
          title: {
            type: 'string',
            description: "Optional title. Without one the note is titled by its first line.",
          },
        },
        required: ['text'],
      },
    })
    await $.tool.register({
      name: 'notch_notify',
      description:
        "Flash a short message in the user's Mac notch (NotchNerd) for a few seconds. Use it when the user asks to be told in the notch, or to flag something they'd want to see while looking elsewhere: a long build, test run or deploy finishing, or something waiting on them. One short phrase, not a summary; don't use it for routine progress.",
      inputSchema: {
        type: 'object',
        properties: {
          message: { type: 'string', description: 'The message, a few words (shown on one line, about 30 characters fit).' },
          title: { type: 'string', description: 'Short label for where it comes from, e.g. the project name. Defaults to "Claude Code".' },
          style: {
            type: 'string',
            enum: [...TOAST_STYLES],
            description: 'info (default), success, warning or error. Sets the icon and its color.',
          },
          icon: { type: 'string', description: 'Optional SF Symbol name to use instead of the style\'s icon.' },
          duration: { type: 'number', description: 'Seconds on screen, 2 to 10. Default 4.' },
          sound: { type: 'boolean', description: 'Also play the notification sound. Default false.' },
        },
        required: ['message'],
      },
    })
    await $.tool.register({
      name: 'notch_timer',
      description:
        "Start or stop a countdown in the user's Mac notch (NotchNerd); when it ends the notch shows a message and plays a sound. Use when the user asks for a timer, a focus session or a reminder in N minutes. One timer at a time: starting replaces the running one.",
      inputSchema: {
        type: 'object',
        properties: {
          minutes: { type: 'number', description: 'Length in minutes, 1 to 240. Omit with stop.' },
          label: { type: 'string', description: 'What it is for, a few words (e.g. "Write tests", "Tea").' },
          stop: { type: 'boolean', description: 'Stop the running timer instead of starting one.' },
        },
      },
    })
    // A command whose name Claude Code later takes as a built-in is refused; skip it rather than let
    // the throw stop the rest of this hook (the tools above and the reply loop below).
    const commands = [
      {
        name: 'timer',
        description: 'Countdown in the notch: /timer 25 [label], /timer stop, or /timer to see what is left',
        argumentHint: '[minutes] [label] | stop',
        immediate: true as const,
      },
      {
        name: 'notch',
        description: 'Jot a line into the NotchNerd notepad (no text: show the open note)',
        argumentHint: '[text]',
        immediate: true as const,
      },
    ]
    for (const command of commands) {
      await $.command.register(command).catch(() => $.ui.toast(`NotchNerd: /${command.name} is taken, so it's off.`))
    }
    startReplyLoop($, e.cwd, e.surface)
    return next(e)
  })

  on('session.end', async ($, e, next) => {
    const root = await agentRoot($)
    if (root) {
      await writePresence($, root, {
        sessionId: e.sessionId,
        cwd: await $.session.cwd(),
        surface: null,
        updatedAt: await $.clock.now(),
        ended: true,
      }).catch(() => undefined)
    }
    return next(e)
  })

  on('tool.call', { tool: 'mcp__notchnerd__notepad_list' }, async $ => {
    try {
      const { notes } = await loadNotes($)
      const rows = notes.map(
        n => `- id ${n.id}  "${n.title}"  modified ${n.modifiedAt ?? 'unknown'}${n.isSelected ? '  (open in the notch)' : ''}`,
      )
      return { result: `${notes.length} note(s) in the NotchNerd notepad:\n${rows.join('\n')}` }
    } catch (error) {
      return { deny: error instanceof NotepadError ? error.message : `Could not read the notepad: ${error}` }
    }
  })

  on('tool.call', { tool: 'mcp__notchnerd__notepad_read' }, async ($, e) => {
    try {
      const { notes } = await loadNotes($)
      const note = findNote(notes, e.note)
      const body =
        note.body.length > MAX_READ_CHARS
          ? `${note.body.slice(0, MAX_READ_CHARS)}\n[... truncated, ${note.body.length - MAX_READ_CHARS} more characters]`
          : note.body
      const header = `Note "${note.title}" (id ${note.id}${note.isSelected ? ', open in the notch' : ''}, modified ${note.modifiedAt ?? 'unknown'}):`
      return { result: body.trim() === '' ? `${header}\n(empty)` : `${header}\n\n${body}` }
    } catch (error) {
      return { deny: error instanceof NotepadError ? error.message : `Could not read the notepad: ${error}` }
    }
  })

  on('tool.call', { tool: 'mcp__notchnerd__notepad_append' }, async ($, e) => {
    const text = asText(e.text)
    if (text.trim() === '') return { deny: '`text` is empty; nothing to append.' }
    try {
      const { root, notes } = await loadNotes($)
      const note = findNote(notes, e.note)
      const isApplied = await enqueue($, root, {
        version: 1,
        op: 'append',
        noteID: note.id,
        text,
        title: null,
        source: 'claude-code',
      })
      return { result: outcome(
          isApplied,
          `Appended to "${note.title}" in the NotchNerd notepad.`,
          `Queued an append to "${note.title}".`,
        ) }
    } catch (error) {
      return { deny: error instanceof NotepadError ? error.message : `Could not write to the notepad: ${error}` }
    }
  })

  on('tool.call', { tool: 'mcp__notchnerd__notepad_new' }, async ($, e) => {
    const text = asText(e.text)
    const title = asText(e.title).trim()
    if (text.trim() === '' && title === '') return { deny: 'Give the new note some `text` or a `title`.' }
    try {
      const root = await notepadRoot($)
      const isApplied = await enqueue($, root, {
        version: 1,
        op: 'new',
        noteID: null,
        text,
        title: title === '' ? null : title,
        source: 'claude-code',
      })
      return { result: outcome(
          isApplied,
          'Created a new note in the NotchNerd notepad; it is now open in the notch.',
          'Queued a new note.',
        ) }
    } catch (error) {
      return { deny: error instanceof NotepadError ? error.message : `Could not write to the notepad: ${error}` }
    }
  })

  on('tool.call', { tool: 'mcp__notchnerd__notch_notify' }, async ($, e) => {
    const message = asText(e.message).trim()
    if (message === '') return { deny: '`message` is empty; nothing to show.' }
    const style = TOAST_STYLES.find(s => s === e.style) ?? 'info'
    const title = asText(e.title).trim()
    const icon = asText(e.icon).trim()
    try {
      const isShown = await postEvent($, {
        version: 1,
        type: 'toast',
        message,
        title: title === '' ? null : title,
        style,
        icon: icon === '' ? null : icon,
        duration: typeof e.duration === 'number' ? e.duration : null,
        sound: e.sound === true,
        createdAt: await $.clock.now(),
        source: 'claude-code',
      })
      return { result: isShown
        ? `Shown in the notch: "${message}".`
        : "NotchNerd didn't pick it up (it may not be running), so it won't be shown." }
    } catch (error) {
      return { deny: error instanceof NotepadError ? error.message : `Could not reach NotchNerd: ${error}` }
    }
  })

  on('tool.call', { tool: 'mcp__notchnerd__notch_timer' }, async ($, e) => {
    try {
      if (e.stop === true) return { result: await stopTimer($) }
      const minutes = typeof e.minutes === 'number' ? e.minutes : NaN
      if (!(minutes > 0)) return { deny: 'Give `minutes` (1 to 240), or `stop: true`.' }
      return { result: await startTimer($, minutes, asText(e.label).trim()) }
    } catch (error) {
      return { deny: error instanceof NotepadError ? error.message : `Could not reach NotchNerd: ${error}` }
    }
  })

  on('command.run', { command: 'timer' }, async ($, e) => {
    try {
      const words = e.args.trim().split(/\s+/).filter(word => word !== '')
      if (words.length === 0) {
        const running = await readTimer($)
        return { text: running
          ? `${running.label}: ${remaining(running, await $.clock.now())} left.`
          : 'No timer is running. Start one with /timer 25 [label].' }
      }
      if (/^(stop|cancel|off|end)$/i.test(words[0] ?? '')) return { text: await stopTimer($) }
      const minutes = parseMinutes(words[0])
      const label = (minutes === undefined ? words : words.slice(1)).join(' ')
      return { text: await startTimer($, minutes ?? 25, label) }
    } catch (error) {
      return { text: error instanceof NotepadError ? error.message : `Could not reach NotchNerd: ${error}` }
    }
  })

  on('command.run', { command: 'notch' }, async ($, e) => {
    try {
      const { root, notes } = await loadNotes($)
      const note = findNote(notes, undefined)
      const text = e.args.trim()
      if (text === '') {
        const preview = note.body.trim() === '' ? '(empty)' : note.body.trimEnd().split('\n').slice(0, 20).join('\n')
        return { text: `${note.title}\n${preview}` }
      }
      const isApplied = await enqueue($, root, {
        version: 1,
        op: 'append',
        noteID: note.id,
        text,
        title: null,
        source: 'claude-code /notch',
      })
      return { text: outcome(isApplied, `Added to "${note.title}".`, `Queued for "${note.title}".`) }
    } catch (error) {
      return { text: error instanceof NotepadError ? error.message : `Could not reach the notepad: ${error}` }
    }
  })
}
