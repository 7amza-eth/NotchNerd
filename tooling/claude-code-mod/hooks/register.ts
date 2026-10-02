// NotchNerd notepad bridge for Claude Code.
//
// Gives the model four tools over the always-open notch notepad and adds
// `/notch [text]`. Reads go straight to NotchNerd's on-disk store; writes are
// dropped into its inbox folder as small JSON requests, which the running app
// applies through NotesStore (so they never race its debounced autosave and
// show up live in the notch). If NotchNerd is not running, the request waits
// in the inbox and is applied at its next launch.
//
//   ~/Library/Application Support/NotchNerd/Notepad/
//     index.json        ordered note metadata + selectedID
//     notes/<UUID>.md   one body per note
//     inbox/*.json      { version, op: "append" | "new", noteID, text, title, source }

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
    await $.command.register({
      name: 'notch',
      description: 'Jot a line into the NotchNerd notepad (no text: show the open note)',
      argumentHint: '[text]',
      immediate: true,
    })
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
