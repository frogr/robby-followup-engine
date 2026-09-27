# Decisions

Every judgment call made while building this, with the alternative that was
considered and the reason for the choice. Where a choice has a cost, the cost
is stated.

Every output block is a copy of a file in `docs/captures/`, written by
`ruby docs/capture.rb` from an empty database.

Contents:

- [What the seed data showed](#what-the-seed-data-showed)
- [Reading the data](#reading-the-data)
- [Deriving quote state](#deriving-quote-state)
- [The outbox and the send boundary](#the-outbox-and-the-send-boundary)
- [The policy](#the-policy)
- [The cap and the reply exemption](#the-cap-and-the-reply-exemption)
- [Tests and documentation](#tests-and-documentation)
- [Corrections made along the way](#corrections-made-along-the-way)

## What the seed data showed

The brief described the data before it had been read. Several decisions below
come from what the files actually contain.

**Event types.** The brief lists four. The data has five. `quote_sent` appears
once per quote, stamped at the quote's `created_at`:

```text
$ sqlite3 -header -column followup.sqlite3 "SELECT type, COUNT(*) AS events FROM events GROUP BY type ORDER BY type"
type              events
----------------  ------
customer_replied  9     
message_sent      6     
quote_accepted    1     
quote_sent        30    
quote_viewed      36
```

```text
$ sqlite3 -header -column followup.sqlite3 "SELECT COUNT(*) AS quote_sent_events, COUNT(DISTINCT e.quote_id) AS quotes_covered, SUM(e.ts = q.created_at) AS stamped_at_created_at FROM events e JOIN quotes q ON q.id = e.quote_id WHERE e.type = 'quote_sent'"
quote_sent_events  quotes_covered  stamped_at_created_at
-----------------  --------------  ---------------------
30                 30              30
```

**Message direction.** Every `message_sent` event is outbound:

```text
$ sqlite3 -header -column followup.sqlite3 "SELECT type, direction, COUNT(*) AS events FROM events WHERE type = 'message_sent' GROUP BY 1, 2"
type          direction  events
------------  ---------  ------
message_sent  outbound   6
```

**Phone numbers.** All in one format:

```text
$ sqlite3 -header -column followup.sqlite3 "SELECT COUNT(*) AS quotes, SUM(customer_phone GLOB '+1[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]') AS plus_one_then_ten_digits FROM quotes"
quotes  plus_one_then_ten_digits
------  ------------------------
30      30
```

**Quotes.** Thirty, of which three are closed in the snapshot:

```text
$ sqlite3 -header -column followup.sqlite3 "SELECT status, COUNT(*) AS quotes, MIN(created_at) AS first_created, MAX(created_at) AS last_created FROM quotes GROUP BY status"
status     quotes  first_created         last_created        
---------  ------  --------------------  --------------------
accepted   2       2026-08-04T05:00:00Z  2026-08-07T07:00:00Z
dismissed  1       2026-08-09T02:00:00Z  2026-08-09T02:00:00Z
open       27      2026-08-01T15:00:00Z  2026-08-11T01:00:00Z
```

**Closed quotes and events.** Two of the three closed quotes have no closing
event. No quote is accepted by an event while open in the snapshot:

```text
$ sqlite3 followup.sqlite3 "SELECT id || ' ' || status FROM quotes q WHERE status <> 'open' AND NOT EXISTS (SELECT 1 FROM events e WHERE e.quote_id = q.id AND e.type = 'quote_accepted')"
Q-1009 dismissed
Q-1017 accepted
```

```text
$ sqlite3 followup.sqlite3 "SELECT COUNT(*) FROM quotes q WHERE status = 'open' AND EXISTS (SELECT 1 FROM events e WHERE e.quote_id = q.id AND e.type = 'quote_accepted')"
0
```

**`last_contact_at` against `message_sent` events.** For each quote, the
snapshot's `last_contact_at` compared with the latest `message_sent` event:

```text
$ sqlite3 -header -column followup.sqlite3 "SELECT COUNT(*) AS quotes, SUM(last_contact_at IS NOT latest) AS disagree, SUM(last_contact_at IS NOT NULL AND latest IS NULL) AS contact_but_no_event, SUM(last_contact_at IS NULL AND latest IS NOT NULL) AS event_but_no_contact, SUM(last_contact_at < latest) AS event_is_later, SUM(last_contact_at > latest) AS snapshot_is_later FROM (SELECT q.last_contact_at, (SELECT MAX(ts) FROM events e WHERE e.quote_id = q.id AND e.type = 'message_sent') AS latest FROM quotes q)"
quotes  disagree  contact_but_no_event  event_but_no_contact  event_is_later  snapshot_is_later
------  --------  --------------------  --------------------  --------------  -----------------
30      22        16                    2                     3               1
```

| Column | Meaning |
|---|---|
| `disagree` | The two values differ, counting a missing value as different |
| `contact_but_no_event` | The snapshot records a contact and there is no `message_sent` event |
| `event_but_no_contact` | There is a `message_sent` event and the snapshot records no contact |
| `event_is_later` | Both exist and the event is later |
| `snapshot_is_later` | Both exist and the snapshot is later |

**Duplicates and ordering.**

```text
$ sort data/events.jsonl | uniq -d | wc -l
       6
```

```text
$ ruby -rjson -e 't = File.readlines("data/events.jsonl").map { |l| JSON.parse(l)["timestamp"] }; puts "#{t.size} lines, #{t.each_cons(2).count { |a, b| b < a }} adjacent pairs out of order"'
88 lines, 41 adjacent pairs out of order
```

**Customers with more than one quote.** One:

```text
$ sqlite3 -header -column followup.sqlite3 "SELECT id, customer_name, customer_phone, status, amount FROM quotes WHERE customer_phone = '+19175552003'"
id      customer_name  customer_phone  status  amount
------  -------------  --------------  ------  ------
Q-1003  Karen Nguyen   +19175552003    open    850   
Q-1025  Karen Nguyen   +19175552003    open    850
```

**Events for unknown quotes.** None:

```text
$ sqlite3 followup.sqlite3 "SELECT COUNT(*) FROM events WHERE quote_id NOT IN (SELECT id FROM quotes)"
0
```

## Reading the data

| Decision | Alternative considered | Why |
|---|---|---|
| Dedup on the source `event_id`, falling back to type, quote id and timestamp when there is none | Always dedup on the content tuple | Every seed event has an id and the six duplicates are exact repeats, so the id is sufficient and is what a webhook provider guarantees. The fallback is kept for sources that send no id. |
| On a repeated key, keep the first event seen | Keep the last, or raise on a payload mismatch | The seed duplicates are identical, so the choice does not change any result. First-seen is what `INSERT OR IGNORE` does across runs, so the two dedup layers behave the same. Cost: a corrected re-delivery with the same id would be ignored. |
| Accept both `event_id` and `id`, and both `timestamp` and `ts` | Accept only the names in the seed file | The brief used `id` and `ts`, the data uses `event_id` and `timestamp`. Accepting both costs two lines. |
| Skip a record that has no type, no quote id or an unparseable timestamp | Stop the ingest | One bad webhook should not block the rest. The count of malformed lines is printed. Cost: skipped records are counted, not logged individually. |
| Store event types the fold does not know, and ignore them | Reject unknown types | `quote_sent` was not in the brief. Storing unknown types means nothing is lost if a later version wants them. |
| `quote_sent` is not a follow-up contact | Count it as a contact that starts the cooldown | It is stamped at `created_at` on every quote, so it is the quote being delivered, not someone chasing it. Counting it would also count against the per-quote cap. |
| `last_contact_at` counts as an outbound contact | Trust only `message_sent` events | Sixteen quotes record a contact in the snapshot with no event, which suggests contact by phone or in person. Ignoring it would message people the shop had just spoken to. Cost: if the field is unreliable, some customers wait longer than they need to. |
| `last_contact_at` does not count toward the per-quote cap | Count it as one follow-up | It records one moment and says nothing about how many contacts there were. The brief for the cap named `message_sent` events and sent outbox rows. |
| The customer is identified by phone number | Name, or name and phone | The cooldown is about not texting the same phone twice. Cost: it is an exact string match, so two formats of one number would be two customers. The seed data uses one format throughout. |
| Seed files are read from `./data` | `./seed`, as in the zip | The brief said `./data`. |

## Deriving quote state

| Decision | Alternative considered | Why |
|---|---|---|
| Quote state is derived on every run and never stored | Store a current status per quote and update it as events arrive | A stored status has to be corrected when a late event arrives. Deriving from the events at "now" cannot go stale, and the same rows answer "what was true at A" and "what is true at B". Cost: every run folds every event, which is fine at this size. |
| Either source can close a quote | Events only, or the snapshot only | The brief said events win over the snapshot, expecting quotes accepted by an event and open in the snapshot. The data has the opposite: closed in the snapshot with no event. Taking either source covers both. |
| Nothing reopens a closed quote | Let a later event or a later snapshot reopen it | The cost of wrongly treating a quote as closed is one missed follow-up. The cost of wrongly treating it as open is texting someone who already bought or declined. |
| A closed status in the snapshot holds at every "now" | Treat it as closed only from some estimated time | The snapshot has no closed-at field. Cost: replaying an early "now" shows Q-1004 as closed before its acceptance event. |
| A quote created after "now" is invisible | Include it | It did not exist yet. The same rule as for events. |
| A `message_sent` event with direction `inbound` is not a contact by us | Ignore the direction field | All six seed events are outbound, so this changes nothing today. It guards against a provider that reports inbound messages under the same type. |
| The engine's own sent messages count as contact on the quote, not only for the customer's cooldown | Count them for the cooldown only | Without this, a reply we had answered would be listed as `replied_unanswered` again the following week. |
| All timestamps are UTC strings of one width | Store as integers | The brief said UTC only. Fixed-width ISO strings compare correctly as text and are readable in the database. |

## The outbox and the send boundary

| Decision | Alternative considered | Why |
|---|---|---|
| The guardrails are conditions of the send `UPDATE` | Check in Ruby, then update | A check followed by a write leaves a gap in which another process can send or an acceptance can arrive. One statement has no gap. Cost: the cooldown is written twice, in Ruby for the policy and in SQL for the send. |
| `blocked` is a separate status from `failed` | Record a guardrail refusal as `failed` with the reason in `last_error` | The first design used `failed` for both. They mean different things: a failed delivery should be retried, a refused one should not. With one status, retry would keep picking up rows for accepted quotes. |
| `blocked` is terminal | Allow a blocked row to be re-approved | A row blocked for cooldown carries a message written for an earlier moment. A new draft next week is better than reviving the old one. Cost: the follow-up is lost for that week, because the row keeps its idempotency key. |
| A `failed` row can move to `blocked` | Only allow `failed` to `sent` | A quote can be accepted between the failure and the retry. Retry must be able to refuse. |
| Send processes one row per transaction, highest score first | One statement over all approved rows | With one statement, both of a customer's rows pass the cooldown, because neither is sent when the conditions are evaluated. One at a time, the first send is visible to the second. Score order means the more important message is the one that gets through. |
| Delivery runs inside the send transaction, and a failure rolls it back | Add a `sending` status and deliver after commit | It keeps the state machine to five statuses and means a row is never visibly sent and then un-sent. Cost: it is only sound for one process with no network call. A real provider needs the `sending` status. |
| The send statement has no upper bound on "now" | Apply the same "at or before now" filter as the policy | If the database holds a contact or an acceptance, sending against it is wrong whatever "now" was passed. The two only differ when replaying an earlier "now". Cost: the policy can list a candidate that send then blocks. |
| The state machine is enforced by a trigger | Enforce it in Ruby | The trigger applies to every writer, including a person at the SQLite prompt. |
| A trigger rejects deletes from the outbox | Allow deletes | The outbox is the record of what was sent and refused, and the cooldown reads it. Deleting a sent row would shorten a cooldown. |
| The idempotency key is quote, reason and ISO week | Quote and reason only, or quote, reason and day | From the brief. Quote and reason alone would allow one follow-up per reason for the life of the quote. A day bucket would allow one per day. Cost: week boundaries are arbitrary. |
| Draft uses `ON CONFLICT DO NOTHING` on the key | Look for an existing row, then insert | The constraint decides, so two draft runs at once cannot both insert. |
| The outbox stores the score | Recompute it at send time | Send needs an order, and the order should be the one the approver saw. |
| Two views for contacts and replies | A fourth table, or the same subqueries written inline | The brief allowed three tables. Views hold no data, and they keep the send statement short enough to read. |
| No reject command | Add `reject <id>` and a `rejected` status | Not in the brief's command list. Leaving a draft `pending` has the same effect on the customer. Cost: the draft stays in the outbox and holds its key. |
| `approve` takes no `--now` | Record an approved-at time | Approval does not depend on time in this design. Cost: there is no record of when a draft was approved, and approved drafts do not expire. |

## The policy

| Decision | Alternative considered | Why |
|---|---|---|
| A quote gets the first signal it matches | Add up points for every signal that matches | One reason per candidate gives one explanation and one template. A summed score is harder to explain to the person approving. |
| Base scores are spaced wider than the amount bonus | One blended score of urgency and amount | The reason always decides the tier. A large quote with a routine check-in never outranks a small quote whose customer is waiting on a reply. |
| Age decay applies to `generic_checkin` only | Decay every score | A reply or a recent view matters whatever the quote's age. Only the routine check-in loses value over time. |
| `viewed_no_reply` requires no outbound contact since the view | Only require no reply since the view | If we have already followed up on that view, the signal has been used. |
| The quiet period starts at `created_at` when nobody has contacted the customer | Start it at the `quote_sent` event, or treat never-contacted as always quiet | `quote_sent` and `created_at` are the same moment in the seed data. Starting at creation gives a new quote 5 days before its first check-in. |
| A customer reply lifts the cooldown | The cooldown always runs its full 3 days | From the brief. A customer who has replied is waiting on us. |
| A contact exactly 3 days old no longer blocks | Block at exactly 3 days | The brief said 3 days since last contact. A morning run at the same hour three days later should be allowed. |
| Both of a customer's quotes can be candidates | List one quote per customer | The brief asked for no cap on candidates. The send boundary allows one and blocks the other. Cost: the approver sees two drafts for one person. |
| The generic check-in threshold is 5 days | Any other number | It is longer than the cooldown and shorter than the big-quote threshold. It is a guess, not a tuned value. |
| Messages come from four fixed templates | One generic message, or a language model | From the brief. A template per reason lets the message match why we are writing. |

## The cap and the reply exemption

| Decision | Alternative considered | Why |
|---|---|---|
| A flat cap of 3 follow-ups per quote | No cap, or escalating spacing between touches | Without a cap, every quiet open quote was drafted again each week until it reached 60 days. A flat cap is the smallest fix. Cost: it is blunt. Escalating spacing is the better design and is listed as the next thing to build. |
| The cap is a policy exclusion and is not checked at send | Add it to the send statement | The cap is about not nagging, not about safety. The send statement keeps the two rules whose failure harms a customer. Cost: a row drafted before the cap was reached can still be sent. |
| The cap does not apply while a customer reply is waiting | Apply the cap regardless | The first version applied it regardless, which meant a customer who replied after the third follow-up was never answered. The cap limits chasing, not conversations. |
| The exemption and the `replied_unanswered` signal share one function | Write the condition twice | If they could differ, a quote could be exempt from the cap and then match no signal, or the reverse. |
| The exemption looks at this quote's replies and contacts | Use the customer's replies on any quote | The cap is per quote, so its exemption is too. The cooldown is per customer, so its reply rule is per customer. |
| The cap is checked before the cooldown | Cooldown first | A capped quote stays capped, while a cooldown ends. Reporting the lasting reason is more useful to the person reading the skip counts. |

## Tests and documentation

| Decision | Alternative considered | Why |
|---|---|---|
| Test dedup and ordering, the guardrails, and idempotent send, and nothing else | Cover the policy scores and the CLI as well | The brief asked for tests on the risky parts. These are the places where a mistake reaches a customer or corrupts state. |
| Guardrails are tested at the send boundary with a row that was approved before the facts changed | Test the policy's exclusions only | The policy is advisory. The realistic failure is the world changing between approval and send. |
| Tests count deliveries through a recording deliverer | Assert on row statuses only | "Never double-send" is a claim about what reached the customer. |
| Tests use an in-memory database | A file per test | No cleanup and no shared state between tests. |
| A mutation check, kept in the repository | Trust that passing tests are meaningful | All tests passed the first time they ran, which says nothing about whether they can fail. |
| Every output in the documents is copied from `docs/captures/` | Type the outputs into the documents | Typed numbers drift from the code. One of them already had. See the corrections below. |
| The demo includes a second draft at C | Follow the brief's sequence with one draft | After the first send there are no approved rows, so `send --fail` would have nothing to process. |
| The demo includes candidates at D | Stop at C | The cap does not fire at A, B or C. Without D the demo would not show it. |

## Corrections made along the way

| What was wrong | How it was found | What changed |
|---|---|---|
| An earlier README said 17 quotes had a snapshot contact with no `message_sent` event. The number is 16. | Replacing hand-written numbers with captured queries | The count is now taken from a query, shown at the top of this document |
| A reply answered by this engine was listed as `replied_unanswered` again the next week | Planning the demo at C | The engine's sent messages now count as contact on the quote |
| Removing the status condition from the send statement was not caught by any test | The mutation check | `test_a_stale_worker_cannot_resend_a_sent_row` was added |
| A customer who replied after the third follow-up was never answered | Review of the cap | The reply exemption was added |
| The message template produced a double full stop after "Jose M." | Reading the demo output | The templates were reworded so the name is not at the end of a sentence |
| The cooldown block message said "under 3 days before", which read wrongly for a contact later than "now" | Replaying a send at A | It now says "within 3 days of" |
