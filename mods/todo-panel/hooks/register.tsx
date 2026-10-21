import { atom, read, update } from 'claude-code'
import type { EngineInterface, Register } from 'claude-code'

import type { TodoKind, TodoPending, TodoTask } from '../types'

const PANE = 'todo-panel'
const TITLE = 'Todo'
const ADD_TOOL = 'add_pending'
const RESOLVE_TOOL = 'resolve_pending'
const START_TOOL = 'start_pending'
// The dock takes a quarter of the terminal, never narrower than MIN_COLUMNS.
const MIN_COLUMNS = 30
// session.start knows no width: a quarter of the 144 columns an unasked pane needs to dock.
const AUTO_COLUMNS = 36

// Claude's own task list: TaskCreate/TaskUpdate keep `tasks`, TodoWrite replaces `todos` whole.
const tasks = atom({ plugin: 'todo-panel', key: 'tasks' } as const, [])
const todos = atom({ plugin: 'todo-panel', key: 'todos' } as const, [])
// Rows the model's tools or /todo add keep: decisions waiting on the person, and Claude's own tasks.
const pending = atom({ plugin: 'todo-panel', key: 'pending' } as const, [])
const nextId = atom({ plugin: 'todo-panel', key: 'nextId' } as const, 1)
// True while the pane is open because the session started, not because the person asked.
const isAuto = atom({ plugin: 'todo-panel', key: 'isAuto' } as const, true)

const RULES = [
  '# Todo panel',
  `The person sees a side panel listing what this session has not handled yet. Keep it current with the \`mcp__todo-panel__${ADD_TOOL}\`, \`mcp__todo-panel__${START_TOOL}\` and \`mcp__todo-panel__${RESOLVE_TOOL}\` tools.`,
  `- kind "decision": call \`${ADD_TOOL}\` once per item you leave for the person to decide or act on: a question you asked, an option list awaiting their pick, a problem you found but were not asked to fix, a follow-up you deferred.`,
  `- kind "task": when you lay out several steps you will do yourself, call \`${ADD_TOOL}\` once per step, unless TaskCreate or TodoWrite already tracks them. Call \`${START_TOOL}\` when you start a step.`,
  `- Call \`${RESOLVE_TOOL}\` with the item's id once a decision is made or dropped, or a task is done.`,
  '- Record items in the same turn you raise them, before you end the turn. Keep each text short (under 60 characters), in the language of the conversation.',
].join('\n')

// Sent back to the model when its reply looks like it left something open but recorded nothing.
const REMINDER = [
  `todo-panel: your last reply seems to leave questions, options or a list of steps open, and you recorded nothing on the todo panel this turn.`,
  `Record each open item now with mcp__todo-panel__${ADD_TOOL} (kind "decision" for what waits on the person, kind "task" for steps you will do), then end your turn without repeating your reply.`,
  'If nothing in it should be recorded, end your turn without saying anything.',
].join(' ')

// A question near the end, or three or more numbered lines (steps or options; bullets are mostly explanation).
function looksOpen(reply: string): boolean {
  const tail = reply.slice(-600)
  const listLines = reply.split('\n').filter(line => /^\s*\d+[.、)]\s+\S/.test(line)).length

  return /[?？]/.test(tail) || listLines >= 3
}

async function addPending($: EngineInterface, text: string, kind: TodoKind): Promise<number> {
  const id = (await read($, nextId)) ?? 1
  await update($, nextId, () => id + 1)
  await update($, pending, list => [...(list ?? []), { id, text, kind }])

  return id
}

async function resolvePending($: EngineInterface, id: number): Promise<boolean> {
  const list: TodoPending[] = (await read($, pending)) ?? []
  const isFound = list.some(item => item.id === id)
  await update($, pending, current => (current ?? []).filter(item => item.id !== id))

  return isFound
}

async function startPending($: EngineInterface, id: number): Promise<boolean> {
  const list: TodoPending[] = (await read($, pending)) ?? []
  const isFound = list.some(item => item.id === id && item.kind === 'task')
  await update($, pending, current =>
    (current ?? []).map(item => (item.id === id && item.kind === 'task' ? { ...item, isActive: true } : item)),
  )

  return isFound
}

function dockColumns(terminalColumns: number): number {
  return Math.max(MIN_COLUMNS, Math.floor(terminalColumns / 4))
}

async function openPane($: EngineInterface, terminalColumns: number) {
  await update($, isAuto, () => false)

  return $.ui.open({ id: PANE, title: TITLE, columns: dockColumns(terminalColumns) })
}

// In-progress work first, then what is still waiting to start.
function sortByStatus(list: readonly TodoTask[]): TodoTask[] {
  return [...list].sort((a, b) => Number(b.status === 'in_progress') - Number(a.status === 'in_progress'))
}

