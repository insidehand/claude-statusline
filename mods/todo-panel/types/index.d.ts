export type TodoStatus = 'pending' | 'in_progress' | 'completed'

export type TodoTask = { id: string; subject: string; status: TodoStatus }

export type TodoKind = 'decision' | 'task'

// A row the model or /todo add keeps: a decision waits on the person, a task is Claude's own work.
// Rows kept before `kind` existed are decisions.
export type TodoPending = { id: number; text: string; kind?: TodoKind; isActive?: boolean }

declare module 'claude-code' {
  interface PluginState {
    'todo-panel': {
      tasks: TodoTask[]
      todos: TodoTask[]
      pending: TodoPending[]
      nextId: number
      isAuto: boolean
    }
  }
}
