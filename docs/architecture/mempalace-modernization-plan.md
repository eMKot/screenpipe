# Master Plan: MemPalace-Inspired Modernization of Screenpipe

## Context

Screenpipe captures everything on screen and audio 24/7 but its retrieval layer is flat — raw FTS over noisy OCR text and transcription fragments. AI agents via MCP start cold every session and consume thousands of tokens of verbose, unstructured results. MemPalace demonstrated two key innovations: **layered context loading** (170 tokens on wake-up vs. full search) and **structured retrieval** (+34% recall by filtering by topic before searching). This plan adopts those principles natively in Screenpipe's Rust/TypeScript architecture.

The analysis document at `docs/architecture/mempalace-inspired-analysis.md` established what to adopt and what to skip. This plan is the detailed implementation blueprint.

---

## Phase 1: Context Endpoint — Warm MCP Wake-up (P0)

**Goal:** Every MCP session starts with ~200 tokens of structured context instead of a cold search.

### 1.1 New REST endpoint: `GET /context`

**File:** `crates/screenpipe-engine/src/routes/context.rs` (new)

Response shape:
```json
{
  "device": { "name": "MacBook Pro", "recording_since": "2026-04-07T09:00:00Z" },
  "active_apps": [
    { "name": "VS Code", "minutes": 42, "window": "auth.ts — orion" },
    { "name": "Chrome", "minutes": 18, "window": "clerk.com/docs" }
  ],
  "recent_speakers": ["Mykola", "Kai"],
  "active_meeting": null,
  "key_memories": [
    { "content": "decided to use Clerk for auth", "importance": 0.9 }
  ],
  "compact_timeline": [
    "[09:15] vscode:orion/auth.ts — editing route handler",
    "[09:32] chrome:clerk.com/docs — reading middleware docs",
    "[09:45] slack:#orion-dev — discussion about pricing"
  ],
  "generated_at": "2026-04-07T10:00:00Z"
}
```

**Data sources (all existing queries, no new tables):**
- `active_apps`: Same query as `activity_summary.rs` lines 93-108 (app usage from frames), scoped to last 2 hours
- `recent_speakers`: From `audio_transcriptions` joined with `speakers`, last 2 hours
- `active_meeting`: From `meetings` table where `meeting_end IS NULL`
- `key_memories`: From `memories` table, `ORDER BY importance DESC LIMIT 3`
- `compact_timeline`: From `frames` table — distinct `(app_name, window_name)` transitions in last hour, deduplicated, max 10 lines

**Background cache:** Refresh every 5 minutes in a `tokio::spawn` loop (same pattern as the API usage reporter at `server.rs:277-289`). Store result in a `tokio::sync::watch::Sender<Option<ContextResponse>>` on `AppState`.

### 1.2 Register route

**File:** `crates/screenpipe-engine/src/routes/mod.rs` — add `pub mod context;`
**File:** `crates/screenpipe-engine/src/server.rs` — add `.get("/context", get_context)` next to the existing `.get("/activity-summary", get_activity_summary)` at line 507

### 1.3 MCP tool: `get-context`

**File:** `crates/screenpipe-connect/screenpipe-mcp/src/index.ts`

Add new tool to the `TOOLS` array:
```typescript
{
  name: "get-context",
  description: "Get current context: active apps, speakers, meetings, recent memories, compact timeline. ~200 tokens. Call this first.",
  annotations: { title: "Get Context", readOnlyHint: true },
  inputSchema: { type: "object", properties: {} }
}
```

Add handler that calls `GET /context` and returns the JSON as text.

Also upgrade the existing `screenpipe://context` resource (line 221) to call this endpoint instead of just returning timestamps.

### 1.4 MCP manifest update

**File:** `crates/screenpipe-connect/screenpipe-mcp/manifest.json` — add `get-context` to the tools array

**Estimated: ~250 lines Rust + ~30 lines TypeScript**

---

## Phase 2: Activity Sessions — Topic Clustering (P1)

**Goal:** Group captures into topic-based sessions so search can filter by topic, not just time+app.

### 2.1 New migration: `activity_sessions` table

