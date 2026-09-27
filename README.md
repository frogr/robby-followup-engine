# Robby take-home: follow-up engine

For a given "now", this engine decides which open quotes deserve a follow-up,
drafts a message for each, and moves it through draft, approve and send into an
outbox. Nothing is delivered: the outbox table stands in for the SMS provider,
behind the interface a real one would plug into. It is plain Ruby and SQLite
with one CLI, and "now" is always an argument, so every output below can be
reproduced.

Depth lives in `docs/`:

| Document | What it answers |
|---|---|
| [docs/architecture.md](docs/architecture.md) | Data flow, schema, the event fold, the outbox state machine, the send statement |
| [docs/policy.md](docs/policy.md) | Every signal, threshold and weight, with worked scores |
| [docs/verification.md](docs/verification.md) | Each guardrail, the test that covers it, and a captured run |
| [docs/decisions.md](docs/decisions.md) | Every judgment call, the alternative, and why |

## Quickstart

Needs Ruby 3.x and the `sqlite3` gem. Minitest ships with Ruby. The `sqlite3`
command line tool is only needed to re-run the documentation captures.

```sh
git clone <repo-url> robby && cd robby
gem install sqlite3
bin/test
rm -f followup.sqlite3   # start from an empty database
```

Every output block in this README and in `docs/` is a copy of a file in
`docs/captures/`. Those files are written by `ruby docs/capture.rb`, which
deletes the database and runs the sequence below from empty.

The demo uses four values of "now". The seed events run from 2026-08-01 to
2026-08-16.

| Name | Value | Why |
|---|---|---|
| A | `2026-08-13T09:00:00Z` | Mid-stream: later events are invisible |
| B | `2026-08-17T09:00:00Z` | After every event |
| C | `2026-08-24T09:00:00Z` | One week on, a new ISO week |
| D | `2026-08-31T09:00:00Z` | Two weeks on: the per-quote cap starts to bite |

### 1. Ingest

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

Running it again stores nothing new:

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

### 2. Who to follow up with

