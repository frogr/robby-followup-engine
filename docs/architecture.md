# Architecture

How data moves through the engine, what is stored, and where each rule is
enforced. Every output block is a copy of a file in `docs/captures/`, written
by `ruby docs/capture.rb` from an empty database.

Contents:

- [Data flow](#data-flow)
- [Schema](#schema)
- [The event fold](#the-event-fold)
- [The outbox state machine](#the-outbox-state-machine)
- [The send statement](#the-send-statement)
- [The idempotency key](#the-idempotency-key)
- [The now parameter](#the-now-parameter)

## Data flow

```text
 data/quotes.json      data/events.jsonl
        |                     |
        |                     |  Events.normalize: parse, drop unusable
        |                     |  records, dedup on event id, sort by time
        v                     v
 +--------------------------------------+
 | bin/followup ingest                  |
 |   quotes: upsert                     |
 |   events: INSERT OR IGNORE           |
 +--------------------------------------+
        |                     |
        v                     v
   quotes table          events table
        |                     |
        +----------+----------+
                   |
                   v
 +--------------------------------------+
 | State.derive(quotes, events, now)    |<----- sent outbox rows
 |   fold events with ts <= now         |       (our own messages count
 |   one QuoteState per quote           |        as contact)
 +--------------------------------------+               ^
                   |                                    |
                   v                                    |
 +--------------------------------------+               |
 | Policy.run                           |               |
 |   exclude, pick a signal, score      |               |
 +--------------------------------------+               |
                   |                                    |
                   v  bin/followup candidates (prints)  |
              candidates                                |
                   |                                    |
                   v  bin/followup draft                |
 +--------------------------------------+               |
 | outbox row, status pending           |               |
 |   UNIQUE idempotency_key             |               |
 +--------------------------------------+               |
                   |                                    |
                   v  bin/followup approve (a human)    |
            status approved                             |
                   |                                    |
                   v  bin/followup send                 |
 +--------------------------------------+               |
 | GUARDED_SEND, one row per transaction|               |
 |   then deliver(row)                  |               |
 +--------------------------------------+               |
        |            |            |                     |
        v            v            v                     |
      sent        failed       blocked                  |
        |            |                                  |
        |            +--> bin/followup retry            |
        |                 (same statement)              |
        +-----------------------------------------------+
```

The code is split the same way:

| File | Responsibility |
|---|---|
| `lib/followup/events.rb` | Parse, dedup and sort raw events |
| `lib/followup/ingest.rb` | Read the two files and store them |
| `lib/followup/state.rb` | Fold events into per-quote state at "now" |
| `lib/followup/policy.rb` | Exclusions, signals, scores |
| `lib/followup/templates.rb` | One message template per reason |
| `lib/followup/outbox.rb` | Draft, approve, send, retry, and the delivery seam |
| `lib/followup/db.rb` | Schema, views, triggers, reads |
| `lib/followup/cli.rb` | Argument parsing and printing |

`events.rb`, `state.rb` and `policy.rb` do not touch the database. They take
arrays and a time and return values, which is what makes the policy testable
and repeatable.

## Schema

Three tables, two views, two triggers. This is the schema as SQLite reports it
after the demo run:

```text
$ sqlite3 followup.sqlite3 .schema
CREATE TABLE quotes (
  id              TEXT PRIMARY KEY,
  customer_name   TEXT NOT NULL,
  customer_phone  TEXT NOT NULL,
  tech_name       TEXT,
  amount          INTEGER NOT NULL,
  status          TEXT NOT NULL CHECK (status IN ('open','accepted','dismissed')),
  created_at      TEXT NOT NULL,
  last_contact_at TEXT
);
CREATE INDEX quotes_phone ON quotes (customer_phone);
CREATE TABLE events (
  event_id  TEXT PRIMARY KEY,
  type      TEXT NOT NULL,
  quote_id  TEXT NOT NULL,
  ts        TEXT NOT NULL,
  channel   TEXT,
  direction TEXT
);
CREATE INDEX events_quote_ts ON events (quote_id, ts);
CREATE TABLE outbox (
  id              INTEGER PRIMARY KEY,
  quote_id        TEXT NOT NULL REFERENCES quotes (id),
  customer_phone  TEXT NOT NULL,
  reason          TEXT NOT NULL,
  score           REAL NOT NULL,
  body            TEXT NOT NULL,
  status          TEXT NOT NULL DEFAULT 'pending'
                  CHECK (status IN ('pending','approved','sent','failed','blocked')),
  idempotency_key TEXT NOT NULL UNIQUE,
  created_at      TEXT NOT NULL,
  sent_at         TEXT,
  attempts        INTEGER NOT NULL DEFAULT 0,
  last_error      TEXT
);
CREATE INDEX outbox_phone_sent ON outbox (customer_phone, sent_at);
CREATE TRIGGER outbox_transitions
BEFORE UPDATE OF status ON outbox
WHEN NOT (
  (OLD.status = 'pending'  AND NEW.status = 'approved') OR
  (OLD.status = 'approved' AND NEW.status IN ('sent','failed','blocked')) OR
  (OLD.status = 'failed'   AND NEW.status IN ('sent','blocked'))
)
BEGIN
  SELECT RAISE(ABORT, 'illegal outbox transition');
END;
CREATE VIEW customer_contacts AS
  SELECT q.customer_phone AS customer_phone, e.ts AS at
    FROM events e JOIN quotes q ON q.id = e.quote_id
   WHERE e.type = 'message_sent' AND COALESCE(e.direction, 'outbound') <> 'inbound'
  UNION ALL
  SELECT customer_phone, last_contact_at FROM quotes WHERE last_contact_at IS NOT NULL
  UNION ALL
  SELECT customer_phone, sent_at FROM outbox WHERE status = 'sent'
/* customer_contacts(customer_phone,at) */;
CREATE VIEW customer_replies AS
  SELECT q.customer_phone AS customer_phone, e.ts AS at
    FROM events e JOIN quotes q ON q.id = e.quote_id
   WHERE e.type = 'customer_replied'
/* customer_replies(customer_phone,at) */;
CREATE TRIGGER outbox_no_delete
BEFORE DELETE ON outbox
BEGIN
  SELECT RAISE(ABORT, 'outbox rows are never deleted');
END;
```

All timestamps are UTC ISO 8601 strings of the same width, for example
`2026-08-12T16:00:00Z`, so comparing the strings compares the times.

### quotes

One row per quote, from `quotes.json`.

| Column | Meaning |
|---|---|
| `id` | Quote id from the snapshot. Primary key. |
| `customer_name` | Full name. The first word is used in messages. |
| `customer_phone` | The customer's identity. The cooldown is keyed on it. |
| `tech_name` | The technician on the quote. Signs the message. |
| `amount` | Whole dollars. |
| `status` | `open`, `accepted` or `dismissed`, as the snapshot said. Once a stored row is closed, a later snapshot saying `open` does not overwrite it. |
| `created_at` | When the quote was created. Used for age, the 60-day exclusion, and as the start of the quiet period when nobody has contacted the customer. |
| `last_contact_at` | The snapshot's record of the last contact. May be null. Treated as one outbound contact. |

### events

One row per distinct event, from `events.jsonl`.

| Column | Meaning |
|---|---|
| `event_id` | The dedup key and primary key. The source `event_id` when there is one, otherwise `type`, `quote_id` and timestamp joined with a pipe. |
| `type` | Stored as received. The fold acts on `quote_viewed`, `customer_replied`, `message_sent` and `quote_accepted`. Any other type, including `quote_sent`, is stored and ignored. |
| `quote_id` | The quote the event is about. Not a foreign key, so an event for an unknown quote is stored and never folded. |
| `ts` | When the event happened, from the source `timestamp` field. |
| `channel` | `sms` or `email` where the source gave one. Stored, not used. |
| `direction` | Present on `message_sent`. A `message_sent` with direction `inbound` is not counted as us contacting the customer. |

### outbox

One row per drafted follow-up.

| Column | Meaning |
|---|---|
| `id` | Row id. `approve <id>` takes this. |
| `quote_id` | The quote the message is about. Foreign key to `quotes`. |
| `customer_phone` | Copied from the quote at draft time. The cooldown check uses it. |
| `reason` | The policy reason that produced the draft. Selects the template. |
| `score` | Copied from the candidate at draft time. Send processes rows in descending score. |
| `body` | The rendered message. |
| `status` | `pending`, `approved`, `sent`, `failed` or `blocked`. |
| `idempotency_key` | `quote_id:reason:ISO-week`. `UNIQUE`. |
| `created_at` | The "now" of the draft run. |
| `sent_at` | The "now" of the send run. Null until the row is sent. |
| `attempts` | Delivery attempts. Goes up by one on each send or retry that reaches delivery. A block does not change it. |
| `last_error` | The delivery error or the guardrail that blocked the row. Cleared when the row is sent. |

### Views

| View | Rows |
|---|---|
| `customer_contacts` | Every time we contacted a customer, as `(customer_phone, at)`. The union of `message_sent` events that are not inbound, each quote's `last_contact_at`, and sent outbox rows. |
| `customer_replies` | Every `customer_replied` event, as `(customer_phone, at)`. |

Both join events to quotes to get the phone number, so they are per customer
across all of that customer's quotes. They exist so the send statement can
state the cooldown in a few lines.

### Triggers

| Trigger | Fires | Effect |
|---|---|---|
| `outbox_transitions` | Before any update that sets `status` | Aborts unless the change is one of the allowed transitions listed below |
| `outbox_no_delete` | Before any delete from `outbox` | Always aborts. The outbox is the record of what was sent and what was refused. |

The triggers apply to every writer, including a person at the SQLite prompt:

```text
$ sqlite3 followup.sqlite3 "UPDATE outbox SET status = 'pending' WHERE id = 1"
Error: stepping, illegal outbox transition (19)
```

```text
$ sqlite3 followup.sqlite3 "DELETE FROM outbox WHERE id = 1"
Error: stepping, outbox rows are never deleted (19)
```

## The event fold

### Dedup

There are two layers.

1. Within one file, `Events.normalize` keeps the first event seen for each key.
2. Across runs, the key is the primary key of `events` and ingest uses
   `INSERT OR IGNORE`, so an event already stored is skipped.

The key is the source `event_id`. Every seed event has one, so the fallback of
type, quote id and timestamp is not exercised by the seed data. It is covered
by a test.

The seed file has 88 lines. Six of them are exact repeats of another line:

```text
$ sort data/events.jsonl | uniq -d | wc -l
       6
```

```text
$ bin/followup ingest
quotes                         30
event lines                    88
malformed                      0
invalid or duplicate in file   6
unique events                  82
inserted                       82
already stored                 0
```

```text
$ bin/followup ingest
quotes                         30
event lines                    88
malformed                      0
invalid or duplicate in file   6
unique events                  82
inserted                       0
already stored                 82
```

### Ordering

File order is never used. `Events.normalize` sorts by timestamp, then event id.
Every read from the table is `ORDER BY ts, event_id`. The seed file is well out
of order:

```text
$ ruby -rjson -e 't = File.readlines("data/events.jsonl").map { |l| JSON.parse(l)["timestamp"] }; puts "#{t.size} lines, #{t.each_cons(2).count { |a, b| b < a }} adjacent pairs out of order"'
88 lines, 41 adjacent pairs out of order
```

The fold itself keeps the latest timestamp per event type, so its result does
not depend on the order it sees events in. Sorting makes storage and output
deterministic. It is not what makes the fold correct.

### A quote's state at time T

`State.derive(quotes, events, now)` returns one `QuoteState` per quote:

1. Drop quotes created after T. They do not exist yet.
2. Drop events with a timestamp after T.
3. Start each quote as `open`, or as closed if the snapshot says `accepted` or
   `dismissed`.
4. Start the last outbound contact at the snapshot's `last_contact_at`, if that
   is at or before T.
5. For each of the quote's events:
   - `quote_viewed` updates the last view.
   - `customer_replied` updates the last reply.
   - `message_sent` updates the last outbound contact and adds one to the
     follow-up count, unless its direction is `inbound`.
   - `quote_accepted` sets the status to `accepted`.
   - Anything else is ignored.
6. Add the messages this engine has sent for the quote: each one updates the
   last outbound contact and adds one to the follow-up count.

Nothing derived is written back. Running at a different T derives a different
state from the same rows.

### Snapshot against events

The rule: either source can close a quote, and nothing reopens one.

- A closed status in the snapshot holds at every T.
- A `quote_accepted` event holds from its timestamp onward.
- Events after a close still update the last view and last reply, but the
  status stays closed.

The three closed quotes in the seed data:

```text
$ sqlite3 -header -column followup.sqlite3 "SELECT id, status, created_at, last_contact_at FROM quotes WHERE id IN ('Q-1004','Q-1009','Q-1017') ORDER BY id"
id      status     created_at            last_contact_at     
------  ---------  --------------------  --------------------
Q-1004  accepted   2026-08-07T07:00:00Z  2026-08-09T17:00:00Z
Q-1009  dismissed  2026-08-09T02:00:00Z  2026-08-11T03:00:00Z
Q-1017  accepted   2026-08-04T05:00:00Z  2026-08-05T23:00:00Z
```

```text
$ sqlite3 -header -column followup.sqlite3 "SELECT quote_id, ts, type FROM events WHERE quote_id IN ('Q-1004','Q-1009','Q-1017') ORDER BY quote_id, ts"
quote_id  ts                    type            
--------  --------------------  ----------------
Q-1004    2026-08-07T07:00:00Z  quote_sent      
Q-1004    2026-08-09T07:00:00Z  quote_viewed    
Q-1004    2026-08-09T20:00:00Z  customer_replied
Q-1004    2026-08-10T07:00:00Z  quote_accepted  
Q-1004    2026-08-11T07:00:00Z  quote_viewed    
Q-1004    2026-08-14T12:00:00Z  quote_viewed    
Q-1009    2026-08-09T02:00:00Z  quote_sent      
Q-1009    2026-08-10T05:00:00Z  customer_replied
Q-1009    2026-08-15T00:00:00Z  quote_viewed    
Q-1017    2026-08-04T05:00:00Z  quote_sent      
Q-1017    2026-08-05T14:00:00Z  customer_replied
Q-1017    2026-08-10T04:00:00Z  quote_viewed    
Q-1017    2026-08-11T06:00:00Z  quote_viewed
```

| Quote | Snapshot | Events | Derived | What it shows |
|---|---|---|---|---|
| Q-1004 | `accepted` | `quote_accepted` on 08-10, then two views | `accepted` | Both sources agree. The later views do not reopen it. |
| Q-1017 | `accepted` | No `quote_accepted` event | `accepted` | The snapshot alone closes a quote. |
| Q-1009 | `dismissed` | No closing event, and a view on 08-15 | `dismissed` | There is no dismissed event type, so dismissal can only come from the snapshot. |

The two quotes closed by the snapshot alone:

```text
$ sqlite3 followup.sqlite3 "SELECT id || ' ' || status FROM quotes q WHERE status <> 'open' AND NOT EXISTS (SELECT 1 FROM events e WHERE e.quote_id = q.id AND e.type = 'quote_accepted')"
Q-1009 dismissed
Q-1017 accepted
```

The opposite case, accepted by an event while the snapshot says `open`, does
not occur in the seed data:

```text
$ sqlite3 followup.sqlite3 "SELECT COUNT(*) FROM quotes q WHERE status = 'open' AND EXISTS (SELECT 1 FROM events e WHERE e.quote_id = q.id AND e.type = 'quote_accepted')"
0
```

That case is covered by the test
`test_an_accepted_event_beats_an_open_status_in_the_snapshot`, using a fixture.

**Limitation.** The snapshot has no closed-at timestamp. Q-1004 is treated as
closed at every T, including a T before its acceptance event on 08-10. Replaying
an early T therefore under-reports open quotes. It never over-reports them.

## The outbox state machine

| Status | Meaning | Terminal |
|---|---|---|
| `pending` | Drafted, waiting for a human | No |
| `approved` | A human approved it | No |
| `sent` | Delivered | Yes |
| `failed` | Delivery was attempted and failed | No |
| `blocked` | A guardrail refused the send | Yes |

Allowed transitions:

| From | To | Caused by | When |
|---|---|---|---|
| `pending` | `approved` | `approve <id>` or `approve --all` | A human approves |
| `approved` | `sent` | `send` | The send statement matched and delivery returned |
| `approved` | `failed` | `send` | The send statement matched and delivery raised. The transaction is rolled back, then the row is marked failed. |
| `approved` | `blocked` | `send` | The send statement matched no row because the quote is closed or the customer is in cooldown |
| `failed` | `sent` | `retry` | As for `approved` to `sent` |
| `failed` | `blocked` | `retry` | As for `approved` to `blocked` |

A retry whose delivery fails again leaves the row `failed`. The status column
is not written, and `attempts` and `last_error` are updated.

Everything else is rejected by the `outbox_transitions` trigger. That includes
skipping approval, and any change to a `sent` or `blocked` row:

```text
$ sqlite3 followup.sqlite3 "UPDATE outbox SET status = 'sent' WHERE id = 1"
Error: stepping, illegal outbox transition (19)
```

```text
$ sqlite3 followup.sqlite3 "UPDATE outbox SET status = 'approved' WHERE status = 'blocked'"
Error: stepping, illegal outbox transition (19)
```

**Limitation.** There is no reject or cancel transition. A draft nobody approves
stays `pending`. It is never sent, and it holds its idempotency key for that
week.

## The send statement

`GUARDED_SEND` in `lib/followup/outbox.rb`, as the code holds it:

```sql
UPDATE outbox
   SET status = 'sent', sent_at = :now, attempts = attempts + 1, last_error = NULL
 WHERE id = :id
   AND status = :from
   AND EXISTS (SELECT 1 FROM quotes q
                WHERE q.id = outbox.quote_id AND q.status = 'open')
   AND NOT EXISTS (SELECT 1 FROM events e
                    WHERE e.quote_id = outbox.quote_id AND e.type = 'quote_accepted')
   AND NOT EXISTS (
         SELECT 1 FROM customer_contacts c
          WHERE c.customer_phone = outbox.customer_phone
            AND c.at > :cutoff
            AND NOT EXISTS (SELECT 1 FROM customer_replies r
                             WHERE r.customer_phone = c.customer_phone AND r.at > c.at))
```

It takes four parameters: the row `id`, the status the row must be in (`from`),
`now`, and `cutoff`, which is `now` minus the cooldown of 3 days.

| Lines | Condition | What it guarantees |
|---|---|---|
| `SET status = 'sent' ...` | | The row becomes sent, stamped with `now`, with one more attempt and no error. This only happens if every condition below holds. |
| `WHERE id = :id` | This row | One row per statement. |
| `AND status = :from` | The row is still `approved` (for send) or `failed` (for retry) | A row that is pending, already sent or blocked is not touched. A second process holding the same id changes nothing. |
| `AND EXISTS (... q.status = 'open')` | The quote is open in the snapshot | Never message a quote the snapshot has closed. |
| `AND NOT EXISTS (... 'quote_accepted')` | No acceptance event exists for the quote | Never message a quote an event has closed. |
| `AND NOT EXISTS (SELECT 1 FROM customer_contacts c ...` | There is no blocking contact for this customer | The cooldown. The next three lines say what makes a contact blocking. |
| `c.customer_phone = outbox.customer_phone` | The contact was with this customer | Per customer, across all their quotes. |
| `c.at > :cutoff` | The contact is more recent than the cutoff | A contact exactly 3 days old no longer blocks. |
| `AND NOT EXISTS (... r.at > c.at)` | The customer has not replied since that contact | A reply after our last contact lifts the cooldown. |

If the statement changes one row, `deliver(row)` is called inside the same
transaction. If delivery raises, the transaction is rolled back, so the row was
never visibly `sent`, and it is then marked `failed`.

If the statement changes no row, the code looks up why and marks the row
`blocked` with the reason in `last_error`. If the row is no longer in the
expected status, it is reported as skipped and left alone.

### Why the guardrails are in the statement and not in Ruby

A check in Ruby reads, decides, then writes. Between the read and the write
another process can send to the same customer, or an acceptance can be
ingested. With the conditions in the `WHERE` clause, the database evaluates
them and writes in one step, under its write lock.

It also means there is one definition of "allowed to send". Send and retry run
the same statement, so a retry cannot skip a guardrail.

### One row per transaction

`send` reads the ids of the approved rows, ordered by score descending and then
id, and runs the statement once per id, each in its own transaction. The `sent`
row written for the first id is visible to the statement for the second. That
is how Karen Nguyen's second quote is blocked:

```text
$ sqlite3 -header -column followup.sqlite3 "SELECT id, customer_name, customer_phone, status, amount FROM quotes WHERE customer_phone = '+19175552003'"
id      customer_name  customer_phone  status  amount
------  -------------  --------------  ------  ------
Q-1003  Karen Nguyen   +19175552003    open    850   
Q-1025  Karen Nguyen   +19175552003    open    850
```

```text
$ bin/followup send --now 2026-08-17T09:00:00Z
send at 2026-08-17T09:00:00Z: 24 processed, 23 sent, 0 failed, 1 blocked, 0 skipped
  #24 blocked: cooldown: customer last contacted at 2026-08-17T09:00:00Z, within 3 days of 2026-08-17T09:00:00Z
```

Running the statement over all approved rows at once would let both of her
rows pass, because neither would be `sent` when the conditions were evaluated.

### What the statement does not cover

- **The per-quote cap and the 60-day limit** are policy exclusions only. A row
  drafted before the cap was reached can still be sent.
- **A hand-written `UPDATE`** from `approved` to `sent` passes the transition
  trigger without going through these conditions. The trigger enforces the
  state machine for every writer. The cooldown and closed-quote rules are
  enforced for everything that sends through `GUARDED_SEND`, which is the only
  send path in the code.
- **Delivery inside the transaction** is sound for one process on SQLite. With
  a real provider the transaction would be held open across a network call.
  The README section "In production" describes the `sending` status that would
  replace it.

## The idempotency key

Format: `quote_id:reason:ISO-week`, with the ISO week written as year and week
number, taken from the "now" of the draft run.

```text
$ bin/followup outbox | head -9
outbox: 51 rows  blocked=2 sent=49
#1   sent     112.5  Q-1016  Ray Klein        replied_unanswered  tries=1 sent_at=2026-08-17T09:00:00Z
       key: Q-1016:replied_unanswered:2026-W34
       msg: Hi Ray, Jaden here. Sorry for the slow reply on your $12,500 quote. I have your message and I'm around today. What's the best time to talk it through?
#2   sent     105.2  Q-1007  Emily Patel      replied_unanswered  tries=1 sent_at=2026-08-17T09:00:00Z
       key: Q-1007:replied_unanswered:2026-W34
       msg: Hi Emily, Brad here. Sorry for the slow reply on your $5,200 quote. I have your message and I'm around today. What's the best time to talk it through?
#3   sent     103.8  Q-1015  Angela Ortiz     replied_unanswered  tries=1 sent_at=2026-08-17T09:00:00Z
       key: Q-1015:replied_unanswered:2026-W34
```

| Action | What happens | Why |
|---|---|---|
| Draft again in the same week | No new row | The insert is `ON CONFLICT (idempotency_key) DO NOTHING` |
| Insert a duplicate by hand | Rejected | The column is `UNIQUE` |
| Send again | Nothing to process | The rows are no longer `approved` |
| Retry | The same row is tried again | Retry selects `failed` rows. It creates nothing, and the key does not change. |
| Draft in a later week | A new row with a new key | The week is part of the key, so the same reason can produce a new follow-up |

```text
$ bin/followup draft --now 2026-08-17T09:00:00Z
draft at 2026-08-17T09:00:00Z (2026-W34): 0 created, 24 already drafted
```

```text
$ sqlite3 followup.sqlite3 "INSERT INTO outbox (quote_id, customer_phone, reason, score, body, idempotency_key, created_at) SELECT quote_id, customer_phone, reason, score, body, idempotency_key, created_at FROM outbox WHERE id = 1"
Error: stepping, UNIQUE constraint failed: outbox.idempotency_key (19)
```

```text
$ bin/followup draft --now 2026-08-24T09:00:00Z
draft at 2026-08-24T09:00:00Z (2026-W35): 27 created, 0 already drafted
```

Why ISO week: a follow-up for the same reason is worth repeating eventually,
but not within days. A week bucket gives a key that is computed from "now"
alone, with no lookup of earlier rows, and it is the same on every re-run
inside that week.

Once messages have been sent, drafting again in the same week reports nothing
to draft, because every customer is in cooldown and the policy returns no
candidates:

```text
$ bin/followup draft --now 2026-08-17T09:00:00Z
draft at 2026-08-17T09:00:00Z (2026-W34): 0 created, 0 already drafted
```

**Limitations.**

- Week boundaries are arbitrary. A draft on Sunday and another on Monday are in
  different weeks. The cooldown still blocks the second send.
- A `blocked` or `failed` row keeps its key. The same follow-up cannot be
  drafted again until the next week.
- The key stops duplicate drafts. It does not limit how many follow-ups a quote
  gets over time. The per-quote cap in the policy does that.

## The now parameter

### Why it exists

The engine never reads the wall clock. Every command that depends on time
takes `--now`, and refuses to run without it. The same database and the same
`--now` give the same output on any day, which is what makes the captured
outputs in these documents checkable. It also lets the policy be run "as of"
an earlier moment.

### What it filters

| Input | Filter |
|---|---|
| Events | Only events with a timestamp at or before `now` are folded |
| Quotes | Only quotes created at or before `now` are considered |
| Snapshot `last_contact_at` | Counted as a contact only if at or before `now` |
| Quote age and quiet periods | Measured back from `now` |

### What it does not filter

| Input | Behaviour | Why |
|---|---|---|
| Snapshot status | A closed status holds at every `now` | The snapshot gives no closed-at time |
| Messages this engine sent | Always count, in the policy and at send | We know we sent them |

### The one place send ignores it

`GUARDED_SEND` uses `now` for two things: the `sent_at` stamp and the cooldown
cutoff. It does not use it as an upper bound. Any contact later than the
cutoff blocks the send, and any acceptance event blocks the send, including
ones with a timestamp after `now`.

The policy and the send statement therefore agree whenever `now` is at or
after the latest event, which is always the case in production. They differ
only when an earlier `now` is replayed. Then the policy shows what was known
at that moment, and send refuses to act against what is known today.

Q-1019 shows the difference. At A the policy lists her as `replied_unanswered`,
because the `message_sent` event dated 08-14 is after A:

```text
$ sqlite3 -header -column replay.sqlite3 "SELECT quote_id, ts, type FROM events WHERE quote_id = 'Q-1019' ORDER BY ts"
quote_id  ts                    type            
--------  --------------------  ----------------
Q-1019    2026-08-09T22:00:00Z  quote_sent      
Q-1019    2026-08-12T16:00:00Z  quote_viewed    
Q-1019    2026-08-12T21:00:00Z  customer_replied
Q-1019    2026-08-14T14:00:00Z  message_sent
```

Drafting, approving and sending at A, on a separate database:

```text
$ FOLLOWUP_DB=replay.sqlite3 bin/followup ingest | tail -2 && FOLLOWUP_DB=replay.sqlite3 bin/followup draft --now 2026-08-13T09:00:00Z && FOLLOWUP_DB=replay.sqlite3 bin/followup approve --all
inserted                       82
already stored                 0
draft at 2026-08-13T09:00:00Z (2026-W33): 19 created, 0 already drafted
approved 19
```

```text
$ FOLLOWUP_DB=replay.sqlite3 bin/followup send --now 2026-08-13T09:00:00Z
send at 2026-08-13T09:00:00Z: 19 processed, 17 sent, 0 failed, 2 blocked, 0 skipped
  #3 blocked: cooldown: customer last contacted at 2026-08-14T14:00:00Z, within 3 days of 2026-08-13T09:00:00Z
  #19 blocked: cooldown: customer last contacted at 2026-08-13T09:00:00Z, within 3 days of 2026-08-13T09:00:00Z
```

```text
$ sqlite3 -header -column replay.sqlite3 "SELECT id, quote_id, status FROM outbox WHERE status = 'blocked'"
id  quote_id  status 
--  --------  -------
3   Q-1019    blocked
19  Q-1003    blocked
```

Q-1019 is blocked by the 08-14 contact that the policy at A could not see.
Q-1003 is Karen Nguyen's second quote, blocked by the message sent to her a
moment earlier in the same run.