**File:** `crates/screenpipe-db/src/migrations/2026MMDD000000_add_activity_sessions.sql`

```sql
CREATE TABLE IF NOT EXISTS activity_sessions (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    topic TEXT NOT NULL,              -- auto-detected slug: "orion-auth-migration"
    start_time TEXT NOT NULL,         -- ISO 8601
    end_time TEXT,                    -- NULL = ongoing
    apps TEXT NOT NULL DEFAULT '[]',  -- JSON array of app_name values
    windows TEXT NOT NULL DEFAULT '[]', -- JSON array of window_name values
    keywords TEXT NOT NULL DEFAULT '[]', -- extracted topic keywords
    compact_log TEXT NOT NULL DEFAULT '', -- one-line-per-event summary
    frame_count INTEGER DEFAULT 0,
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now'))
);

CREATE INDEX IF NOT EXISTS idx_activity_sessions_time ON activity_sessions(start_time, end_time);
CREATE INDEX IF NOT EXISTS idx_activity_sessions_topic ON activity_sessions(topic);
```

### 2.2 Session detection worker

**File:** `crates/screenpipe-engine/src/activity_sessions.rs` (new)

**Pattern:** Same as `snapshot_compaction.rs` — `tokio::spawn`, shutdown receiver, periodic loop.

**Detection algorithm:**
1. Every 5 minutes, query frames from the last 10 minutes (overlapping window for continuity)
2. Group consecutive frames by `app_name` — a gap >5 minutes or app change starts a new segment
3. Within each segment, extract topic from:
   - `window_name` parsing: "filename — project" patterns (VS Code), tab titles (Chrome)
   - `browser_url` parsing: extract org/repo from GitHub URLs, domain from others
4. Merge segments with same topic within 30 minutes into one session
5. Upsert into `activity_sessions` — extend `end_time` and append to `apps`/`windows`/`compact_log`

**Topic slug generation:**
- Extract project name from window_name patterns: `"auth.ts — orion"` → `"orion"`
- Extract repo from GitHub URLs: `"github.com/acme/orion/pull/42"` → `"orion"`
- Combine app + project: `"vscode-orion"`, `"chrome-clerk-docs"`
- Fallback: just the app name slug

**Compact log generation (Phase 2.5 / P2):**
For each session, generate lines like:
```
[14:32] vscode:orion/auth.ts — editing
[14:35] chrome:clerk.com/docs — reading
[14:40] slack:#orion-dev — messaging
```
Rules:
- One line per distinct `(app_name, window_name)` transition
- Skip consecutive identical entries
- Max 20 lines per session
- Timestamp is `HH:MM`, app is lowercased slug, context is window_name truncated to 40 chars

### 2.3 DB functions

**File:** `crates/screenpipe-db/src/db.rs`

Add functions:
- `upsert_activity_session(topic, start_time, end_time, apps, windows, keywords, compact_log, frame_count)`
- `list_activity_sessions(start_time, end_time, topic_filter, limit, offset)`
- `get_session_by_id(id)`

### 2.4 Spawn worker from main

**File:** `crates/screenpipe-engine/src/bin/screenpipe-engine.rs`

Add next to the `start_snapshot_compaction` call (~line 610):
```rust
screenpipe_engine::start_activity_sessions(
    db.clone(),
    shutdown_tx.subscribe(),
);
```

**File:** `crates/screenpipe-engine/src/lib.rs` — add `pub mod activity_sessions;` and re-export `start_activity_sessions`

**Estimated: ~400 lines Rust + migration**

---

## Phase 3: Temporal Memories (P3)

**Goal:** Memories can expire. "What's currently true?" becomes queryable.

### 3.1 Migration

**File:** `crates/screenpipe-db/src/migrations/2026MMDD000001_add_temporal_memories.sql`

```sql
ALTER TABLE memories ADD COLUMN valid_from TEXT;
ALTER TABLE memories ADD COLUMN valid_to TEXT;
ALTER TABLE memories ADD COLUMN entity TEXT;  -- person/project this relates to
CREATE INDEX IF NOT EXISTS idx_memories_entity ON memories(entity);
CREATE INDEX IF NOT EXISTS idx_memories_valid ON memories(valid_from, valid_to);
```

