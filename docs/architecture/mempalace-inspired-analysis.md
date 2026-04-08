# Architecture Analysis: MemPalace-Inspired Improvements for Screenpipe

> Baseline branch: `architecture/mempalace-inspired-analysis` (from `d60c14154`)
> Date: 2026-04-07
> Status: Analysis only. No code changes.

---

## 1. Executive Summary

MemPalace is a local AI memory system that organizes conversation exports and project files into a structured, searchable "palace" with wings (domains), rooms (topics), halls (memory types), and drawers (verbatim content). It achieves 96.6% recall on LongMemEval with zero API calls, primarily through two innovations:

1. **Structured retrieval** — filtering by domain/topic before searching (34% recall improvement over flat search)
2. **Layered context loading** — a 4-tier memory stack that delivers ~170 tokens on wake-up instead of searching everything

This analysis evaluates which MemPalace concepts address real gaps in Screenpipe and proposes concrete adoption paths within the existing Rust/TypeScript architecture.

---

## 2. Current State: What Screenpipe Has Today

### 2.1 Data Model (screenpipe-db)

| Table | What it stores |
|-------|---------------|
| `frames` | Screenshot metadata: timestamp, app_name, window_name, browser_url, focused, file_path |
| `ocr_text` | OCR text per frame per window, with text_json (bounding boxes) |
| `audio_chunks` | Raw audio file references with timestamps |
| `audio_transcriptions` | Speech-to-text results: text, engine, speaker_id, timestamps |
| `speakers` | Speaker identity: name, embeddings |
| `meetings` | Detected meetings: app, title, attendees, start/end |
| `memories` | Persistent facts: content, source, tags, importance, frame_id |
| `ui_events` | Keyboard/mouse/clipboard events |
| `elements` | Accessibility tree elements per frame |

**Key observation:** The data model is rich and well-structured for *capture*. Every record has a timestamp, device, and app context. But there is no **topic/project grouping** across these tables. A search for "auth migration" returns timestamped results from different apps with no semantic connection between them.

### 2.2 Search (screenpipe-engine/routes/search.rs)

The `/search` endpoint supports:
- Full-text search via SQLite FTS on OCR text and audio transcriptions
- Filters: time range, app_name, window_name, content_type, speaker, focused, browser_url
- Pagination with limit/offset
- Optional `max_content_length` truncation
- Optional cloud search

**What it returns:** Raw `SearchResult` variants — `OCR(OCRResult)`, `Audio(AudioResult)`, `UI(UiContent)`, `Input(UiEventRecord)`, `Memory(MemoryRecord)`. Each variant contains full verbatim text, file paths, timestamps, and metadata.

**Gap:** No summarization, no topic grouping, no relevance ranking beyond FTS. A search returns chronologically ordered raw captures. An AI agent processing these results consumes thousands of tokens of noisy OCR text and transcription fragments.

### 2.3 Activity Summary (screenpipe-engine/routes/activity_summary.rs)

The `/activity-summary` endpoint is the closest thing to MemPalace's layered loading:
- Returns app usage (frame count, minutes), recent texts, audio summary
- Scoped to a time range
- ~200-500 tokens output

**Gap:** This is a time-based activity log, not a semantic summary. It answers "what apps did I use?" not "what am I working on?" or "what decisions did I make today?"

### 2.4 Memories (screenpipe-engine/routes/memories.rs)

CRUD for persistent facts with:
- Free-text content
- Source provenance (user, pipe, system)
- Tags (JSON array)
- Importance score (0.0-1.0)
- Optional frame_id link

**Gap:** Memories are a flat key-value store. No hierarchy, no relationship between memories, no temporal validity ("this was true from X to Y"), no automatic extraction from captures.

### 2.5 Snapshot Compaction (screenpipe-engine/snapshot_compaction.rs)

Compresses JPEG snapshots into H.265 MP4 chunks (10-30x compression). This is **media compaction**, not semantic compaction. It reduces storage, not context window usage.

### 2.6 MCP Integration (cli/mcp.rs)

Downloads and runs a Python-based MCP server (`screenpipe-mcp` via uv). The MCP server wraps the HTTP API — when Claude calls a tool, it hits the REST endpoints and returns raw results.

