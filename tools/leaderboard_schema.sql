-- Schema for the global leaderboard.
--
-- Run this once in the Supabase SQL editor (Dashboard → SQL Editor → New
-- query → paste → Run).
--
-- The security model matters here. The anon key ships inside the game and is
-- therefore public: anyone can read it out of the bundle. Row Level Security
-- is what stops that key from being able to do anything harmful — insert and
-- read only, never update or delete. Constraints below reject values the game
-- could not legitimately produce, which raises the cost of casual forgery
-- without pretending to be real anti-cheat.

create table if not exists public.scores (
  id          bigint generated always as identity primary key,
  name        text        not null,
  time        real        not null,
  level       integer     not null,
  kills       integer     not null,
  generation  integer     not null,
  created_at  timestamptz not null default now(),

  -- Bounds a legitimate run cannot exceed. A rejected insert is silent from
  -- the game's point of view, which is the right outcome for a bad score.
  constraint name_length      check (char_length(name) between 1 and 16),
  constraint time_sane        check (time  >= 0 and time  <= 60 * 60 * 6),
  constraint level_sane       check (level between 1 and 500),
  constraint kills_sane       check (kills between 0 and 500000),
  constraint generation_sane  check (generation between 0 and 200)
);

-- The board is always read ordered by time; without this every fetch is a
-- full scan once the table grows.
create index if not exists scores_time_idx on public.scores (time desc);

alter table public.scores enable row level security;

-- Anyone may read the board.
drop policy if exists "read scores" on public.scores;
create policy "read scores"
  on public.scores for select
  to anon, authenticated
  using (true);

-- Anyone may post a run. Note there is deliberately no update or delete
-- policy: with RLS enabled and no policy, those operations are denied, so a
-- leaked anon key cannot be used to rewrite or wipe the board.
drop policy if exists "insert scores" on public.scores;
create policy "insert scores"
  on public.scores for insert
  to anon, authenticated
  with check (true);
