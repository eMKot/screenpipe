-- Temporal validity for memories: facts can expire.
-- Inspired by MemPalace's knowledge graph temporal triples.
-- Enables "what's currently true?" queries via valid_to IS NULL.

ALTER TABLE memories ADD COLUMN valid_from TEXT;
ALTER TABLE memories ADD COLUMN valid_to TEXT;
ALTER TABLE memories ADD COLUMN entity TEXT;

CREATE INDEX IF NOT EXISTS idx_memories_entity ON memories(entity);
CREATE INDEX IF NOT EXISTS idx_memories_valid ON memories(valid_from, valid_to);