**Gap:** No wake-up protocol, no tiered loading, no context compression. Every MCP interaction starts cold and returns verbose raw data.

---

## 3. MemPalace Concepts: Applicability Assessment

### 3.1 Layered Context Loading (L0-L3)

**MemPalace implementation:**
- L0: Identity (~50 tokens) — "Who am I?" from identity.txt
- L1: Critical facts (~120 tokens) — Auto-generated top moments from palace
- L2: On-demand — Retrieved when a topic comes up
- L3: Deep search — Full semantic search

**Applicability to Screenpipe: HIGH**

Screenpipe has all the raw data to build this but no tiering. The mapping:

| Layer | Screenpipe Source | What it would contain | Token budget |
|-------|------------------|----------------------|-------------|
| L0 | User config + device info | "Recording on MacBook Pro. Apps: VS Code, Chrome, Slack, Terminal. Speaker: Mykola." | ~50 |
| L1 | Activity summary + memories | "Today: 3.2h VS Code (orion/src), 1.1h Chrome (clerk docs, github PRs), 45min Slack. Key: decided to use Clerk for auth (importance: 0.9)." | ~150 |
| L2 | Filtered search by app/topic | When agent sees "auth" in conversation, pull relevant OCR + audio for that topic | ~500 |
| L3 | Full `/search` | Current behavior | unlimited |

**Proposed endpoint:** `GET /context` — returns pre-computed L0+L1 in a single compact response. Updated every 5 minutes by a background worker.

**Impact:** Every MCP session starts with ~200 tokens of context instead of a cold search. The agent knows what the user is working on before asking.

### 3.2 Topic Clustering / Rooms

**MemPalace implementation:**
- Rooms are named ideas: "auth-migration", "graphql-switch", "ci-pipeline"
- Files are routed to rooms by keyword scoring
- Same room in multiple wings creates a "tunnel" (cross-domain link)
- Searching within a room yields +34% recall over flat search

**Applicability to Screenpipe: MEDIUM-HIGH**

Screenpipe already has implicit topic signals that are not exploited:
- `app_name` + `window_name` — "VS Code - auth.ts - orion" tells you the project and file
- `browser_url` — "github.com/acme/orion/pull/42" tells you the project and PR
- Audio transcriptions mention project names, people, decisions
- App switches within a 5-minute window suggest task context

**Proposed approach:** A background worker that clusters recent captures into "activity sessions" (topic + time window):

```
Session: "orion-auth-migration" (14:20-15:45)
  - VS Code: auth.ts, middleware.ts, clerk-config.ts
  - Chrome: clerk.com/docs, github.com/acme/orion/pull/42
  - Slack: #orion-dev (3 messages about Clerk pricing)
  - Terminal: npm test (auth suite)
```

**Implementation:** New table `activity_sessions` with:
- `id`, `topic` (auto-detected slug), `start_time`, `end_time`
- `apps` (JSON array of app_name values)
- `keywords` (extracted from OCR + transcriptions)
- `summary` (compact text, ~50 tokens)

Search could then filter by session/topic, not just by time+app. This is MemPalace's "room" concept without the metaphor.

### 3.3 AAAK-Style Compression

**MemPalace implementation:**
- Entity codes (Alice → ALC), emotion markers, pipe-separated fields
- ~30x compression, readable by any LLM without a decoder
- Used for L1 wake-up context and closet summaries

**Applicability to Screenpipe: MEDIUM**

The principle is sound: raw OCR text is extremely wasteful in context windows. A VS Code screenshot OCR might be 2000 tokens, but the useful information is:

```
Raw OCR:  "1 | use axum::{routing::get, serve, Router}; 2 | use oasgen::Server; ..."
          (2000 tokens of every visible line)

Compressed: "VS Code|auth.ts|orion|editing axum route handler|14:32"
            (12 tokens)
```

**However:** AAAK's specific format (entity codes, emotion markers) is designed for personal journals, not screen captures. Screenpipe needs a different compression scheme:

```
[14:32] vscode:orion/auth.ts — editing axum routes
[14:35] chrome:clerk.com/docs/middleware — reading auth middleware docs
[14:40] slack:#orion-dev — "kai: pricing looks good, let's go with clerk"
[14:42] vscode:orion/clerk-config.ts — new file, implementing clerk setup
```

