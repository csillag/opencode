import { describe, expect, test } from "bun:test"
import { getUsage } from "../../src/session/session"

const baseModel: any = {
  id: "claude-sonnet-4",
  providerID: "anthropic",
  api: { id: "claude-sonnet-4", url: "https://api.anthropic.com", npm: "@ai-sdk/anthropic" },
  name: "Claude Sonnet 4",
  capabilities: {},
  // 5m cache_write rate is the catalog's anchor; 1h portion derives 1.6× on top.
  cost: { input: 3, output: 15, cache: { read: 0.3, write: 3.75 } },
  limit: { context: 200_000, output: 8192 },
  status: "active",
  options: {},
  headers: {},
  release_date: "2026-01-01",
}

// AI SDK v6 normalizes `inputTokens` to include cache_read + cache_creation tokens.
// Tests below isolate the cache-write cost path: set inputTokens == cacheCreationInputTokens
// so the "uncached input" subtraction in getUsage lands on 0 and only cache.write cost remains.
const usage = (cacheWriteTotal: number, overrides: Partial<any> = {}) => ({
  inputTokens: cacheWriteTotal,
  outputTokens: 0,
  totalTokens: cacheWriteTotal,
  ...overrides,
})

describe("getUsage cache write cost split", () => {
  test("no cache_creation breakdown -> entire write billed at 5m rate (backward compat)", () => {
    const result = getUsage({
      model: baseModel,
      usage: usage(1_000_000),
      metadata: { anthropic: { cacheCreationInputTokens: 1_000_000 } } as any,
    })
    // Entire 1M tokens at 5m rate ($3.75/M) = $3.75
    expect(result.tokens.cache.write).toBe(1_000_000)
    expect(result.cost).toBeCloseTo(3.75, 6)
  })

  test("cache_creation reports 1h tokens -> 1.6x multiplier applied to 1h portion", () => {
    const result = getUsage({
      model: baseModel,
      usage: usage(1_000_000),
      metadata: {
        anthropic: {
          cacheCreationInputTokens: 1_000_000,
          usage: {
            cache_creation: {
              ephemeral_5m_input_tokens: 400_000,
              ephemeral_1h_input_tokens: 600_000,
            },
          },
        },
      } as any,
    })
    // 5m: 400_000 * $3.75/M = $1.50
    // 1h: 600_000 * $3.75/M * 1.6 = $3.60
    // total: $5.10
    expect(result.tokens.cache.write).toBe(1_000_000)
    expect(result.cost).toBeCloseTo(5.1, 6)
  })

  test("only 1h tokens reported -> entire write billed at 1.6x rate", () => {
    const result = getUsage({
      model: baseModel,
      usage: usage(500_000),
      metadata: {
        anthropic: {
          cacheCreationInputTokens: 500_000,
          usage: {
            cache_creation: {
              ephemeral_5m_input_tokens: 0,
              ephemeral_1h_input_tokens: 500_000,
            },
          },
        },
      } as any,
    })
    // 500_000 * $3.75/M * 1.6 = $3.00
    expect(result.cost).toBeCloseTo(3.0, 6)
  })

  test("only 1h reported, 5m field absent -> 5m derived as total - 1h", () => {
    const result = getUsage({
      model: baseModel,
      usage: usage(1_000_000),
      metadata: {
        anthropic: {
          cacheCreationInputTokens: 1_000_000,
          usage: {
            cache_creation: {
              // 5m field omitted entirely; total - 1h = 700_000 falls back to 5m
              ephemeral_1h_input_tokens: 300_000,
            },
          },
        },
      } as any,
    })
    // 5m: 700_000 * $3.75/M = $2.625
    // 1h: 300_000 * $3.75/M * 1.6 = $1.80
    // total: $4.425
    expect(result.cost).toBeCloseTo(4.425, 6)
  })

  test("vertex provider metadata key also recognized", () => {
    const result = getUsage({
      model: { ...baseModel, providerID: "google-vertex-anthropic" },
      usage: usage(1_000_000),
      metadata: {
        vertex: {
          cacheCreationInputTokens: 1_000_000,
          usage: {
            cache_creation: {
              ephemeral_5m_input_tokens: 0,
              ephemeral_1h_input_tokens: 1_000_000,
            },
          },
        },
      } as any,
    })
    // 1M at 1h rate: $3.75 * 1.6 = $6.00
    expect(result.cost).toBeCloseTo(6.0, 6)
  })
})
