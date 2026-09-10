/** App/metadata limit, not an ERC-20 limit. Carbon's Launcher and LaunchToken store strings
 * without a length cap. */
export const TOKEN_SYMBOL_MAX_LENGTH = 16

export function tokenSymbolProblem(symbol: string): string | undefined {
  const value = symbol.trim()
  if (value.length < 2 || value.length > TOKEN_SYMBOL_MAX_LENGTH) {
    return `Use 2–${TOKEN_SYMBOL_MAX_LENGTH} characters for the symbol.`
  }
}
