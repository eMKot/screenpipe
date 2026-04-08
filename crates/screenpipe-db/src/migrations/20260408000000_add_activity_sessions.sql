-- Activity sessions: topic-based grouping of captures across apps.
-- Inspired by MemPalace "rooms" — each session clusters related captures
-- (e.g., "orion-auth" groups VS Code edits + Chrome docs + Slack discussions).

CREATE TABLE IF NOT EXISTS activity_sessions (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    topic TEXT NOT NULL,
    start_time TEXT NOT NULL,
    end_time TEXT,
    apps TEXT NOT NULL DEFAULT '[]',
    windows TEXT NOT NULL DEFAULT '[]',
    keywords TEXT NOT NULL DEFAULT '[]',
    compact_log TEXT NOT NULL DEFAULT '',
    frame_count INTEGER DEFAULT 0,
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now'))
);

CREATE INDEX IF NOT EXISTS idx_activity_sessions_time ON activity_sessions(start_time, end_time);
CREATE INDEX IF NOT EXISTS idx_activity_sessions_topic ON activity_sessions(topic);
