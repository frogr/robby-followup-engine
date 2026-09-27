# Robby take-home: follow-up engine

For a given "now", decide which open quotes deserve a follow-up, draft the
message, and move it through draft, approve and send into an outbox. Nothing is
delivered. Plain Ruby, SQLite, one CLI.

## How to run

Needs Ruby 3.x and the `sqlite3` gem (`gem install sqlite3`). Minitest ships
with Ruby.

```sh
bin/test                 # 35 tests
rm -f followup.sqlite3   # start the demo from an empty database
```

`now` is always an argument. The engine never reads the wall clock, so every
command below gives the same output on any day.

The demo uses three times. The seed events run from 2026-08-01 to 2026-08-16.

| Name | Value | Why |
|---|---|---|
| A | `2026-08-13T09:00:00Z` | Mid-stream: later events are invisible |
| B | `2026-08-17T09:00:00Z` | After every event, ISO week 34 |
| C | `2026-08-24T09:00:00Z` | One week on, ISO week 35 |

```sh
bin/followup ingest
bin/followup ingest                                  # re-run: inserted 0

bin/followup candidates --now 2026-08-13T09:00:00Z   # 19 candidates
bin/followup candidates --now 2026-08-17T09:00:00Z   # 24 candidates

bin/followup draft --now 2026-08-17T09:00:00Z        # 24 created
bin/followup draft --now 2026-08-17T09:00:00Z        # 0 created, 24 already drafted
bin/followup approve --all                           # approved 24
bin/followup send --now 2026-08-17T09:00:00Z         # 23 sent, 1 blocked
bin/followup send --now 2026-08-17T09:00:00Z         # 0 processed

bin/followup draft --now 2026-08-24T09:00:00Z        # 27 created (new ISO week)
bin/followup approve --all                           # approved 27
bin/followup send --now 2026-08-24T09:00:00Z --fail  # 27 failed, 0 sent
bin/followup retry --now 2026-08-24T09:00:00Z        # 26 sent, 1 blocked
bin/followup retry --now 2026-08-24T09:00:00Z        # 0 processed

bin/followup outbox                                  # 51 rows: sent=49 blocked=2
```

What to look for:

- **The blocked row is Karen Nguyen.** She has two open quotes (Q-1003 and
  Q-1025). Both are drafted and approved. Q-1025 scores higher and is sent;
  Q-1003 is then inside her cooldown and is blocked. This happens on the plain
  send and again on the fail-then-retry path.
- **`send --fail` needs approved rows**, and after the first send there are
  none. The second half of the demo drafts again a week later, which also shows
  the ISO-week rule producing new follow-ups.
- `approve <id>` approves a single row.

## How state is modeled

Three tables and two views, all in `lib/followup/db.rb`.

| Table | Holds | Key point |
|---|---|---|
| `quotes` | The `quotes.json` snapshot | A closed quote is never reopened by a later snapshot |
| `events` | The webhook stream | Primary key is the dedup key; ingest is `INSERT OR IGNORE` |
| `outbox` | Drafted messages and their delivery state | `UNIQUE` idempotency key, status transitions enforced by trigger |

Quote state is not stored. It is derived each run by folding the events with
timestamp at or before `now`, in event-time order (`lib/followup/state.rb`).

The seed events all carry an `event_id`, so that is the dedup key. Events
without one fall back to `(type, quote_id, timestamp)`.

Outbox state machine:

```
pending -> approved -> sent      terminal
                    -> failed    delivery failed; retry picks these up
                    -> blocked   a guardrail refused; terminal
           failed   -> sent | blocked
```

### Where each guardrail is enforced

| Guardrail | Enforced by |
|---|---|
| No message without approval | Send only selects `approved`; the trigger rejects `pending -> sent` |
| Customer cooldown (3 days) | A condition of the send `UPDATE` itself |
| Never message a closed quote | A condition of the send `UPDATE` itself |
| Never draft the same follow-up twice | `UNIQUE (idempotency_key)` with `ON CONFLICT DO NOTHING` |
| Never send a row twice | `status = 'approved'` in the send `UPDATE`; `sent` is terminal by trigger |
| Outbox history is never lost | A trigger rejects `DELETE` |

The send boundary is one SQL statement, `GUARDED_SEND` in
`lib/followup/outbox.rb`. Rows are processed one at a time, highest score
first, each in its own transaction, so a row sent a moment ago counts against
the next row for the same customer.

The policy also skips closed quotes and customers in cooldown, but that is a
courtesy to the person approving. The send boundary is what is relied on.

**Idempotency key:** `quote_id:reason:ISO-week`, for example
`Q-1016:replied_unanswered:2026-W34`. A quote gets at most one follow-up per
reason per ISO week. The same reason in a later week is a new follow-up.

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

Excluded entirely: closed quotes, quotes older than 60 days, and customers
inside the cooldown. There is no cap on candidates per run.

**Cooldown:** 3 days per customer (by phone number), across all of their
quotes. A customer reply after our last contact lifts it, because they are
waiting on us. Our next send restarts it.

### Decisions the seed data forced

- **`quote_sent` is not a follow-up contact.** It is a fifth event type, one
  per quote, stamped at `created_at`. It is stored but does not start a
  cooldown or count as answering a reply.
- **Either source can close a quote, and nothing reopens it.** Q-1017 and
  Q-1009 are closed in `quotes.json` with no event. A closed status in the
  snapshot holds at every `now`; a `quote_accepted` event holds from its
  timestamp.
- **`last_contact_at` counts as a contact.** It disagrees with the
  `message_sent` events on 22 of 30 quotes, and 17 have no event at all. I
  treat it as one more outbound contact, because ignoring it would message
  people the shop already reached some other way.

### Policy and send differ on purpose

The policy is a pure function of `now`: events after `now` do not exist. The
send boundary is stricter: any contact or acceptance already in the database
blocks the send, whatever `now` is. The two only differ when replaying an
earlier `now`, and then the send errs toward not messaging.

### Other signals I would look for

TODO (author): trim or extend.

- Repeat views: three views in a day means more than one
- What the reply said: "too expensive" and "when can you start" need different messages
- Whether earlier follow-ups on this quote got any response
- Quote expiry date, if quotes have one
- Job type and season: a dead furnace in January is not a repaint
- The customer's usual channel and time of day

## Production notes

`deliver(row)` in `lib/followup/outbox.rb` is the seam for a real provider. It
returns on success and raises `DeliveryError` on failure.

Today the delivery call runs inside the send transaction, and a failure rolls
the `sent` status back. That is sound for one process on SQLite. With a real
provider I would:

- Add a `sending` status. Claim the row with the guarded `UPDATE`, commit, call
  the provider, then record `sent` or `failed`.
- Pass the idempotency key to the provider, so a crash between the provider
  accepting and us recording cannot produce a second text.
- Take `message_sent` and delivery receipts from the provider's webhooks, which
  lets the existing event fold confirm what was delivered.

## Where I stopped

What is built: ingest, state derivation, policy, templates, the outbox flow and
its guardrails, and 35 tests on the parts I consider risky.

Known limits:

- **No cap on follow-ups per quote.** A quiet open quote gets a check-in every
  week until it is 60 days old. In the demo, all 27 open quotes are drafted
  again at time C.
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

Not tested, by choice: score values and thresholds, template wording, CLI
argument parsing.

## Running this for 50 shops

TODO (author).

## What I would build next with another day

TODO (author).