This is a time-ordered activity log, not a symbolic dialect. Each line: timestamp, app:context, action/content summary. Achievable with existing OCR + transcription data, no LLM needed for the common case (app_name + window_name + first line of OCR change).

**Proposed implementation:** Add a `compact_summary` field to the activity session table. Generated by a Rust function, not an LLM. For the MCP `/context` endpoint.

### 3.4 Knowledge Graph with Temporal Validity

**MemPalace implementation:**
- SQLite-backed entity-relationship triples
- Subject → predicate → object with valid_from/valid_to
- Invalidation when facts change
- Point-in-time queries

**Applicability to Screenpipe: LOW-MEDIUM**

Screenpipe's `memories` table already stores persistent facts. Adding a full knowledge graph would require:
1. Entity extraction from OCR + transcriptions (needs LLM or NER)
2. Relationship inference (needs LLM)
3. Temporal validity tracking
4. Contradiction detection

This is high effort for uncertain payoff at Screenpipe's data volume. The `memories` table with tags and importance already serves the "store facts" use case. The missing piece is **automatic extraction**, not the storage schema.

**Recommendation:** Don't build a KG. Instead, enhance `memories` with:
- `valid_from` / `valid_to` timestamps (temporal validity)
- `entity` field (person/project name this memory relates to)
- A background pipe that extracts memories from high-signal captures (meeting transcriptions, clipboard content with decisions)

### 3.5 Contradiction Detection

**MemPalace implementation:**
- Checks new facts against existing knowledge graph
- Flags attribution conflicts, wrong dates, stale data

**Applicability to Screenpipe: LOW (for now)**

Requires a populated knowledge graph to check against. Premature without 3.4. Could be valuable later as a pipe that validates memories before storing them.

### 3.6 Specialist Agents / Diary

**MemPalace implementation:**
- Agents with focus areas (reviewer, architect, ops)
- Each agent has its own wing and AAAK diary
- Agents accumulate expertise in their domain

**Applicability to Screenpipe: ALREADY EXISTS (as Pipes)**

Screenpipe's pipe system already enables this. A pipe can watch specific events, maintain state, and act on patterns. The diary concept maps to a pipe that writes memories scoped to its domain. No new infrastructure needed — just well-crafted pipes.

---

## 4. Proposed Changes: Priority Order

### P0: Context Endpoint (L0+L1 wake-up)

**What:** New `GET /context` endpoint returning a compact JSON summary of current state.
**Where:** `crates/screenpipe-engine/src/routes/` (new file `context.rs`)
**Data sources:** Existing `activity_summary` query + `memories` table + device info
**Background worker:** Refresh every 5 minutes, cache in AppState
**Token budget:** ~200 tokens
**Effort:** ~200 lines of Rust
**Impact:** Every MCP session starts informed instead of cold

### P1: Activity Sessions (Topic Clustering)

**What:** Background worker that groups captures into topic-based sessions.
**Where:** New `crates/screenpipe-engine/src/activity_sessions.rs` + migration for `activity_sessions` table
**Detection heuristic:**
  - New session on app_name change with >5 min gap
  - Merge consecutive windows in same app
  - Extract topic from window_name + browser_url patterns (e.g., "github.com/{org}/{repo}" → repo name)
  - Keyword extraction from OCR delta (what changed, not full text)
**Effort:** ~500 lines of Rust + migration
**Impact:** Enables topic-filtered search, powers the L1 summary

### P2: Compact Activity Log (Compression for Context Windows)

**What:** Generate a one-line-per-event compact log for each activity session.
**Where:** Part of the activity sessions worker
**Format:** `[HH:MM] app:context — action` per meaningful event
**Rules:**
  - Skip consecutive identical app+window (deduplicate)
  - Prefer window_name over OCR text (shorter, cleaner)
  - Include audio transcription snippets only for meeting segments
  - Cap at 20 lines per session
**Effort:** ~150 lines of Rust (formatting logic)
**Impact:** 10-50x reduction in tokens for MCP search results

### P3: Temporal Validity for Memories

**What:** Add `valid_from`, `valid_to`, `entity` columns to `memories` table.
**Where:** New migration + update to memories CRUD endpoints
**Effort:** ~100 lines + migration
**Impact:** Enables "what's currently true?" queries, prevents stale facts

