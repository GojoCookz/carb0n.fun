import { expect, test } from 'bun:test'
import { DEFAULT_DRAFT, applySimplePreset, validate } from '../src/lib/launch'
import { TOKEN_SYMBOL_MAX_LENGTH, tokenSymbolProblem } from '../src/lib/tokenSymbol'

for (const mode of ['simple', 'advanced'] as const) {
  for (const symbol of ['MONEROCHAN', 'A'.repeat(TOKEN_SYMBOL_MAX_LENGTH)]) {
    test(`${mode} preserves and accepts ${symbol}`, () => {
      const draft = { ...DEFAULT_DRAFT, mode, symbol }
      const configured = mode === 'simple' ? applySimplePreset(draft) : draft
      expect(configured.symbol).toBe(symbol)
      expect(validate(configured, undefined).filter(issue => issue.field === 'symbol')).toEqual([])
    })
  }
}
test('rejects empty, too short and over-limit saved symbols without truncating', () => {
  for (const symbol of ['', ' ', 'A', 'A'.repeat(17)]) {
    expect(tokenSymbolProblem(symbol)).toBeDefined()
    expect(validate({ ...DEFAULT_DRAFT, symbol }, undefined).some(issue => issue.field === 'symbol')).toBe(true)
  }
})