### 3.2 Update DB functions

**File:** `crates/screenpipe-db/src/db.rs`

- `insert_memory`: Add `valid_from`, `valid_to`, `entity` parameters (all optional, backward compatible)
- `list_memories`: Add `entity` filter and `current_only` boolean (where `valid_to IS NULL`)
- `update_memory`: Add ability to set `valid_to` (invalidation)

### 3.3 Update types

**File:** `crates/screenpipe-db/src/types.rs`

Add fields to `MemoryRecord`:
```rust
pub valid_from: Option<String>,
pub valid_to: Option<String>,
pub entity: Option<String>,
```

### 3.4 Update REST endpoints

**File:** `crates/screenpipe-engine/src/routes/memories.rs`

- `CreateMemoryRequest`: Add optional `valid_from`, `valid_to`, `entity`
- `ListMemoriesQuery`: Add optional `entity`, `current_only`
- `UpdateMemoryRequest`: Add optional `valid_to`, `entity`
- `MemoryResponse`: Add the three new fields

### 3.5 Update MCP tool

**File:** `crates/screenpipe-connect/screenpipe-mcp/src/index.ts`

Update `update-memory` tool schema to include `valid_from`, `valid_to`, `entity`, and `invalidate` (boolean to set valid_to=now).

**Estimated: ~120 lines Rust + migration + ~20 lines TypeScript**

---

## Phase 4: Topic-Filtered Search (P4)

**Goal:** Search within a topic/session for +30% retrieval improvement.

### 4.1 Add topic filter to search

**File:** `crates/screenpipe-engine/src/routes/search.rs`

Add to `SearchQuery`:
```rust
#[serde(default)]
topic: Option<String>,
#[serde(default)]
session_id: Option<i64>,
```

When `topic` or `session_id` is provided:
1. Look up the session's `start_time`, `end_time`, and `apps` from `activity_sessions`
2. Inject these as pre-filters into the existing search: time range + app_name IN (...)
3. Existing FTS then runs within this narrowed scope

### 4.2 Add sessions list endpoint

**File:** `crates/screenpipe-engine/src/routes/context.rs` (extend)

Add `GET /sessions` endpoint:
```json
{
  "data": [
    { "id": 42, "topic": "orion-auth", "start_time": "...", "end_time": "...", "apps": ["VS Code", "Chrome"], "frame_count": 87 }
  ],
  "pagination": { ... }
}
```

### 4.3 MCP tool: `list-sessions`

**File:** `crates/screenpipe-connect/screenpipe-mcp/src/index.ts`

New tool:
```typescript
{
  name: "list-sessions",
  description: "List activity sessions (topic clusters). Use to find which topics to search within.",
  inputSchema: {
    type: "object",
    properties: {
      start_time: { type: "string" },
      end_time: { type: "string" },
      topic: { type: "string", description: "Filter by topic keyword" },
      limit: { type: "integer", default: 20 }
    }
  }
}
```

Update `search-content` tool schema to add `topic` and `session_id` parameters.

**Estimated: ~150 lines Rust + ~40 lines TypeScript**

---

## Phase 5: Integration — Context Endpoint Uses Sessions (P0 + P1 combined)

**Goal:** The `/context` endpoint returns session-aware information once P1 is live.

Upgrade the context worker (from Phase 1) to:
1. Include the 3 most recent activity sessions in the response
2. Use session topics in the `compact_timeline` instead of raw app+window
3. Link key_memories to their entity/session if available

This is not a new component — it's an enhancement to the Phase 1 context worker once Phase 2 data is available. The context endpoint degrades gracefully: if no sessions exist yet, it falls back to the raw activity_summary style.

**Estimated: ~50 lines Rust (modify existing context worker)**

---

## Implementation Order

```
Phase 1  (P0):  Context endpoint + MCP tool         ~250 LOC Rust, ~30 LOC TS
Phase 2  (P1):  Activity sessions worker + table     ~400 LOC Rust
Phase 3  (P3):  Temporal memories                    ~120 LOC Rust, ~20 LOC TS
Phase 4  (P4):  Topic-filtered search + sessions API ~150 LOC Rust, ~40 LOC TS
Phase 5  (P0+P1): Context uses sessions              ~50 LOC Rust
                                                     ─────────────────────────
Total:                                               ~970 LOC Rust, ~90 LOC TS
```

