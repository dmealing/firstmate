/** Why the session waits on the person, and for which tool. */
export type FirstmateHerdrBlock = {
  kind: 'question' | 'permission'
  tool: string
}

/** The main loop's turn as the mod last saw it; kept across a hot reload of the module. */
export type FirstmateHerdrTurn = {
  running: boolean
  blocked: FirstmateHerdrBlock | null
}

declare module 'claude-code' {
  interface PluginState {
    'firstmate-herdr-state': { turn: FirstmateHerdrTurn }
  }
}