The first four rows and the skip summary at A and at B. The full lists are in
[docs/verification.md](docs/verification.md#candidates-at-a-b-c-and-d).

```text
$ bin/followup candidates --now 2026-08-13T09:00:00Z | sed -n '1,6p;$p'
candidates at 2026-08-13T09:00:00Z: 19
#   score  quote   customer           amount   reason              why
1   112.5  Q-1016  Ray Klein          $12,500  replied_unanswered  Customer replied 7.5 days ago and nobody has answered
2   105.2  Q-1007  Emily Patel        $5,200   replied_unanswered  Customer replied 2.9 days ago and nobody has answered
3   105.2  Q-1019  Gloria Sano        $5,200   replied_unanswered  Customer replied 12h ago and nobody has answered
4   103.8  Q-1015  Angela Ortiz       $3,800   replied_unanswered  Customer replied 38h ago and nobody has answered
skipped: closed=3, cooldown=3, no_signal=5
```

```text
$ bin/followup candidates --now 2026-08-17T09:00:00Z | sed -n '1,6p;$p'
candidates at 2026-08-17T09:00:00Z: 24
#   score  quote   customer           amount   reason              why
1   112.5  Q-1016  Ray Klein          $12,500  replied_unanswered  Customer replied 11.5 days ago and nobody has answered
2   105.2  Q-1007  Emily Patel        $5,200   replied_unanswered  Customer replied 6.9 days ago and nobody has answered
3   103.8  Q-1015  Angela Ortiz       $3,800   replied_unanswered  Customer replied 5.6 days ago and nobody has answered
4   85.0   Q-1026  Hank Crane         $22,000  viewed_no_reply     Viewed the quote 17h ago, no reply and no follow-up since
skipped: closed=3, cooldown=1, no_signal=2
```

Q-1019 is third at A and missing at B: a `message_sent` event dated 08-14
answered her reply and put her in cooldown.

### 3. Draft, approve, send

```text
$ bin/followup draft --now 2026-08-17T09:00:00Z
draft at 2026-08-17T09:00:00Z (2026-W34): 24 created, 0 already drafted
```

```text
$ bin/followup draft --now 2026-08-17T09:00:00Z
draft at 2026-08-17T09:00:00Z (2026-W34): 0 created, 24 already drafted
```

```text
$ bin/followup approve --all
approved 24
```

```text
$ bin/followup send --now 2026-08-17T09:00:00Z
send at 2026-08-17T09:00:00Z: 24 processed, 23 sent, 0 failed, 1 blocked, 0 skipped
  #24 blocked: cooldown: customer last contacted at 2026-08-17T09:00:00Z, within 3 days of 2026-08-17T09:00:00Z
```

```text
$ bin/followup send --now 2026-08-17T09:00:00Z
send at 2026-08-17T09:00:00Z: 0 processed, 0 sent, 0 failed, 0 blocked, 0 skipped
```

The blocked row is Karen Nguyen. She has two open quotes, both drafted and
approved. The higher score is sent first, and the second is then inside her
cooldown:

```text
$ bin/followup outbox | awk '/^#/{show = /Karen Nguyen/} show'
#21  sent     18.5   Q-1025  Karen Nguyen     generic_checkin     tries=1 sent_at=2026-08-17T09:00:00Z
       key: Q-1025:generic_checkin:2026-W34
       msg: Hi Karen, Jaden here, checking in on your $850 quote. Still interested? I can get you on the schedule whenever you're ready.
#24  blocked  15.4   Q-1003  Karen Nguyen     generic_checkin     tries=0 sent_at=-
       key: Q-1003:generic_checkin:2026-W34
       msg: Hi Karen, Jaden here, checking in on your $850 quote. Still interested? I can get you on the schedule whenever you're ready.
       err: cooldown: customer last contacted at 2026-08-17T09:00:00Z, within 3 days of 2026-08-17T09:00:00Z
```

### 4. A week later: a forced failure, then a retry

`send --fail` needs approved rows and step 3 left none, so this drafts again at
C. The new ISO week gives new idempotency keys.

```text
$ bin/followup draft --now 2026-08-24T09:00:00Z
draft at 2026-08-24T09:00:00Z (2026-W35): 27 created, 0 already drafted
```

```text
$ bin/followup approve --all
approved 27
```

```text
$ bin/followup send --now 2026-08-24T09:00:00Z --fail | head -4
send at 2026-08-24T09:00:00Z: 27 processed, 0 sent, 27 failed, 0 blocked, 0 skipped
  #25 failed: delivery failed (forced by --fail)
  #26 failed: delivery failed (forced by --fail)
  #27 failed: delivery failed (forced by --fail)
```

```text
$ bin/followup retry --now 2026-08-24T09:00:00Z
retry at 2026-08-24T09:00:00Z: 27 processed, 26 sent, 0 failed, 1 blocked, 0 skipped
  #51 blocked: cooldown: customer last contacted at 2026-08-24T09:00:00Z, within 3 days of 2026-08-24T09:00:00Z
```

```text
$ bin/followup retry --now 2026-08-24T09:00:00Z
retry at 2026-08-24T09:00:00Z: 0 processed, 0 sent, 0 failed, 0 blocked, 0 skipped
```

Karen's second quote is blocked again, this time on the retry path.

### 5. Two weeks later: the per-quote cap

```text
$ bin/followup candidates --now 2026-08-31T09:00:00Z | sed -n '1,6p;$p'
candidates at 2026-08-31T09:00:00Z: 24
#   score  quote   customer           amount   reason              why
1   65.0   Q-1020  Walt Herrera       $18,000  big_quote_cold      $18,000 quote with no contact in 7.0 days
2   65.0   Q-1021  Judy Faulk         $22,000  big_quote_cold      $22,000 quote with no contact in 7.0 days
3   65.0   Q-1023  Tina Grady         $18,000  big_quote_cold      $18,000 quote with no contact in 7.0 days
4   65.0   Q-1026  Hank Crane         $22,000  big_quote_cold      $22,000 quote with no contact in 7.0 days
skipped: closed=3, max follow-ups reached=3
```

```text
$ bin/followup outbox | head -1
outbox: 51 rows  blocked=2 sent=49
```

Other commands: `bin/followup approve <id>` approves one row, and
`bin/followup outbox` prints every row with its key, message and error.

## How it's built

**The event fold.** Events are stored once, keyed on `event_id`. Quote state is
never stored: each run folds the events dated at or before "now" into a status
and the last view, reply and contact per quote. File order plays no part.
Either the snapshot or an event can close a quote, and nothing reopens one.
See [the event fold](docs/architecture.md#the-event-fold).

**The policy.** A pure function of quotes, events and "now". It drops quotes
that are closed, too old, capped or in cooldown, gives each remaining quote the
first signal it matches, and scores it. Every threshold is in one constants
block. See [docs/policy.md](docs/policy.md).

**The outbox state machine.** `pending` to `approved` to one of `sent`,
`failed` or `blocked`. Retry picks up `failed` only. `sent` and `blocked` are
terminal. One trigger rejects every other transition and another rejects
deletes. See [the state machine](docs/architecture.md#the-outbox-state-machine).

**How the guardrails are enforced.** Sending is one SQL `UPDATE` whose
conditions are the row being approved, the quote being open and the customer
being outside the cooldown, so there is no gap between checking and sending.
Rows go one at a time, highest score first, each in its own transaction.
Duplicate drafts are stopped by a `UNIQUE` idempotency key. See
[the send statement](docs/architecture.md#the-send-statement) and
[docs/verification.md](docs/verification.md).

### In production

`deliver(row)` in `lib/followup/outbox.rb` is the seam for a real provider.
Today delivery runs inside the send transaction and a failure rolls the `sent`
status back, which is sound for one process on SQLite. With a real provider I
would add a `sending` status, pass the idempotency key to the provider so a
crash cannot produce a second text, and take delivery receipts from the
provider's webhooks into the existing event stream.

## Policy and why

Every threshold and weight is in the constants block at the top of
`lib/followup/policy.rb`.

Each open quote gets the first signal it matches:

| Priority | Reason | Rule | Base score |
|---|---|---|---|
| 1 | `replied_unanswered` | Customer replied and we have not contacted them since | 100 |
| 2 | `viewed_no_reply` | Viewed in the last 48h, with no reply and no contact since the view | 70 |
| 3 | `big_quote_cold` | Amount at least $2,000 and no contact for 7 days | 50 |
| 4 | `generic_checkin` | No contact for 5 days | 20, scaled by age |

Why this order: a reply is a customer waiting on us, which is the most
expensive thing to ignore. A view is interest with a short shelf life. A large
quote going quiet is money at risk. Everything else is a routine check-in.

Scoring details:

- **Amount bonus:** 1 point per $1,000, capped at 15. Base scores are spaced
  wider than the cap, so a reason always outranks the one below it and amount
  only orders quotes within a reason.
- **Age decay:** applies to `generic_checkin` only, linear from 1.0 at creation
  to 0.0 at 60 days.
- **Ties** break on quote id, so output order is stable.

Excluded entirely: closed quotes, quotes older than 60 days, quotes that have
already had 3 follow-ups, and customers inside the cooldown. Follow-ups are
counted per quote as `message_sent` events plus our own sent messages. The cap
does not apply while a customer reply is unanswered: a reply after our last
contact always makes the quote eligible as `replied_unanswered`. There is no
cap on candidates per run.

**Cooldown:** 3 days per customer (by phone number), across all of their
quotes. A customer reply after our last contact lifts it, because they are
waiting on us. Our next send restarts it.

### Decisions the seed data forced

- **`quote_sent` is not a follow-up contact.** It is the quote being delivered:
  one per quote, stamped at `created_at`.
- **Either source can close a quote, and nothing reopens it.** Q-1017 and
  Q-1009 are closed in the snapshot with no event.
- **`last_contact_at` counts as a contact.** 16 of 30 quotes record a contact
  in the snapshot with no `message_sent` event, so ignoring it would message
  people the shop had already reached.

The queries behind those counts are in
[docs/decisions.md](docs/decisions.md#what-the-seed-data-showed).

### Policy and send differ on purpose

The policy only sees events dated at or before `now`. Send is stricter: any
contact or acceptance in the database blocks it, whatever `now` is. They differ
only when an earlier `now` is replayed. See
[the now parameter](docs/architecture.md#the-now-parameter).

### Other signals I would look for

TODO (author): edit.

- What the reply said: "too expensive" and "when can you start" need different messages
- Repeat views: three views in a day means more than one
- Whether earlier follow-ups on this quote got any response

## Tests

Tests cover the three places where a mistake reaches a customer or corrupts
state, and nothing else.

| File | Covers | Why it is risky |
|---|---|---|
| `test/events_state_test.rb` | Dedup, ordering, closing a quote from either source | The input is messy by design, and a wrong fold makes every later decision wrong |
| `test/guardrails_test.rb` | Cooldown, closed quotes, duplicate drafts, the cap | The facts can change between approval and send |
| `test/send_idempotency_test.rb` | Re-run, retry, fail then retry, illegal transitions | A double send is the failure a customer sees |

The send tests count deliveries, not only row statuses.

```text
$ grep -c 'def test_' test/*_test.rb
test/events_state_test.rb:12
test/guardrails_test.rb:14
test/send_idempotency_test.rb:11
```

```text
$ bin/test
Run options: --seed 25450

# Running:

.....................................

Finished in 0.021882s, 1690.8875 runs/s, 4432.8672 assertions/s.

37 runs, 97 assertions, 0 failures, 0 errors, 0 skips
```

`test/mutation_check.rb` weakens the code four ways and runs the suite against
each, to check the tests can fail. All four are caught:
[output](docs/verification.md#mutation-check).

Not tested, by choice: score values and thresholds, template wording, CLI
argument parsing.

## Running this for 50 shops

The engine does not change. Its inputs do. Today the policy constants are one
block in one file; for a parent company they become configuration rows, with
defaults set at the parent level and overrides per shop for the cooldown, the
big-quote threshold, the quiet days, and which reason tiers are switched on at
all. Every table gets a shop id. Customer identity becomes shop plus phone, so
one person quoted by two shops is two customers, and one shop's follow-up does
not start a cooldown at the other. The idempotency key becomes shop, quote,
reason and week. Each shop sends from its own number, so outbox rows carry the
number they send from, and sends are queued per number, because carrier rate
limits and sender registration apply per number and not per company.

The bigger change is approval, which stops being a button and becomes a
per-shop policy. Some owners want to approve everything. Others want generic
check-ins sent automatically and only the big-quote messages put in front of
them. I would expose that as an autonomy level per reason tier, and only raise
it for a shop once that shop's approval rate on that tier is high enough to
justify it. The parent company will also want to know which shops' follow-ups
convert. A quote accepted after a sent follow-up is the outcome signal, and it
is how the weights get tuned per shop from results instead of by hand.

## What I would build next with another day

First, escalating backoff in place of the flat cap. Three follow-ups and then
silence is a blunt rule. Spacing the touches at 3, 7 and 14 days matches how a
person would chase a quote.

Second, a sending status and a real provider with a delivery webhook. Today a
message is either sent or not. With a real carrier there is a gap between "we
sent it" and "the carrier confirmed it", and a failure inside that gap has to
be recoverable without texting the customer twice.

Third, LLM drafting behind the template, with the template as the fallback
when the model is unavailable or its draft is rejected. I would grade it on
whether the owner approved the draft unedited or changed it first, since every
edit is free training signal about what that shop wants to sound like.

Fourth, STOP handling, quiet hours and a timezone per shop. These are the
rules that keep a shop out of trouble with carriers and customers, and the
current build has none of them. After that, a simple approval screen, since
owners will not use a CLI.

## Where I stopped

What is built: ingest, state derivation, policy, templates, the outbox flow and
its guardrails, and tests on the parts I consider risky.

Known limits:

- **The follow-up cap is flat.** Three per quote, then never again. The better
  version is escalating backoff between touches (3, 7, 14 days).
- **The cap is a policy exclusion only.** A row drafted before the cap was
  reached can still be sent.
- **A draft cannot be rejected.** There is no reject command. A draft nobody
  approves stays `pending` and is never sent.
- **Approved drafts do not expire.** A message approved today and sent next
  week passes the guardrails but may carry a stale reason.
- **A blocked or failed row holds its idempotency key.** That follow-up cannot
  be drafted again until the next ISO week.
- **ISO-week boundaries are arbitrary.** Sunday and Monday are in different
  weeks, so two drafts can be a day apart. The cooldown still blocks the second
  send.
- **The cooldown exists twice,** in Ruby for the policy and in SQL for the
  send. The tests cover the SQL one.
- **Customer identity is an exact phone string match.**
- **No opt-out handling and no quiet hours.** All times are UTC.
- **Dismissal only comes from the snapshot.** There is no dismissed event type
  in the data.
- **Templates do not read the customer's reply.**

## Transcript and time

The full coding-agent conversation is in
[robby-transcript.md](robby-transcript.md).

TODO (author): confirm the time spent. Steps 1 to 7 were committed between
10:56 and 11:53 on 2026-09-27. The reply exemption and the documentation in
`docs/` were written later the same day. The commit log is in
[docs/verification.md](docs/verification.md#commit-log).