### P4: Topic-Filtered Search

**What:** Add `session_id` or `topic` parameter to `/search` endpoint.
**Where:** `crates/screenpipe-engine/src/routes/search.rs` + `crates/screenpipe-db/src/db.rs`
**Effort:** ~100 lines
**Impact:** MemPalace's +34% retrieval improvement, achieved by pre-filtering by topic before FTS

---

## 5. What NOT to Adopt

| MemPalace Feature | Why not |
|---|---|
| ChromaDB / vector embeddings | Screenpipe already has sqlite-vec. Adding a second vector DB is redundant overhead. |
| Palace metaphor (wings/halls/closets/drawers) | Marketing abstraction, not a data model. Screenpipe's richer schema (frames, OCR, audio, UI events) would lose information forced into this hierarchy. |
| AAAK dialect format | Designed for personal journals with emotional markers. Screen captures need a different compression format (time-ordered activity logs). The *principle* of compression is adopted in P2, but not the specific format. |
| Full knowledge graph | High implementation cost, requires LLM for entity extraction at Screenpipe's data volume. The lighter `memories` enhancement (P3) gets 80% of the value at 10% of the cost. |
| Batch mining pipeline | Screenpipe captures continuously. A batch `mine` command is architecturally incompatible. |
| Onboarding wizard | Screenpipe already has onboarding. The entity detection flow is specific to MemPalace's text-mining use case. |

---

## 6. Architecture Diagram: Before and After

### Before (current)

```
Capture → DB → /search (raw FTS) → AI agent (cold start, verbose results)
```

### After (with P0-P4)

```
Capture → DB ──→ Activity Sessions worker (P1)
                    ├── topic clustering
                    ├── compact log generation (P2)
                    └── L1 summary refresh (P0)

AI agent ──→ /context (P0)        → 200 tokens, knows user's world
         ──→ /search?topic= (P4)  → topic-filtered, compact results
         ──→ /search (current)    → full raw results when needed (L3)
         ──→ /memories (P3)       → temporal facts with validity windows
```

---

## 7. Metrics: How to Measure Success

| Metric | Current baseline | Target | How to measure |
|--------|-----------------|--------|---------------|
| Tokens per MCP wake-up | ~0 (cold start) or ~2000 (first search) | ~200 (L0+L1 context) | Count tokens in /context response |
| Tokens per search result | ~500-2000 per item (raw OCR) | ~50-100 per item (compact log) | Average content_length in search responses |
| Search recall with topic filter | N/A (no topic filter) | +30% over flat search | Benchmark with labeled query set |
| MCP response usefulness | Qualitative | Agent gives correct answers with fewer tool calls | Track tool_call count per user question |

---

## 8. Implementation Sequence

```
Week 1: P0 (context endpoint) + P3 (temporal memories migration)
         These are independent, small, and immediately useful.

Week 2: P1 (activity sessions worker)
         The core clustering logic. Can ship without P2/P4.

Week 3: P2 (compact log) + P4 (topic-filtered search)
         These depend on P1's session data being populated.
```

Each change is independently useful and shippable. No change depends on all others being complete.

---

## 9. Risk Assessment

| Risk | Likelihood | Mitigation |
|------|-----------|------------|
| Activity session detection is noisy | Medium | Start with conservative heuristics (app+window change only). Refine with user feedback. |
| Context endpoint becomes stale | Low | 5-minute refresh + on-demand regeneration when capture events fire |
| Compact log loses important detail | Medium | Always link back to raw data. Compact log is a summary, not a replacement. |
| Performance impact of background workers | Low | Activity sessions worker processes in batches, runs on idle. Similar pattern to existing snapshot compaction. |
| Scope creep toward full KG | Medium | Explicitly defer KG to post-P4 evaluation. The memories enhancement (P3) is the ceiling for now. |

---

## 10. References

- MemPalace source: `/Users/mykola/Documents/Cursor/mempalace/`
- MemPalace benchmarks: 96.6% R@5 LongMemEval, +34% from palace structure
- Screenpipe activity_summary.rs: existing compact summary (~200-500 tokens)
- Screenpipe memories: flat CRUD, no temporal validity
- Screenpipe snapshot_compaction: media compaction pattern (reusable for semantic compaction scheduling)