Each phase is independently shippable and testable. Phase 5 is just a refinement pass.

---

## Files Modified/Created Summary

### New files
| File | Phase |
|------|-------|
| `crates/screenpipe-engine/src/routes/context.rs` | 1 |
| `crates/screenpipe-engine/src/activity_sessions.rs` | 2 |
| `crates/screenpipe-db/src/migrations/2026MMDD_add_activity_sessions.sql` | 2 |
| `crates/screenpipe-db/src/migrations/2026MMDD_add_temporal_memories.sql` | 3 |

### Modified files
| File | Phase | What changes |
|------|-------|-------------|
| `crates/screenpipe-engine/src/routes/mod.rs` | 1 | Add `pub mod context;` |
| `crates/screenpipe-engine/src/server.rs` | 1, 4 | Register `/context` and `/sessions` routes, add `context_cache` to AppState |
| `crates/screenpipe-engine/src/lib.rs` | 2 | Add `pub mod activity_sessions;`, re-export `start_activity_sessions` |
| `crates/screenpipe-engine/src/bin/screenpipe-engine.rs` | 2 | Spawn activity sessions worker |
| `crates/screenpipe-db/src/db.rs` | 2, 3 | Add session CRUD + update memory functions |
| `crates/screenpipe-db/src/types.rs` | 3 | Add fields to `MemoryRecord` |
| `crates/screenpipe-engine/src/routes/memories.rs` | 3 | Update request/response types |
| `crates/screenpipe-engine/src/routes/search.rs` | 4 | Add `topic`/`session_id` parameters |
| `crates/screenpipe-connect/screenpipe-mcp/src/index.ts` | 1, 3, 4 | Add `get-context`, `list-sessions` tools, update `update-memory` and `search-content` |
| `crates/screenpipe-connect/screenpipe-mcp/manifest.json` | 1, 4 | Add new tools |

### Patterns reused from existing code
- **Background worker:** `snapshot_compaction.rs` pattern (tokio::spawn + shutdown_rx + periodic loop)
- **Route registration:** Same as `activity_summary` at `server.rs:507`
- **DB queries:** Raw SQL via `execute_raw_sql` (same as activity_summary) for reads, typed queries for writes
- **AppState caching:** Same watch channel pattern as metrics reporters at `server.rs:277`
- **MCP tool registration:** Same pattern as existing tools in `index.ts:48-196`
- **Migration:** Same directory and naming convention as `20260315000000_add_frame_id_to_memories.sql`

---

## Verification

### Phase 1
```bash
# Start screenpipe, wait 2+ minutes for context cache to populate
curl http://localhost:3030/context | jq .
# Should return device info, active_apps, compact_timeline

# Test via MCP
claude mcp add screenpipe -- npx screenpipe-mcp
# Ask Claude: "what am I working on?" — should call get-context first
```

### Phase 2
```bash
# After running for 30+ minutes with app switches
curl 'http://localhost:3030/sessions?start_time=2h+ago&end_time=now' | jq .
# Should return activity sessions with topics

# Check compact logs
curl 'http://localhost:3030/sessions?start_time=2h+ago&end_time=now' | jq '.[0].compact_log'
```

### Phase 3
```bash
# Create a temporal memory
curl -X POST http://localhost:3030/memories -H 'Content-Type: application/json' \
  -d '{"content":"using Clerk for auth","entity":"orion","valid_from":"2026-04-07","importance":0.9}'

# Query current memories
curl 'http://localhost:3030/memories?current_only=true&entity=orion' | jq .
```

### Phase 4
```bash
# Search within a topic
curl 'http://localhost:3030/search?q=pricing&topic=orion-auth&content_type=all' | jq .
# Should return only results from the orion-auth session time/app window
```

### Rust tests
```bash
cargo test -p screenpipe-db    # migration + CRUD tests
cargo test -p screenpipe-engine # context + sessions tests
```