function openTasks(list: readonly TodoTask[]): TodoTask[] {
  return list.filter(task => task.status !== 'completed')
}

export const register: Register = on => {
  // Whether this turn already touched the panel through the model's tools; the Stop reminder reads it.
  let hasRecorded = false

  on('session.start', async ($, e, next) => {
    await $.command.register({
      name: 'todo',
      description: 'Todo 面板：開關面板，或管理待決事項',
      argumentHint: '[add <text> | done <id> | clear]',
    })
    await $.tool.register({
      name: ADD_TOOL,
      description:
        'Adds one item to the todo panel: a decision left for the person, or a step of your own work. Returns its id.',
      inputSchema: {
        type: 'object',
        properties: {
          text: { type: 'string', description: 'The item, under 60 characters' },
          kind: {
            type: 'string',
            enum: ['decision', 'task'],
            description: 'decision: waits on the person (default). task: a step you will do yourself.',
          },
        },
        required: ['text'],
      },
      isDeferred: false,
    })
    await $.tool.register({
      name: RESOLVE_TOOL,
      description: 'Removes an item from the todo panel once it is decided or handled.',
      inputSchema: {
        type: 'object',
        properties: { id: { type: 'number', description: 'The id add_pending returned' } },
        required: ['id'],
      },
      isDeferred: false,
    })
    await $.tool.register({
      name: START_TOOL,
      description: 'Marks a task item on the todo panel as the step you are working on now.',
      inputSchema: {
        type: 'object',
        properties: { id: { type: 'number', description: 'The id add_pending returned' } },
        required: ['id'],
      },
      isDeferred: false,
    })
    if (e.isInteractive) {
      await update($, isAuto, () => true)
      void $.ui.open({ id: PANE, title: TITLE, columns: AUTO_COLUMNS })
    }

    return next(e)
  })

  on('session.end', async ($, e, next) => {
    if (e.reason === 'clear') {
      await update($, tasks, () => [])
      await update($, todos, () => [])
      await update($, pending, () => [])
      await update($, nextId, () => 1)
    }

    return next(e)
  })

  on('turn.start', ($, e, next) => {
    hasRecorded = false

    return next(e)
  })

  // A reply that leaves things open but recorded nothing goes back to the model once.
  on('classic.Stop', async ($, e, next) => {
    const ran = await next(e)
    const isOpen = !hasRecorded && !e.stop_hook_active && looksOpen(e.last_assistant_message ?? '')
    if (ran.block !== undefined || !isOpen) return ran
    hasRecorded = true

    return { ...ran, block: REMINDER }
  })

  on('prompt.compose', async ($, e, next) => {
    const composed = await next(e)

    return {
      sections: [...composed.sections, { id: 'todo-panel:rules', text: RULES, scope: 'session' }],
    }
  })

  on('tool.call', { tool: 'TaskCreate' }, async ($, e, next) => {
    const ran = await next(e)
    if (ran.deny === undefined && ran.isError !== true) {
      const task: TodoTask = { id: ran.result.task.id, subject: e.subject, status: 'pending' }
      await update($, tasks, list => [...(list ?? []), task])
    }

    return ran
  })

  on('tool.call', { tool: 'TaskUpdate' }, async ($, e, next) => {
    const ran = await next(e)
    if (ran.deny === undefined && ran.isError !== true && ran.result.success) {
      await update($, tasks, list =>
        (list ?? []).flatMap(task => {
          if (task.id !== e.taskId) return [task]
          if (e.status === 'deleted') return []

          return [{ ...task, subject: e.subject ?? task.subject, status: e.status ?? task.status }]
        }),
      )
    }

    return ran
  })

  on('tool.call', { tool: 'TodoWrite' }, async ($, e, next) => {
    const ran = await next(e)
    if (ran.deny === undefined && ran.isError !== true) {
      await update($, todos, () =>
        e.todos.map((todo, index) => ({ id: `w${index}`, subject: todo.content, status: todo.status })),
      )
    }

    return ran
  })

  on('tool.call', { tool: /^mcp__todo-panel__add_pending$/ }, async ($, e) => {
    hasRecorded = true
    const input = e as { text?: unknown; kind?: unknown }
    const text = String(input.text ?? '').trim()
    if (text === '') return { deny: 'text is empty' }
    const kind: TodoKind = input.kind === 'task' ? 'task' : 'decision'
    const id = await addPending($, text, kind)

    return { result: `Added to the todo panel as #${id} (${kind}).` }
  })

  on('tool.call', { tool: /^mcp__todo-panel__start_pending$/ }, async ($, e) => {
    hasRecorded = true
    const id = Number((e as { id?: unknown }).id)
    const isFound = await startPending($, id)

    return { result: isFound ? `Marked #${id} as in progress.` : `No task #${id} on the todo panel.` }
  })

  on('tool.call', { tool: /^mcp__todo-panel__resolve_pending$/ }, async ($, e) => {
    hasRecorded = true
    const id = Number((e as { id?: unknown }).id)
    const isFound = await resolvePending($, id)

    return { result: isFound ? `Removed #${id} from the todo panel.` : `No item #${id} on the todo panel.` }
  })

  on('command.run', { command: 'todo' }, async ($, e) => {
    const [verb = '', ...rest] = e.args.trim().split(/\s+/)
    const text = rest.join(' ')

    if (verb === '') {
      const isUp = (await $.ui.panes()).some(pane => pane.id === PANE)
      if (isUp && !(await read($, isAuto))) {
        await $.ui.close({ id: PANE })

        return { text: 'Todo 面板已關閉。' }
      }
      await openPane($, e.presentation.columns)

      return { text: 'Todo 面板已開啟。' }
    }
    if (verb === 'add' && text !== '') {
      const id = await addPending($, text, 'decision')

      return { text: `已加入待決事項 #${id}：${text}` }
    }
    if (verb === 'done' && text !== '') {
      const id = Number(text.replace(/^#/, ''))
      const isFound = await resolvePending($, id)

      return { text: isFound ? `已移除 #${id}。` : `找不到 #${id}。` }
    }
    if (verb === 'clear') {
      await update($, pending, () => [])

      return { text: '已清空 /todo 與 Claude 記錄的事項。' }
    }

    return { text: '用法：/todo [add <text> | done <id> | clear]' }
  })

  on('ui.render', { component: 'Pane', requestId: PANE }, async ($, e) => {
    const { Box, Text } = $.ui.resolve(e)

    // Opened automatically on the main screen: the pane would sit above the prompt, not beside it.
    if (e.props.placement === 'inline' && (await read($, isAuto))) {
      $.ui.close({ id: PANE }).catch(() => undefined)

      return <Box />
    }

    const rows: TodoPending[] = (await read($, pending)) ?? []
    const work = sortByStatus([
      ...openTasks((await read($, tasks)) ?? []),
      ...openTasks((await read($, todos)) ?? []),
      ...rows
        .filter(row => row.kind === 'task')
        .map((row): TodoTask => ({
          id: `#${row.id}`,
          subject: row.text,
          status: row.isActive ? 'in_progress' : 'pending',
        })),
    ])
    const waiting = rows.filter(row => row.kind !== 'task')
    // The body less paddingX on both sides.
    const width = Math.max(8, e.props.bodyColumns - 2)

    // Every Text names a theme colour: an uncoloured one takes the terminal's own foreground,
    // which need not suit the dock the engine paints in the Claude theme.
    if (work.length === 0 && waiting.length === 0) {
      return (
        <Box flexDirection="column" alignItems="center" paddingTop={2}>
          <Text color="success">✓</Text>
          <Text color="inactive">沒有未處理的事項</Text>
        </Box>
      )
    }

    const section = (children: JSX.Element[]) => <Box flexDirection="column">{children}</Box>

    const header = (icon: string, title: string, count: number, color: 'claude' | 'warning') => (
      <Box flexDirection="column">
        <Box justifyContent="space-between">
          <Text color={color} bold>
            {icon} {title}
          </Text>
          <Text color={color}>{count}</Text>
        </Box>
        <Text color="subtle">{'─'.repeat(width)}</Text>
      </Box>
    )

    return (
      <Box flexDirection="column" paddingX={1} paddingTop={1} gap={1}>
        {work.length > 0 && (
          section([
            header('●', '進行中', work.length, 'claude'),
            ...work.map(task => {
              const isActive = task.status === 'in_progress'

              return (
                <Box paddingLeft={1}>
                  <Text color={isActive ? 'claude' : 'subtle'}>{isActive ? '▶ ' : '○ '}</Text>
                  {task.id.startsWith('#') && <Text color="subtle">{`${task.id} `}</Text>}
                  <Text color={isActive ? 'text' : 'inactive'} bold={isActive}>
                    {task.subject}
                  </Text>
                </Box>
              )
            }),
          ])
        )}
        {waiting.length > 0 &&
          section([
            header('◆', '待你決定', waiting.length, 'warning'),
            ...waiting.map(item => (
              <Box paddingLeft={1}>
                <Text color="warning">{`#${item.id}`.padEnd(4)}</Text>
                <Text color="text">{item.text}</Text>
              </Box>
            )),
          ])}
      </Box>
    )
  })

}
