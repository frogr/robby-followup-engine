# Robby take-home: follow-up engine

For a given "now", this engine decides which open quotes deserve a follow-up,
drafts a message for each, and moves it through draft, approve and send into an
outbox. Nothing is delivered: the outbox table stands in for the SMS provider.
It is plain Ruby and SQLite with one CLI, and "now" is always an argument, so
every output here can be reproduced.

| Go deeper                                    | What it answers                                                     |
| -------------------------------------------- | ------------------------------------------------------------------- |
| [docs/architecture.md](docs/architecture.md) | Data flow, schema, state machine, the send statement, production    |
| [docs/policy.md](docs/policy.md)             | Every signal, threshold and weight, with worked scores              |
| [docs/verification.md](docs/verification.md) | Each guardrail, the tests that cover it, captured runs, test output |
| [docs/decisions.md](docs/decisions.md)       | Every judgment call, the alternative, and why                       |

## How to run it

Needs Ruby 3.x and the `sqlite3` gem.

```sh
git clone https://github.com/frogr/robby-followup-engine.git
cd robby-followup-engine
gem install sqlite3
bin/test
rm -f followup.sqlite3   # start from an empty database
```

The demo, with the summary line of each command. It uses four values of "now":
mid-stream, after every event, one week on, and two weeks on.

```text
$ bin/followup ingest
  inserted 82
$ bin/followup ingest
  inserted 0
$ bin/followup candidates --now 2026-08-13T09:00:00Z
  candidates at 2026-08-13T09:00:00Z: 19
  skipped: closed=3, cooldown=3, no_signal=5
$ bin/followup candidates --now 2026-08-17T09:00:00Z
  candidates at 2026-08-17T09:00:00Z: 24
  skipped: closed=3, cooldown=1, no_signal=2
$ bin/followup draft --now 2026-08-17T09:00:00Z
  draft at 2026-08-17T09:00:00Z (2026-W34): 24 created, 0 already drafted
$ bin/followup draft --now 2026-08-17T09:00:00Z
  draft at 2026-08-17T09:00:00Z (2026-W34): 0 created, 24 already drafted
$ bin/followup approve --all
  approved 24
$ bin/followup send --now 2026-08-17T09:00:00Z
  send at 2026-08-17T09:00:00Z: 24 processed, 23 sent, 0 failed, 1 blocked, 0 skipped
$ bin/followup send --now 2026-08-17T09:00:00Z
  send at 2026-08-17T09:00:00Z: 0 processed, 0 sent, 0 failed, 0 blocked, 0 skipped
$ bin/followup draft --now 2026-08-24T09:00:00Z
  draft at 2026-08-24T09:00:00Z (2026-W35): 27 created, 0 already drafted
$ bin/followup approve --all
  approved 27
$ bin/followup send --now 2026-08-24T09:00:00Z --fail | head -4
  send at 2026-08-24T09:00:00Z: 27 processed, 0 sent, 27 failed, 0 blocked, 0 skipped
$ bin/followup retry --now 2026-08-24T09:00:00Z
  retry at 2026-08-24T09:00:00Z: 27 processed, 26 sent, 0 failed, 1 blocked, 0 skipped
$ bin/followup retry --now 2026-08-24T09:00:00Z
  retry at 2026-08-24T09:00:00Z: 0 processed, 0 sent, 0 failed, 0 blocked, 0 skipped
$ bin/followup candidates --now 2026-08-31T09:00:00Z
  candidates at 2026-08-31T09:00:00Z: 24
  skipped: closed=3, max follow-ups reached=3
$ bin/followup outbox | head -1
  outbox: 51 rows blocked=2 sent=49
```

- **The blocked row is Karen Nguyen.** She has two open quotes. One is sent,
  and the other is then inside her cooldown.
- **Every re-run is a no-op:** the second ingest, the second draft, the second
  send and the second retry.
- **`--fail` then `retry`** delivers each message once.
- **The per-quote cap** first shows in the last `candidates` call.

This block and every output in `docs/` is copied from `docs/captures/`, which
`ruby docs/capture.rb` writes from an empty database. Full outputs are in
[docs/verification.md](docs/verification.md).

## Policy and why

Each open quote gets the first signal it matches:

| Priority | Reason               | Rule                                                                | Base score        |
| -------- | -------------------- | ------------------------------------------------------------------- | ----------------- |
| 1        | `replied_unanswered` | Customer replied and we have not contacted them since               | 100               |
| 2        | `viewed_no_reply`    | Viewed in the last 48h, with no reply and no contact since the view | 70                |
| 3        | `big_quote_cold`     | Amount at least $2,000 and no contact for 7 days                    | 50                |
| 4        | `generic_checkin`    | No contact for 5 days                                               | 20, scaled by age |

Why this order: a reply is a customer waiting on us, which is the most
expensive thing to ignore. A view is interest with a short shelf life. A large
quote going quiet is money at risk. Everything else is a routine check-in.

Closed quotes, quotes older than 60 days, quotes with 3 follow-ups and
customers contacted in the last 3 days are excluded. Exclusions, scoring and
other signals are in [docs/policy.md](docs/policy.md).

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

## Transcript

The full coding-agent conversation is in
[robby-transcript.md](robby-transcript.md).
