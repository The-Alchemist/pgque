# BETTER_DOCS.md — design doc for PgQue documentation

Status: draft, design doc only. No documentation files have been written from
this plan yet. Implementation lands in follow-up PRs.

## Purpose

Define what PgQue documentation should look like end-to-end: what stays in
`README.md`, what moves into a new `docs/` tree, how the tree is organized, and
what each file is for. The goal is that a new user can land on the README,
understand whether PgQue fits their problem within two minutes, and then follow
clear paths into deeper material — without the README itself trying to be a
tutorial, a reference, and an explainer all at once.

This document is the design. The actual `docs/` files are written in follow-up
work, in the order set out in section 8.

## 1. Research base

The plan below is grounded in:

- **PgQ** ([github.com/pgq/pgq](https://github.com/pgq/pgq)) — source code,
  inline comments, regression tests, README, and the full commit history
  (~80 commits, 2016–2025). PgQ is the engine PgQue inherits.
- **PgQue** — current `README.md`, `sql/pgque.sql`, experimental SQL,
  `tests/`, `blueprints/SPECx.md`, `blueprints/PHASES.md`, and the project's
  commit history (including the recent `xid8` fix and the ticker-requirement
  clarification in `02f649d`).
- **Diátaxis** ([documentation.divio.com](https://documentation.divio.com/)) —
  four-quadrant model: tutorials, how-to guides, reference, explanation.
- **Kreen & Pihlak, PgCon 2009** — "PgQ: generic queue for PostgreSQL"
  ([slides](https://www.pgcon.org/2009/schedule/attachments/91_pgq.pdf),
  [event](https://www.pgcon.org/2009/schedule/events/138.en.html)). The
  canonical vocabulary (event, batch, tick, producer, consumer, ticker)
  and the ticker rule come from this talk. See section 9. PR #54
  (`claude/extract-pgq-docs-EUM1D`) lands this material as
  `docs/pgq-concepts.md` and `docs/pgq-history.md`; section 9 treats it
  as the project-wide glossary and binds it to the rest of this plan.
- **postgres-ai shared rules**
  ([gitlab.com/postgres-ai/rules](https://gitlab.com/postgres-ai/rules/-/tree/main/rules))
  — referenced from `CLAUDE.md`. The writing rules in particular shape tone,
  terminology, and platform-neutrality across every doc.

## 2. What end users most need to understand

These are ordered by how much pain a user feels when they miss them. They are
the *content priorities*, independent of which file a given piece ends up in.

### Tier 1 — users will fail without this

1. **The mental model.** PgQue is a snapshot-based shared event log with
   per-consumer position tracking. It is not `SKIP LOCKED`, not row-claiming,
   not pgmq-style. Events become visible in batches between ticks, not
   individually. Latency is seconds by design. Fan-out is native — multiple
   consumers each track their own position in the same log; events are not
   duplicated per consumer.
2. **The ticker.** Without ticking, no events are ever visible to consumers.
   This is the single largest source of "it is not working" reports for any
   PgQ-derived system. The README already calls this out (added in
   `02f649d`); the broader docs need to keep reinforcing it. Two ticking
   modes: `pgque.start()` with `pg_cron`, or manual `pgque.ticker()` from an
   external scheduler. Tuning knobs: `ticker_max_lag` (3s),
   `ticker_max_count` (500), `ticker_idle_period` (1m).
3. **The consumer loop.** `receive` returns the current batch. If `ack` is
   not called, the same batch is returned forever. Correct loop:
   `receive` → process → `ack` (or `nack` per event) → repeat. `receive`
   returns empty when no batch is ready; sleep and retry.
4. **The happy path.** Six lines that produce visible output:
   `create_queue` → `subscribe` → `send` → `force_tick` + `ticker` →
   `receive` → `ack`.

### Tier 2 — users will hit this within the first week

5. **Maintenance shape.** Three separate operations, each on its own cadence:
   ticker (~2s), `maint` (~30s), rotate-step-2 (~10s). Step 1 and step 2 of
   rotation must run in separate transactions — combining them defeats the
   global-visibility safety mechanism and event tables grow without bound.
   `pgque.start()` configures all three when `pg_cron` is available;
   otherwise the user runs them.
6. **Retry mechanics.** `nack(batch_id, msg, '60 seconds')` schedules retry.
   `retry_count` increments per attempt. After `max_retries` (default 5),
   the message routes to the dead letter queue. Retries depend on `maint`
   running.
7. **Message shape.** Fields users see on `pgque.message`: `msg_id`,
   `batch_id`, `type`, `payload`, `retry_count` (NULL on first delivery),
   `created_at`, and four `extra` text columns.
8. **Three-table rotation — why bloat is zero.** Each queue has three
   inheritance child tables. Inserts go to the hot table. The oldest is
   `TRUNCATE`d after every consumer has passed it. A consumer that stops
   consuming blocks rotation, and tables grow. Monitor consumer lag.
9. **Exactly-once pattern.** Wrap `receive` + business writes + `ack` in one
   transaction. Rollback rolls back all three atomically. This is the
   property that external brokers structurally cannot offer.

### Tier 3 — users will need this in production

10. **Configuration reference.** Per-queue: `ticker_max_count`,
    `ticker_max_lag`, `ticker_idle_period`, `rotation_period`, `max_retries`,
    `ticker_paused`, `external_ticker`. Set via
    `pgque.set_queue_config(queue, key, value)`.
11. **Monitoring.** `pgque.status()`, `pgque.get_queue_info()`,
    `pgque.get_consumer_info()`. What each column means. What to alert on:
    ticker lag, consumer lag, stuck consumers, DLQ depth.
12. **Roles.** `pgque_reader`, `pgque_writer`, `pgque_admin`. What each can
    do. Uninstall requires superuser by design.
13. **Dead letter queue.** `dlq_inspect`, `dlq_replay`, `dlq_replay_all`,
    `dlq_purge`. Currently in `sql/experimental/`; document the surface that
    is in the default install and clearly mark experimental pieces.
14. **Managed Postgres compatibility.** Pure SQL install, no C extensions,
    no daemon. `pg_cron` availability varies; document the manual fallback.

### Tier 4 — power users and edge cases

15. **Common patterns.** Fan-out, batch send, delayed delivery (experimental),
    cursor-based streaming for large batches, custom batch timing via
    `next_batch_custom`.
16. **PgQ-native primitives.** `insert_event`, `next_batch`,
    `next_batch_info`, `next_batch_custom`, `get_batch_events`,
    `finish_batch`, `event_retry`. For users who need cursor streaming,
    custom batch timing, or direct event field control.
17. **Troubleshooting.** Symptom → cause → fix table for the recurring
    failure modes (no events returned, same batch repeatedly, retry events
    not reappearing, queue growing unbounded, `force_tick` apparently
    no-op).

### Hard-won lessons from PgQ + PgQue commit history

These are not a tier — they are facts that should land in whichever doc
covers the relevant area. They are easy to miss without reading the history.

- **Origin and intent.** PgQ was built at Skype (~2007) by Marko Kreen.
  The PL/pgSQL-only fallback that PgQue is built on was added explicitly
  because users asked for a way to run PgQ in restricted/hosted environments
  where C extensions are not allowed. That is PgQue's entire reason to exist.
- **`xid8` matters.** PG14+ uses `xid8` for transaction IDs. Mismatches
  silently break batch event SQL and rotation. PgQue handles this; users
  extending the schema with custom SQL must be aware.
- **Rotation is two transactions on purpose.** Step 1 advances the table
  pointer; step 2 records a `txid` proving the switch is globally visible.
  Combining them defeats the safety mechanism and the queue grows without
  bound. Observed in the wild before the fix.
- **`force_tick` alone is not enough.** It only bumps the event sequence.
  `ticker()` must run after it to actually create the tick snapshot.
- **`maint` uses `pg_try_advisory_xact_lock`, not session-level.** Session
  locks persist in `pg_cron`'s connection pool after failures; transaction
  locks do not.
- **`LISTEN`/`NOTIFY` is a hint, not delivery.** The ticker emits
  `pg_notify` to wake consumers faster, but notifications are lossy. Always
  keep a polling fallback.
- **`INHERITS` not native partitioning.** PgQ uses inheritance for the
  three rotating tables. Native partitioning is unnecessary for a fixed
  three-child rotation and `TRUNCATE` of the oldest. Document this so users
  do not "modernize" the schema and break the rotation safety properties.

## 3. Writing rules

PgQue inherits the postgres-ai writing rules through `CLAUDE.md`. The ones
most likely to be violated when writing user-facing docs:

- **"Postgres" not "PostgreSQL"**, except when technical accuracy demands it
  (e.g. extension names, version banners).
- **Sentence-style capitalization** for headings — "Database migration
  testing", not "Database Migration Testing".
- **No emojis, no emotional language.** Objective, data-driven tone. No
  "amazing", "unfortunately", "awesome", "battle-tested" (the README uses
  "battle-tested" today; that is the boundary case — usable when it is
  factually descriptive, not as a marketing flourish).
- **Em dashes with spaces**: `word — word`.
- **Platform neutrality.** Never say "RDS does not support X" or "Supabase
  is limited to Y". Say "this setting is not configurable on managed
  Postgres" or "managed services typically do not allow X". This applies
  hardest to `docs/howto/install.md` and `docs/explanation/tradeoffs.md`.
- **Binary units** (KiB, MiB, GiB, TiB) for all sizes and rates in prose.
  Exception: PG config values use PG's native format (`shared_buffers =
  '2GB'`).
- **psql examples** must include `--no-psqlrc` and `PAGER=cat` so output is
  predictable for readers copy-pasting commands.
- **SQL examples** must use lowercase keywords, `snake_case` identifiers,
  and the formatting from `db-sql-style-guide.mdc` (root keywords on their
  own line, multi-arg calls with one arg per line). This already matches
  the style in `sql/pgque.sql`.

It is worth adding a short writing-rules section to `CLAUDE.md` listing the
above bullets. The full URL is already there; an inline checklist makes
violations easier to catch in review.

## 4. README.md — what stays, what moves out

The current README is ~450 lines and tries to be landing page, quick
reference, and explainer simultaneously. The job of the README is to answer
*what is this, why should I care, and how do I try it* in under two minutes.
Everything else moves into `docs/`.

### Stays in README

- Title, tagline, badges.
- One-paragraph framing (PgQ heritage, what PgQue repackages).
- **Why PgQue** — five bullets, current content is good.
- **Latency trade-off** — short, currently good.
- **Comparison table** — keep. It is a useful decision aid in the landing
  page itself, and rewriting it as a how-to removes the at-a-glance value.
- **Installation** — slim to: `\i sql/pgque.sql`, `select pgque.start()`,
  one-line note that without `pg_cron` you call `ticker()` and `maint()`
  yourself. Detailed install guidance moves to `docs/howto/install.md`.
- **Project status** — keep, currently short.
- **Quick start** — keep. The current six-step flow is exactly the right
  length. The `02f649d` follow-up note about `force_tick` belongs here.
- **Client libraries** — keep brief mentions and links. The current Python
  and Go snippets are fine.
- **License + heritage** — keep.
- **Links to `docs/`** — new section near the top: one link per Diátaxis
  quadrant with a one-line description of each.

### Moves out of README

- **Usage examples section** → `docs/howto/` (one file per pattern).
- **Function reference table** → `docs/reference/api.md`. The README can
  keep a one-line "see reference" link and drop the table.
- **Benchmarks section** → user already noted performance gets its own
  document. Move to `docs/explanation/performance.md`. While moving:
  - normalize units across every row (every row reports per-second and
    where applicable per-second-bandwidth in MiB/s)
  - normalize the client/concurrency information across every row (the
    current table only mentions "16 clients" on the first row; either show
    that column for every row or drop it)
  - state vCPU count, RAM, PG version, and `synchronous_commit` setting
    once at the top of the table, not buried in a single row
  - link to the full methodology issue
- **Architecture bullet list** → trim README to one paragraph + link to
  `docs/explanation/architecture.md`. The bullets are useful but they
  belong in the explanation.

This trims the README to roughly 200–250 lines, with everything still
discoverable through the new `docs/` index near the top.

## 5. docs/ tree — the four Diátaxis quadrants

Proposed layout:

```
docs/
  tutorial.md
  howto/
    install.md
    exactly-once.md
    fan-out.md
    retry-and-dlq.md
    delayed-delivery.md
    batch-loading.md
    monitoring.md
    manual-maintenance.md
    tuning-latency.md
    uninstall.md
  reference/
    api.md
    configuration.md
    schema.md
    roles.md
    message-format.md
    maintenance.md
    status-output.md
  explanation/
    architecture.md
    exactly-once-semantics.md
    bloat-free-design.md
    pgq-heritage.md
    tradeoffs.md
    performance.md
```

### 5.1 Tutorial — `docs/tutorial.md`

A single guided walkthrough for a newcomer who has never used PgQue. It
teaches the mental model by making the user *experience* it, not by
describing it.

Concrete scenario: an order-processing queue. Steps:

1. Install (`\i sql/pgque.sql`).
2. `create_queue('orders')`, `subscribe('orders', 'worker')`.
3. `send` an order. Try `receive` immediately — get nothing. This is the
   teaching moment for the ticker.
4. `force_tick('orders')` then `ticker()`. `receive` again — get the batch.
   `ack`.
5. Send a "bad" order. `nack` it with a 5-second delay. Watch it reappear.
6. Drive nack-loop to exhaustion. See it land in the DLQ.
7. `pgque.status()` and `pgque.get_consumer_info()`.
8. `pgque.start()` to switch to `pg_cron`-driven operation.
9. Tear down.

Every step shows expected output. No detours. No reference tables.

### 5.2 How-to guides — `docs/howto/`

Each file solves one task. No conceptual material — that lives in the
explanations. Each file is short (target ~100 lines), starts with the goal,
ends with the result.

| File | Question |
|---|---|
| `install.md` | How do I install on managed Postgres (with and without `pg_cron`)? |
| `exactly-once.md` | How do I process events exactly once? |
| `fan-out.md` | How do I deliver the same events to several independent consumers? |
| `retry-and-dlq.md` | How do I configure retries and inspect/replay the DLQ? |
| `delayed-delivery.md` | How do I schedule events for future delivery? |
| `batch-loading.md` | How do I load events efficiently in bulk? |
| `monitoring.md` | How do I set up alerts on ticker lag, consumer lag, DLQ depth? |
| `manual-maintenance.md` | How do I run PgQue without `pg_cron`? |
| `tuning-latency.md` | How do I reduce batch latency? |
| `uninstall.md` | How do I remove PgQue cleanly? |

### 5.3 Reference — `docs/reference/`

Dry, complete, alphabetical or grouped where that helps lookup. No
narrative. Someone should find any function/parameter/column in under ten
seconds.

| File | Content |
|---|---|
| `api.md` | Every public function: signature, parameters, return type, one-line example. Two sections: modern API (`send`, `receive`, `ack`, `nack`, `subscribe`, `unsubscribe`, `start`, `stop`, `status`); PgQ primitives (`insert_event`, `next_batch`, `next_batch_info`, `next_batch_custom`, `get_batch_events`, `finish_batch`, `event_retry`). |
| `configuration.md` | Every `set_queue_config` key: name, type, default, valid range, what it controls. Plus the `pgque.config` singleton. |
| `schema.md` | Every table and column: `queue`, `consumer`, `subscription`, `tick`, event template, `retry_queue`, `dead_letter`, delayed events, `config`. |
| `roles.md` | Role hierarchy, exact grants per role, how to assign. |
| `message-format.md` | The `pgque.message` composite type, every field, when each is NULL, how `retry_count` evolves. |
| `maintenance.md` | What ticker, `maint`, `rotate_step_1`, `rotate_step_2` do; cadences; statement timeouts; `pg_cron` job names. |
| `status-output.md` | Column-by-column meaning of `pgque.status()`, `get_queue_info()`, `get_consumer_info()`, `get_batch_info()`. |

### 5.4 Explanation — `docs/explanation/`

The "why" behind the design. No instructions, no tables of parameters.
These are essays.

| File | Topic |
|---|---|
| `architecture.md` | Snapshot-based batching vs row claiming. Three-table rotation. Why `TRUNCATE` not `DELETE`. Why `INHERITS` not native partitioning. Tick/snapshot/batch relationship. How `batch_event_sql` uses transaction visibility. Why latency is seconds. |
| `exactly-once-semantics.md` | Why wrapping `receive` + business writes + `ack` in one transaction yields exactly-once. The at-least-once default outside of that wrapping. Why external brokers cannot offer this property. |
| `bloat-free-design.md` | The dead-tuple problem in `SKIP LOCKED` queues (with the Brandur Leach analysis already linked from the README). How rotation solves it. Why a stopped consumer blocks rotation and causes growth. |
| `pgq-heritage.md` | PgQ's history (Skype, ~2007, Marko Kreen). What PgQue changes (schema rename, PG14+ APIs, `xid8`, `pg_cron`, `LISTEN`/`NOTIFY`, DLQ, roles). What it preserves unchanged (the entire batch/tick/rotation/consumer engine). The PL/pgSQL-only path that made PgQue possible. |
| `tradeoffs.md` | When to choose PgQue vs `pgmq` vs `SKIP LOCKED` vs Redis vs Kafka. Honest about limitations: second-level latency, no priorities, no worker lifecycle. Where PgQue wins: durability, zero bloat, fan-out, exactly-once, managed-Postgres compatibility. Platform-neutral framing throughout. |
| `performance.md` | The full benchmark methodology, results table, interpretation. Owns this material so the README can stay short. |

## 6. Cross-cutting principles

- **Do not mix quadrants.** Tutorials are not reference. How-tos are not
  explanation. Reference is not narrative. Each kind serves a different
  reader in a different mode.
- **Every SQL example follows the SQL style guide** in `CLAUDE.md` and the
  postgres-ai rules. This already matches `sql/pgque.sql`.
- **Every shell example uses** `set -Eeuo pipefail` and double-quoted
  expansions.
- **Every psql example uses** `--no-psqlrc` and `PAGER=cat`.
- **Reinforce the ticker** in tutorial, install, manual-maintenance,
  monitoring, and troubleshooting. It is the single most common failure
  mode and costs nothing to mention again.
- **Mark experimental clearly.** Anything in `sql/experimental/` (delayed
  delivery, observability, DLQ tooling) gets an "Experimental" callout in
  the relevant doc and is not promoted in the tutorial. `PHASES.md` is the
  source of truth for what is in the default install in v0.1.
- **Cross-link generously between quadrants** but keep the direction of
  flow sensible: tutorial → how-tos for next-step tasks; how-tos →
  reference for parameter detail; reference → explanation for "why this
  default"; explanation → reference for "what to call".

## 7. Effects on `CLAUDE.md`

Two small additions worth making in a separate small PR before the docs
work starts:

1. A short "Writing rules" section in `CLAUDE.md` listing the bullets
   from section 3 of this doc. The full URL stays.
2. A "Documentation layout" pointer naming the four Diátaxis directories
   under `docs/` and saying which kind of content goes where. This catches
   drift early — without it, future contributors will reach for the README
   to add anything user-facing.

## 8. Suggested order of work

Prioritized so each PR is reviewable on its own and unblocks the next one.

1. **CLAUDE.md updates** — writing rules checklist + docs layout pointer.
   Tiny PR. Lands first so all subsequent docs PRs can be reviewed against
   the rules.
2. **README slim-down** — move benchmarks, function reference, usage
   examples, and architecture detail into placeholder files under `docs/`.
   Add the `docs/` index section near the top of the README. The `docs/`
   files at this point can be stubs that contain the moved material as-is;
   subsequent PRs polish each file.
3. **Tutorial** (`docs/tutorial.md`). The single highest-leverage doc for
   new users.
4. **Reference fill-in.** `api.md`, `configuration.md`, `message-format.md`,
   `maintenance.md`, `status-output.md`. These are mechanical writes from
   the source SQL, so they can be batched.
5. **Explanation: `architecture.md` + `bloat-free-design.md` + `pgq-heritage.md`.**
   These ground the rest of the docs and link in well from the README.
6. **How-to guides** in priority order: `install.md`,
   `manual-maintenance.md`, `exactly-once.md`, `monitoring.md`,
   `retry-and-dlq.md`, `tuning-latency.md`, `fan-out.md`,
   `batch-loading.md`, `delayed-delivery.md`, `uninstall.md`.
7. **Remaining explanations:** `exactly-once-semantics.md`, `tradeoffs.md`,
   `performance.md`.
8. **Reference: `schema.md`, `roles.md`** — last because they are the
   driest and least-frequently-read.

## 9. PgQ vocabulary — canonical glossary (Kreen & Pihlak, PgCon 2009)

All user-facing docs use this vocabulary. The terms come from the 2009 PgCon
talk by Marko Kreen and Martin Pihlak. Using the same words the authors used
protects the lineage and avoids inventing a second vocabulary for the same
objects. PR #54 (`claude/extract-pgq-docs-EUM1D`) lands the same material as
standalone primers under `docs/pgq-concepts.md` and `docs/pgq-history.md`;
this section is the binding between that vocabulary and every other doc in
the plan.

### 9.1 Glossary

- **Event** — one row in a queue table. Delivered *at-least-once*.
- **Batch** — events between two ticks, served to a consumer together.
- **Queue** — named event stream; three rotating tables, purged by
  `TRUNCATE`.
- **Producer** — anything that calls `insert_event` / `pgque.send`.
- **Consumer** — subscribes, reads batches, calls `ack` (or
  `finish_batch`).
- **Ticker** — creates ticks, vacuums, rotates, reschedules retries.
  In PgQue: `pg_cron` calling `pgque.ticker()`.
- **Tick** — position marker in the event stream; delimits batches.

### 9.2 Delivery

At-least-once. Exactly-once requires either:

- **Same DB:** process in the same transaction as `finish_batch` / `ack`.
- **Cross DB:** target-side batch/event tracking
  (`pgque.is_batch_done`).

### 9.3 Consumer loop — canonical form

```
batch_id = next_batch(queue, consumer)   -- NULL → sleep, retry
events   = get_batch_events(batch_id)
process(events)                           -- nack individual failures
finish_batch(batch_id)
commit
```

### 9.4 Event row

`ev_id`, `ev_time`, `ev_txid` (`xid8`), `ev_retry`, `ev_type`, `ev_data`,
`ev_extra1..4`. `ev_extra1` is table name by convention (triggers).
Payload format is a producer/consumer contract; PgQue does not interpret
it.

### 9.5 Health signals

From `pgque.get_consumer_info()`:

- **lag** — age of the last finished batch; high ⇒ falling behind.
- **last_seen** — time since the last batch; high ⇒ consumer not running.

### 9.6 Per-queue tuning

Stored on `pgque.queue`, read by `pgque.ticker()`. Set via
`pgque.create_queue(name, options jsonb)` or `pgque.set_queue_config`.

- `ticker_max_lag` — max wall time between ticks.
- `ticker_idle_period` — tick interval when idle.
- `ticker_max_count` — force a tick at N events (batch-size cap).
- `rotation_period` — table-rotation period (disk vs. history).

### 9.7 The ticker rule — verbatim

> Keep the ticker running. No ticks → no batches → no delivery. Long
> pauses produce huge batches consumers can't handle.

— Kreen & Pihlak, PgCon 2009.

### 9.8 Lineage — short

- **2006** — PgQ started at Skype. Inspired by Slony.
- **2007** — Open-sourced as part of Skytools. First application:
  Londiste replication.
- **2009** — Skytools 3: cascading, cooperative consumers. PgCon talk by
  Kreen & Pihlak.
- **2026** — PgQue: PG14+ single-file repackage for managed databases.

PgQ (Skype, ISC) → Skytools 2/3 → `github.com/pgq/pgq` → **PgQue**
(Apache-2.0, PG14+). Skype ran hundreds of queues on PgQ in production;
PgQue inherits that engine and does not reinvent it.

### 9.9 Where this material lands in the docs tree

- The glossary (9.1) opens `docs/explanation/architecture.md` and is
  reused verbatim as a "Vocabulary" panel in the tutorial.
- Delivery semantics (9.2) seed `docs/explanation/exactly-once-semantics.md`.
- The consumer loop (9.3) is the single canonical form referenced from
  every how-to that touches the read path.
- The event row (9.4) is the source for
  `docs/reference/message-format.md`.
- Health signals + tuning (9.5, 9.6) feed
  `docs/reference/configuration.md` and `docs/howto/monitoring.md`.
- The ticker rule (9.7) is pulled as a blockquote in the README, the
  tutorial, and `docs/howto/manual-maintenance.md`.
- Lineage (9.8) is the spine of `docs/explanation/pgq-heritage.md`.

## 10. DevRel considerations — positioning, the bloat-bakeoff, README leverage

This section pairs the documentation plan above with the marketing
surface. Docs and DevRel share one job: make "doesn't degrade" a
*visible* claim. "Doesn't degrade" is a negative — the absence of
something. Absences don't go viral. The work is to make decay visible
everywhere else and show the PgQue line staying flat.

### 10.1 README leverage — ranked

Targeted changes to `README.md`, ranked by reader reaction per unit of
effort. Items 1–3 are near-term; 4–10 are follow-up.

1. **Lead with a 15-second visual proof, not prose.** Above the fold:
   one chart or GIF — dead tuples over 24 hours, PgQue flat, competitors
   climbing. Today the reader must reach "Why PgQue" before seeing the
   thesis. Every recent Postgres-adjacent breakout (ClickHouse, Turso,
   Dragonfly, Bun) leads with one picture.
2. **Move benchmark numbers up, strip the prose.** "85,836 events/sec on
   a laptop, zero dead tuples after 30 days" is a tweetable opening
   line. Split the benchmark table into two — producer-side and
   consumer-side. The 2.4 M events/s consumer read is currently buried
   and should not be.
3. **Add a two-sentence "Why this exists" above "Why PgQue".**
   Concentrates the decay-mode evidence the README already cites in
   scattered form (Heroku 2015, PlanetScale 2026, River, Oban, PGMQ).
   One paragraph, not four bullets spread across three sections.
4. **Split the comparison table.** Eight columns is unreadable on
   mobile. Two tables: "vs. other Postgres queues" and "vs. external
   queues (Kafka, SQS, Redis Streams)". The second pre-empts the first
   Hacker News question.
5. **Five-minute demo container.** `docker run
   ghcr.io/nikolays/pgque-demo` with PgQue pre-installed, a load
   generator, and a Grafana dashboard on port 3000 showing zero bloat
   while it runs. Collapses the "try it" funnel from ~20 minutes to
   ~60 seconds. PGMQ has this; PgQue should too.
6. **Strengthen the client-library section.** Ctrl-F for a language is
   the first thing decision-makers do. Either ship rough-but-working
   libs in 3–4 languages, or lean hard into "any Postgres driver works
   — here are five one-liners" without framing anything as missing.
7. **Social proof.** A "Who uses this?" section the moment anyone
   nontrivial adopts PgQue. Stars-over-time graph. Sponsors block.
8. **FAQ.** Written pre-emptively against the first ten HN questions:
   how does this compare to Kafka; can I run this on Supabase; what
   happens without `pg_cron`; upgrade story; API stability;
   crash-safety.
9. **"Anti-extension" as brand asset.** A brandable, sticker-able
   concept. SVG in the README; stickers to the first N stargazers.
10. **Pronunciation + SEO.** One sentence: "PgQue (pronounced
    'peg-cue' — PgQ, universal edition)." Removes a micro-friction every
    reader hits, helps search separate PgQue from PgQ.

### 10.2 "Make decay visible" — the playbook

Ranked by leverage. Same logic as the ClickHouse public benchmark, the
TigerBeetle VOPR, Brandur's 2015 post: the *proof* becomes the product.

1. **The Bloat Bakeoff.** A public, always-on, real-time dashboard at
   one URL. Five queues in parallel containers (PgQue, PGMQ, River,
   pg-boss, Que) under identical load. Public Grafana showing
   throughput, dead-tuple count, table size, p99 enqueue/dequeue,
   vacuum time, `xmin` horizon lag. Uptime 24/7/365. Evergreen: every
   competitor release is an excuse to re-share the chart. Budget
   ~$50/month; upside is the ClickHouse-benchmark move applied to the
   one dimension where PgQue structurally wins.
2. **"Why Your Postgres Queue Rots" — a visual essay.** One long-form
   explainer with animated SVGs: how a tuple becomes dead, how `VACUUM`
   fails under a pinned `xmin`, how `SKIP LOCKED` scans skip more rows
   over time, how three-table rotation yields zero dead tuples by
   construction. Written as the continuation of Brandur's 2015 post:
   "…and here is how we actually fixed this." The same artifact is
   `docs/explanation/bloat-free-design.md` from section 5.4 —
   rendered at two quality bars, one canonical source.
3. **Conference demo.** Live: three queues side-by-side, identical
   load, open a `BEGIN; SELECT pg_sleep(600);` session in psql. PGMQ's
   vacuum collapses, River's throughput nosedives, PgQue keeps going.
   Fifteen minutes, recorded; clips into a 45-second video.
4. **Postgres Queue Graveyard.** A page cataloguing every publicly
   documented production outage caused by Postgres queue bloat: Heroku
   2015, PlanetScale 2026, River #59, matching Oban/PGMQ issues. Each
   entry: date, company, queue library, root cause, one-paragraph
   postmortem. Community submissions welcome. Every entry is public
   material — earned SEO, not dark-pattern.
5. **One-command local reproducer.** `docker run
   ghcr.io/pgque/bakeoff` spins up the five-queue dashboard locally.
   Skeptics who dismiss public benchmarks run it on their own laptop in
   60 seconds and see the same line. Short-circuits most
   "synthetic-benchmark" pushback.
6. **Originator blessing.** Alexander Kukushkin recently presented
   "Rediscovering PgQ". Marko Kreen is reachable. A one-line endorsement
   from either in the README is a narrative lock. Offer co-authorship
   of the visual essay (#2) or a PostgresFM episode.
7. **Coin a metric.** Define "Queue Decay Rate" —
   dead-tuple-growth per event processed — as a formal metric. Publish
   a spec. Ask competitors to report theirs. Low odds; high upside if
   it catches on, same shape as Redis `ops/sec`.
8. **One-billion-message challenge.** Run 1 B messages through PgQue.
   Publish hardware, config, runtime, table size before/after,
   dead-tuple count before/after, vacuum total. Invite every competing
   queue to match it. 1BRC-style.

If only two land, land **#1 and #2.** The dashboard is evergreen proof;
the essay is the canonical reference. Every tweet, README line,
conference talk, and HN comment for the next two years points at one of
those two URLs.

### 10.3 Voice — keep the honesty

The "latency trade-off" paragraph currently in the README is doing a
lot of work for trust. That tone — aggressive claim *paired* with
explicit admission of where PgQue is not the right tool — is the
reason the "zero bloat" claim reads as credible rather than as
marketing. Preserve it everywhere: README, tutorial, explanations, and
every DevRel artifact. Honesty is the moat we already have.

### 10.4 Relationship to the docs plan

- Sections 4–5 own in-repo Markdown.
- 10.1–10.2 own positioning, public artifacts, and the landing-page
  surface of the README.
- One piece of content should never be forked. The bloat-free-design
  explainer is the same artifact as the visual essay (#2), rendered at
  two quality bars. The glossary in section 9 is used verbatim across
  tutorial, reference, and any external essay or talk.
- DevRel artifacts (Bakeoff, graveyard, essay) live outside the repo
  as separate projects and landing pages, but link back into `docs/`
  for depth. They never duplicate vocabulary — they import section 9.

## 11. Out of scope for this design doc

- Client library docs (`pgque-py`, `pgque-go`, CLI). Each gets its own
  `docs/` tree under its own subdirectory or repo when those projects
  mature. The PgQue core docs link out, they do not host.
- Internal contributor docs. `SPECx.md`, `PHASES.md`, and this file already
  cover that audience.
- Marketing site or hosted docs. This plan covers in-repo Markdown only.
  A docs site (mkdocs, docusaurus) can be layered on top later without
  changing the source structure.
- Translations.

## 12. Open questions

- Should the `docs/` index live as a section in the README, as a separate
  `docs/README.md`, or both? Recommendation: both. README links to four
  entry points (tutorial, how-tos index, reference index, explanation
  index). Each index page is a `README.md` in its directory.
- Where does the recurring-jobs-with-`pg_cron` example go? It is currently
  in the README under usage examples. Recommendation: short mention stays
  in the README quick-start area as a teaser, full pattern moves to
  `docs/howto/` as a small file or as a section in `manual-maintenance.md`.
- How much of `sql/experimental/` to document. Recommendation: document
  the surface that ships in `sql/pgque.sql` first, add experimental
  surfaces only when they are promoted into the default install per
  `PHASES.md`.
