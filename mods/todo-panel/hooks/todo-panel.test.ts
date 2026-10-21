import { expect, test } from 'claude-code/testing'

// The mod's own tools are registered at run time, so the laid tool table does not list them.
const ownTool = <T,>(input: Record<string, unknown>) => input as unknown as T

const SURFACES = ['terminal', 'desktop'] as const

function paneOf(surface: (typeof SURFACES)[number], placement: 'dock' | 'inline') {
  return {
    plugin: 'todo-panel',
    surface,
    component: 'Pane' as const,
    requestId: 'todo-panel',
    props: {
      title: 'Todo',
      isFocused: false,
      bodyColumns: 40,
      placement,
      scroll: { offset: 0, bodyRows: 20 },
      view: {},
    },
    viewport: { columns: 160, rows: 40, isFullscreen: placement === 'dock' },
  }
}

test('Claude 的 task 出現在面板，完成後消失', async ($, on) => {
  on('tool.call', { tool: 'TaskCreate' }, () => ({ result: { task: { id: '1', subject: 'Run tests' } } }))
  on('tool.call', { tool: 'TaskUpdate' }, () => ({
    result: { success: true, taskId: '1', updatedFields: ['status'] },
  }))

  await $.tool.call({ tool: 'TaskCreate', subject: 'Run tests', description: 'run them' })

  for (const surface of SURFACES) {
    const ui = await $.ui.mount(paneOf(surface, 'dock'))
    expect(await ui.find({ type: 'Text', text: 'Run tests' })).toBeDefined()
    await ui.unmount()
  }

  await $.tool.call({ tool: 'TaskUpdate', taskId: '1', status: 'completed' })

  const ui = await $.ui.mount(paneOf('terminal', 'dock'))
  expect(await ui.find({ type: 'Text', text: 'Run tests' })).toBeUndefined()
  expect(await ui.find({ type: 'Text', text: '沒有未處理的事項' })).toBeDefined()
  await ui.unmount()
})

test('TodoWrite 取代整份清單', async ($, on) => {
  on('tool.call', { tool: 'TodoWrite' }, () => ({ result: { oldTodos: [], newTodos: [] } }))

  await $.tool.call({
    tool: 'TodoWrite',
    todos: [
      { content: 'Write code', status: 'in_progress', activeForm: 'Writing code' },
      { content: 'Old step', status: 'completed', activeForm: 'Doing old step' },
    ],
  })

  const ui = await $.ui.mount(paneOf('terminal', 'dock'))
  expect(await ui.find({ type: 'Text', text: 'Write code' })).toBeDefined()
  expect(await ui.find({ type: 'Text', text: 'Old step' })).toBeUndefined()
  await ui.unmount()
})

test('模型記下的待決事項會顯示，resolve 後移除', async $ => {
  const added = await $.tool.call(ownTool<Parameters<typeof $.tool.call>[0]>({ tool: 'mcp__todo-panel__add_pending', text: '要不要順便修 lint 警告' }))
  expect(added.text ?? JSON.stringify(added.result)).toContain('#1')

  const ui = await $.ui.mount(paneOf('terminal', 'dock'))
  expect(await ui.find({ type: 'Text', text: '要不要順便修 lint 警告' })).toBeDefined()
  await ui.unmount()

  await $.tool.call(ownTool<Parameters<typeof $.tool.call>[0]>({ tool: 'mcp__todo-panel__resolve_pending', id: 1 }))

  const after = await $.ui.mount(paneOf('terminal', 'dock'))
  expect(await after.find({ type: 'Text', text: '要不要順便修 lint 警告' })).toBeUndefined()
  await after.unmount()
})

test('自動開啟的面板在非 fullscreen（inline）時不顯示內容', async $ => {
  await $.tool.call(ownTool<Parameters<typeof $.tool.call>[0]>({ tool: 'mcp__todo-panel__add_pending', text: 'hidden item' }))

  const ui = await $.ui.mount(paneOf('terminal', 'inline'))
  expect(await ui.find({ type: 'Text', text: 'hidden item' })).toBeUndefined()
  await ui.unmount()
})

test('Claude 的 task 類項目出現在進行中，start 後標為進行中', async $ => {
  await $.tool.call(ownTool<Parameters<typeof $.tool.call>[0]>({ tool: 'mcp__todo-panel__add_pending', text: '改 render', kind: 'task' }))
  await $.tool.call(ownTool<Parameters<typeof $.tool.call>[0]>({ tool: 'mcp__todo-panel__add_pending', text: '跑測試', kind: 'task' }))
  await $.tool.call(ownTool<Parameters<typeof $.tool.call>[0]>({ tool: 'mcp__todo-panel__start_pending', id: 2 }))

  const ui = await $.ui.mount(paneOf('terminal', 'dock'))
  expect(await ui.find({ type: 'Text', text: '進行中' })).toBeDefined()
  expect(await ui.find({ type: 'Text', text: '待你決定' })).toBeUndefined()
  const rows = await ui.findAll({ type: 'Text', text: /改 render|跑測試/ })
  expect(rows.map(row => row.text)).toEqual(['跑測試', '改 render'])
  await ui.unmount()
})

test('回覆留下問題卻沒記錄時，Stop 會擋一次提醒', async ($, on) => {
  on('classic.Stop', () => ({}))

  const open = await $.classic.Stop({ stop_hook_active: false, last_assistant_message: '要照這樣做嗎？' })
  expect(open.block).toContain('todo-panel')

  const again = await $.classic.Stop({ stop_hook_active: true, last_assistant_message: '要照這樣做嗎？' })
  expect(again.block).toBeUndefined()
})

test('沒有問題或清單的回覆不會被擋', async ($, on) => {
  on('classic.Stop', () => ({}))

  const done = await $.classic.Stop({ stop_hook_active: false, last_assistant_message: '已經修好了。' })
  expect(done.block).toBeUndefined()
})

test('這一輪已經記錄過就不提醒', async ($, on) => {
  on('classic.Stop', () => ({}))

  await $.tool.call(ownTool<Parameters<typeof $.tool.call>[0]>({ tool: 'mcp__todo-panel__add_pending', text: '選方案' }))
  const ran = await $.classic.Stop({ stop_hook_active: false, last_assistant_message: '要選哪個？' })
  expect(ran.block).toBeUndefined()
})

test('只有項目符號說明、沒有問題的回覆不會被擋', async ($, on) => {
  on('classic.Stop', () => ({}))

  const ran = await $.classic.Stop({
    stop_hook_active: false,
    last_assistant_message: '改了這些：\n- 顏色\n- 間距\n- 圖示\n都通過測試。',
  })
  expect(ran.block).toBeUndefined()
})
