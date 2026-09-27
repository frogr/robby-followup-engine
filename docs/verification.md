# Verification

For each guardrail: the rule, the tests that cover it, and a captured run where
the seed data can show it.

Every output block is a copy of a file in `docs/captures/`. To reproduce them:

```sh
ruby docs/capture.rb
git diff docs/captures
```

`capture.rb` deletes `followup.sqlite3` and runs everything from an empty
database. The only expected differences are the random seed and the timings in
the two test outputs. It needs the `sqlite3` command line tool.

Contents:

- [Guardrail 1: customer cooldown](#guardrail-1-customer-cooldown)
- [Guardrail 2: never message a closed quote](#guardrail-2-never-message-a-closed-quote)
- [Guardrail 3: never double-send](#guardrail-3-never-double-send)
- [Guardrail 4: nothing is sent without approval](#guardrail-4-nothing-is-sent-without-approval)
- [Guardrail 5: the outbox is never rewritten or deleted](#guardrail-5-the-outbox-is-never-rewritten-or-deleted)
- [Guardrail 6: the per-quote cap and the reply exemption](#guardrail-6-the-per-quote-cap-and-the-reply-exemption)
- [Messy input: duplicates and ordering](#messy-input-duplicates-and-ordering)
- [Candidates at A, B, C and D](#candidates-at-a-b-c-and-d)
- [Full test run](#full-test-run)
- [Mutation check](#mutation-check)
- [Commit log](#commit-log)
- [What is not verified](#what-is-not-verified)

The four values of "now":

| Name | Value |
|---|---|
| A | `2026-08-13T09:00:00Z` |
| B | `2026-08-17T09:00:00Z` |
| C | `2026-08-24T09:00:00Z` |
| D | `2026-08-31T09:00:00Z` |

## Guardrail 1: customer cooldown

**Rule.** Never message a customer within 3 days of our last contact with
them. The cooldown is per customer, across all of their quotes. A reply from
the customer after our last contact lifts it.

**Enforced by.** A condition of the send statement. See
[architecture.md](architecture.md#the-send-statement).

**Tests,** all in `test/guardrails_test.rb`:

| Test | What it proves |
|---|---|
| `test_two_quotes_for_one_customer_send_one_and_block_the_other` | Two approved rows for one customer: one delivery, one block |
| `test_a_message_sent_event_that_lands_after_approval_blocks_the_send` | A contact that arrives between approval and send blocks the send |
| `test_cooldown_ends_exactly_three_days_after_the_last_contact` | One second inside the window blocks, exactly 3 days does not |
| `test_a_customer_reply_after_our_last_contact_lifts_the_cooldown` | A reply makes the customer eligible at once |
| `test_our_own_send_restarts_the_cooldown_even_after_a_reply` | After we answer, the cooldown applies again |
| `test_policy_skips_a_customer_contacted_on_another_quote` | The policy applies the same rule across a customer's quotes |

**Captured run.** Karen Nguyen has two open quotes on one phone number:

```text
$ sqlite3 -header -column followup.sqlite3 "SELECT id, customer_name, customer_phone, status, amount FROM quotes WHERE customer_phone = '+19175552003'"
id      customer_name  customer_phone  status  amount
------  -------------  --------------  ------  ------
Q-1003  Karen Nguyen   +19175552003    open    850   
Q-1025  Karen Nguyen   +19175552003    open    850
```

Both are candidates at B, both are drafted and approved. Send processes the
higher score first:

```text
$ bin/followup send --now 2026-08-17T09:00:00Z
send at 2026-08-17T09:00:00Z: 24 processed, 23 sent, 0 failed, 1 blocked, 0 skipped
  #24 blocked: cooldown: customer last contacted at 2026-08-17T09:00:00Z, within 3 days of 2026-08-17T09:00:00Z
```

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

The same thing happens a week later on the retry path. Both rows fail under
`--fail`, then retry sends one and blocks the other:

```text
$ bin/followup retry --now 2026-08-24T09:00:00Z
retry at 2026-08-24T09:00:00Z: 27 processed, 26 sent, 0 failed, 1 blocked, 0 skipped
  #51 blocked: cooldown: customer last contacted at 2026-08-24T09:00:00Z, within 3 days of 2026-08-24T09:00:00Z
```

```text
$ bin/followup outbox | awk '/^#/{show = /Karen Nguyen/} show'
#21  sent     18.5   Q-1025  Karen Nguyen     generic_checkin     tries=1 sent_at=2026-08-17T09:00:00Z
       key: Q-1025:generic_checkin:2026-W34
       msg: Hi Karen, Jaden here, checking in on your $850 quote. Still interested? I can get you on the schedule whenever you're ready.
#24  blocked  15.4   Q-1003  Karen Nguyen     generic_checkin     tries=0 sent_at=-
       key: Q-1003:generic_checkin:2026-W34
       msg: Hi Karen, Jaden here, checking in on your $850 quote. Still interested? I can get you on the schedule whenever you're ready.
       err: cooldown: customer last contacted at 2026-08-17T09:00:00Z, within 3 days of 2026-08-17T09:00:00Z
#47  sent     16.0   Q-1025  Karen Nguyen     generic_checkin     tries=2 sent_at=2026-08-24T09:00:00Z
       key: Q-1025:generic_checkin:2026-W35
       msg: Hi Karen, Jaden here, checking in on your $850 quote. Still interested? I can get you on the schedule whenever you're ready.
#51  blocked  12.9   Q-1003  Karen Nguyen     generic_checkin     tries=1 sent_at=-
       key: Q-1003:generic_checkin:2026-W35
       msg: Hi Karen, Jaden here, checking in on your $850 quote. Still interested? I can get you on the schedule whenever you're ready.
       err: cooldown: customer last contacted at 2026-08-24T09:00:00Z, within 3 days of 2026-08-24T09:00:00Z
```

## Guardrail 2: never message a closed quote

**Rule.** Never message a quote that is accepted or dismissed, whether the
snapshot or an event closed it.

**Enforced by.** Two conditions of the send statement: the quote is `open` in
the `quotes` table, and no `quote_accepted` event exists for it.

**Tests:**

| Test | File | What it proves |
|---|---|---|
| `test_a_quote_accepted_after_approval_is_blocked` | `test/guardrails_test.rb` | An acceptance event that arrives after approval blocks the send |
| `test_a_quote_dismissed_in_a_newer_snapshot_is_blocked` | `test/guardrails_test.rb` | A newer snapshot that dismisses the quote blocks the send |
| `test_blocked_is_terminal_and_retry_does_not_touch_it` | `test/guardrails_test.rb` | A blocked row is not picked up by send or retry, and cannot be re-approved |
| `test_retry_runs_the_same_guardrails_as_send` | `test/send_idempotency_test.rb` | A failed row whose quote has since been accepted is blocked on retry |
| `test_an_accepted_event_beats_an_open_status_in_the_snapshot` | `test/events_state_test.rb` | The policy does not list a quote that an event has accepted |
| `test_a_quote_closed_in_the_snapshot_stays_closed_with_no_event` | `test/events_state_test.rb` | The policy does not list a quote the snapshot has closed |
| `test_activity_after_acceptance_does_not_reopen_the_quote` | `test/events_state_test.rb` | Views and replies after acceptance do not reopen a quote |
| `test_a_later_snapshot_cannot_reopen_a_closed_quote` | `test/events_state_test.rb` | Re-ingesting a snapshot that says `open` does not reopen a closed quote |

**Captured run.** The seed data has three closed quotes. The policy skips all
three at every "now", shown as `closed=3` on the last line of each candidates
output below.

```text
$ sqlite3 -header -column followup.sqlite3 "SELECT id, status, created_at, last_contact_at FROM quotes WHERE id IN ('Q-1004','Q-1009','Q-1017') ORDER BY id"
id      status     created_at            last_contact_at     
------  ---------  --------------------  --------------------
Q-1004  accepted   2026-08-07T07:00:00Z  2026-08-09T17:00:00Z
Q-1009  dismissed  2026-08-09T02:00:00Z  2026-08-11T03:00:00Z
Q-1017  accepted   2026-08-04T05:00:00Z  2026-08-05T23:00:00Z
```

**No captured run for the send block.** Showing a block at send needs a quote
that closes between approval and send, and the seed data has none. The first
four tests above build that case.

## Guardrail 3: never double-send

**Rule.** Re-running any step, or retrying a failed send, never delivers a
message twice.

**Enforced by.** Three things:

- The `UNIQUE` idempotency key stops a second draft of the same follow-up.
- The send statement requires the row to be `approved`, or `failed` for a
  retry. A sent row matches neither.
- The transition trigger makes `sent` terminal.

**Tests,** all in `test/send_idempotency_test.rb` unless noted. They count
what a recording deliverer received.

| Test | What it proves |
|---|---|
| `test_sending_twice_delivers_once` | A second send processes nothing |
| `test_rerunning_the_whole_pipeline_delivers_nothing_more` | Ingest, draft, approve, send and retry, all run twice, deliver once per message |
| `test_a_failed_delivery_is_recorded_as_failed_and_never_as_sent` | A failed delivery leaves no `sent_at` and does not count as a contact |
| `test_fail_then_retry_delivers_each_message_exactly_once` | Fail, retry, retry again, send again: one delivery per message |
| `test_a_retry_that_fails_again_stays_failed_and_can_be_retried` | A second failure leaves the row retryable |
| `test_retry_only_picks_up_failed_rows` | Retry does not send approved rows |
| `test_a_stale_worker_cannot_resend_a_sent_row` | A second process holding an old row id, after the cooldown has passed, sends nothing |
| `test_drafting_again_in_the_same_week_creates_nothing` (`test/guardrails_test.rb`) | A re-run of draft creates no rows |
| `test_the_database_itself_rejects_a_duplicate_idempotency_key` (`test/guardrails_test.rb`) | The constraint holds against a direct insert |
| `test_the_same_reason_in_a_later_iso_week_is_a_new_follow_up` (`test/guardrails_test.rb`) | A later week produces a new key |

**Captured run: drafting twice.**

```text
$ bin/followup draft --now 2026-08-17T09:00:00Z
draft at 2026-08-17T09:00:00Z (2026-W34): 24 created, 0 already drafted
```

```text
$ bin/followup draft --now 2026-08-17T09:00:00Z
draft at 2026-08-17T09:00:00Z (2026-W34): 0 created, 24 already drafted
```

```text
$ sqlite3 followup.sqlite3 "INSERT INTO outbox (quote_id, customer_phone, reason, score, body, idempotency_key, created_at) SELECT quote_id, customer_phone, reason, score, body, idempotency_key, created_at FROM outbox WHERE id = 1"
Error: stepping, UNIQUE constraint failed: outbox.idempotency_key (19)
```

**Captured run: sending twice.**

```text
$ bin/followup send --now 2026-08-17T09:00:00Z
send at 2026-08-17T09:00:00Z: 24 processed, 23 sent, 0 failed, 1 blocked, 0 skipped
  #24 blocked: cooldown: customer last contacted at 2026-08-17T09:00:00Z, within 3 days of 2026-08-17T09:00:00Z
```

```text
$ bin/followup send --now 2026-08-17T09:00:00Z
send at 2026-08-17T09:00:00Z: 0 processed, 0 sent, 0 failed, 0 blocked, 0 skipped
```

**Captured run: fail, then retry, then retry again.** At C, a new ISO week,
27 rows are drafted and approved. `--fail` makes every delivery fail. Only the
first lines of that output are shown:

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
$ bin/followup outbox | head -1
outbox: 51 rows  blocked=1 failed=27 sent=23
```

Nothing was sent by that run. The 23 sent rows are from B, and the failed rows
have one attempt and no `sent_at`:

```text
$ sqlite3 -header -column followup.sqlite3 "SELECT status, attempts, sent_at, last_error, COUNT(*) AS n FROM outbox GROUP BY 1, 2, 3, 4 ORDER BY 1, 2, 3"
status   attempts  sent_at               last_error                                                                                        n 
-------  --------  --------------------  ------------------------------------------------------------------------------------------------  --
blocked  0                               cooldown: customer last contacted at 2026-08-17T09:00:00Z, within 3 days of 2026-08-17T09:00:00Z  1 
failed   1                               delivery failed (forced by --fail)                                                                27
sent     1         2026-08-17T09:00:00Z                                                                                                    23
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

The rows sent at C have two attempts, the failed one and the successful one,
and one `sent_at`:

```text
$ sqlite3 -header -column followup.sqlite3 "SELECT status, attempts, sent_at, COUNT(*) AS n FROM outbox GROUP BY 1, 2, 3 ORDER BY 3, 1, 2"
status   attempts  sent_at               n 
-------  --------  --------------------  --
blocked  0                               1 
blocked  1                               1 
sent     1         2026-08-17T09:00:00Z  23
sent     2         2026-08-24T09:00:00Z  26
```

Every outbox row after the demo, with its key, message and error, is in
`docs/captures/outbox_full.txt`.

## Guardrail 4: nothing is sent without approval

**Rule.** A draft is only sent after a human approves it.

**Enforced by.** Send selects `approved` rows only, and the transition trigger
rejects `pending` to `sent`.

**Tests,** in `test/send_idempotency_test.rb`:

| Test | What it proves |
|---|---|
| `test_nothing_is_sent_without_approval` | Send with only pending rows delivers nothing |
| `test_a_row_cannot_skip_approval` | The database rejects `pending` to `sent` |

**Captured run.** After drafting at B and before approving, send finds nothing
to do, and a direct update is rejected:

```text
$ bin/followup send --now 2026-08-17T09:00:00Z
send at 2026-08-17T09:00:00Z: 0 processed, 0 sent, 0 failed, 0 blocked, 0 skipped
```

```text
$ sqlite3 followup.sqlite3 "UPDATE outbox SET status = 'sent' WHERE id = 1"
Error: stepping, illegal outbox transition (19)
```

## Guardrail 5: the outbox is never rewritten or deleted

**Rule.** `sent` and `blocked` are terminal, and outbox rows are never
deleted. The outbox is the record of what was sent and what was refused.

**Enforced by.** The `outbox_transitions` and `outbox_no_delete` triggers.

**Tests:**

| Test | File | What it proves |
|---|---|---|
| `test_sent_is_terminal` | `test/send_idempotency_test.rb` | A sent row cannot move to any other status, and cannot be deleted |
| `test_blocked_is_terminal_and_retry_does_not_touch_it` | `test/guardrails_test.rb` | A blocked row cannot be re-approved |

**Captured run.** After the send at B:

```text
$ sqlite3 followup.sqlite3 "UPDATE outbox SET status = 'pending' WHERE id = 1"
Error: stepping, illegal outbox transition (19)
```

```text
$ sqlite3 followup.sqlite3 "UPDATE outbox SET status = 'approved' WHERE status = 'blocked'"
Error: stepping, illegal outbox transition (19)
```

```text
$ sqlite3 followup.sqlite3 "DELETE FROM outbox WHERE id = 1"
Error: stepping, outbox rows are never deleted (19)
```

## Guardrail 6: the per-quote cap and the reply exemption

**Rule.** A quote that has had 3 follow-ups is not a candidate again, unless
the customer has replied since our last contact.

**Enforced by.** The policy only. This is not checked at send. See
[policy.md](policy.md#exclusions-in-the-order-they-are-checked).

**Tests,** in `test/guardrails_test.rb`:

| Test | What it proves |
|---|---|
| `test_a_quote_with_three_follow_ups_is_never_a_candidate_again` | Three `message_sent` events cap a quote, and two events plus one of our own sends cap it too |
| `test_a_reply_after_the_third_follow_up_is_still_answered` | A reply after the third follow-up makes the quote a `replied_unanswered` candidate, and the cap returns once we answer |

**Captured run.** The cap first fires at D. Three quotes each have one
`message_sent` event in the seed data and were sent a message at B and at C:

```text
$ sqlite3 -header -column followup.sqlite3 "SELECT q.id, (SELECT COUNT(*) FROM events e WHERE e.quote_id = q.id AND e.type = 'message_sent') AS message_sent_events, (SELECT COUNT(*) FROM outbox o WHERE o.quote_id = q.id AND o.status = 'sent') AS sent_by_engine FROM quotes q WHERE message_sent_events + sent_by_engine >= 3 ORDER BY q.id"
id      message_sent_events  sent_by_engine
------  -------------------  --------------
Q-1005  1                    2             
Q-1012  1                    2             
Q-1027  1                    2
```

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

**No captured run for the reply exemption.** None of the three capped quotes
has a reply after its last contact. The second test above builds that case.

## Messy input: duplicates and ordering

**Rule.** Duplicated and out-of-order events do not change the result.

**Tests,** in `test/events_state_test.rb`:

| Test | What it proves |
|---|---|
| `test_a_repeated_event_id_is_stored_once` | Dedup on event id |
| `test_events_without_an_id_dedup_on_type_quote_and_timestamp` | The fallback key, which the seed data does not exercise |
| `test_events_are_ordered_by_event_time_not_file_order` | Output order is event time |
| `test_unusable_records_are_dropped_not_fatal` | A record with no quote id or a bad timestamp is skipped |
| `test_ingesting_the_same_events_again_stores_nothing_new` | Ingest is repeatable |
| `test_seed_file_has_88_lines_and_82_distinct_events_in_time_order` | The real seed file, ingested twice |
| `test_an_accepted_event_later_than_now_has_not_happened_yet` | Events after "now" are invisible |
| `test_file_order_does_not_decide_whether_a_reply_was_answered` | A reply that is first in the file and last in time is unanswered |

**Captured run.**

```text
$ sort data/events.jsonl | uniq -d | wc -l
       6
```

```text
$ ruby -rjson -e 't = File.readlines("data/events.jsonl").map { |l| JSON.parse(l)["timestamp"] }; puts "#{t.size} lines, #{t.each_cons(2).count { |a, b| b < a }} adjacent pairs out of order"'
88 lines, 41 adjacent pairs out of order
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
$ sqlite3 -header -column followup.sqlite3 "SELECT MIN(ts) AS first_event, MAX(ts) AS last_event FROM events"
first_event           last_event          
--------------------  --------------------
2026-08-01T15:00:00Z  2026-08-16T16:00:00Z
```

## Candidates at A, B, C and D

These are full outputs. A and B are taken before anything is drafted. C is
taken after the send at B. D is taken after the retry at C.

### A

```text
$ bin/followup candidates --now 2026-08-13T09:00:00Z
candidates at 2026-08-13T09:00:00Z: 19
#   score  quote   customer           amount   reason              why
1   112.5  Q-1016  Ray Klein          $12,500  replied_unanswered  Customer replied 7.5 days ago and nobody has answered
2   105.2  Q-1007  Emily Patel        $5,200   replied_unanswered  Customer replied 2.9 days ago and nobody has answered
3   105.2  Q-1019  Gloria Sano        $5,200   replied_unanswered  Customer replied 12h ago and nobody has answered
4   103.8  Q-1015  Angela Ortiz       $3,800   replied_unanswered  Customer replied 38h ago and nobody has answered
5   85.0   Q-1012  Carl Dawson        $18,000  viewed_no_reply     Viewed the quote 2h ago, no reply and no follow-up since
6   75.2   Q-1008  Frank Marino       $5,200   viewed_no_reply     Viewed the quote 31h ago, no reply and no follow-up since
7   70.9   Q-1025  Karen Nguyen       $850     viewed_no_reply     Viewed the quote 9h ago, no reply and no follow-up since
8   70.4   Q-1028  Sal Moss           $420     viewed_no_reply     Viewed the quote 19h ago, no reply and no follow-up since
9   65.0   Q-1021  Judy Faulk         $22,000  big_quote_cold      $22,000 quote with no contact in 7.1 days
10  62.5   Q-1010  Bill Boone         $12,500  big_quote_cold      $12,500 quote with no contact in 11.2 days
11  62.5   Q-1022  Ned Diaz           $12,500  big_quote_cold      $12,500 quote with no contact in 7.1 days
12  57.5   Q-1006  Jose Thompson      $7,500   big_quote_cold      $7,500 quote with no contact in 9.2 days
13  52.4   Q-1001  Susan Chen         $2,400   big_quote_cold      $2,400 quote with no contact in 9.5 days
14  52.4   Q-1013  Diane Lugo         $2,400   big_quote_cold      $2,400 quote with no contact in 8.8 days
15  26.5   Q-1024  Gus Lam            $9,800   generic_checkin     No contact in 6.6 days, quote is 6.6 days old
16  22.9   Q-1011  Rachel Ferreira    $5,200   generic_checkin     No contact in 5.1 days, quote is 5.5 days old
17  21.5   Q-1005  Linda Rivera       $3,800   generic_checkin     No contact in 5.0 days, quote is 5.8 days old
18  19.0   Q-1000  Mike Reilly        $850     generic_checkin     No contact in 5.3 days, quote is 5.3 days old
19  16.8   Q-1003  Karen Nguyen       $850     generic_checkin     No contact in 11.6 days, quote is 11.8 days old
skipped: closed=3, cooldown=3, no_signal=5
```

### B

```text
$ bin/followup candidates --now 2026-08-17T09:00:00Z
candidates at 2026-08-17T09:00:00Z: 24
#   score  quote   customer           amount   reason              why
1   112.5  Q-1016  Ray Klein          $12,500  replied_unanswered  Customer replied 11.5 days ago and nobody has answered
2   105.2  Q-1007  Emily Patel        $5,200   replied_unanswered  Customer replied 6.9 days ago and nobody has answered
3   103.8  Q-1015  Angela Ortiz       $3,800   replied_unanswered  Customer replied 5.6 days ago and nobody has answered
4   85.0   Q-1026  Hank Crane         $22,000  viewed_no_reply     Viewed the quote 17h ago, no reply and no follow-up since
5   70.9   Q-1000  Mike Reilly        $850     viewed_no_reply     Viewed the quote 36h ago, no reply and no follow-up since
6   65.0   Q-1012  Carl Dawson        $18,000  big_quote_cold      $18,000 quote with no contact in 10.3 days
7   65.0   Q-1021  Judy Faulk         $22,000  big_quote_cold      $22,000 quote with no contact in 11.1 days
8   65.0   Q-1027  Beth Vega          $18,000  big_quote_cold      $18,000 quote with no contact in 7.2 days
9   62.5   Q-1010  Bill Boone         $12,500  big_quote_cold      $12,500 quote with no contact in 15.2 days
10  62.5   Q-1022  Ned Diaz           $12,500  big_quote_cold      $12,500 quote with no contact in 11.1 days
11  59.8   Q-1024  Gus Lam            $9,800   big_quote_cold      $9,800 quote with no contact in 10.6 days
12  57.5   Q-1006  Jose Thompson      $7,500   big_quote_cold      $7,500 quote with no contact in 13.2 days
13  55.2   Q-1008  Frank Marino       $5,200   big_quote_cold      $5,200 quote with no contact in 12.0 days
14  55.2   Q-1011  Rachel Ferreira    $5,200   big_quote_cold      $5,200 quote with no contact in 9.1 days
15  55.2   Q-1014  Pete Whitman       $5,200   big_quote_cold      $5,200 quote with no contact in 8.2 days
16  53.8   Q-1005  Linda Rivera       $3,800   big_quote_cold      $3,800 quote with no contact in 9.0 days
17  53.8   Q-1029  Wanda Quinn        $3,800   big_quote_cold      $3,800 quote with no contact in 8.0 days
18  52.4   Q-1001  Susan Chen         $2,400   big_quote_cold      $2,400 quote with no contact in 13.5 days
19  52.4   Q-1013  Diane Lugo         $2,400   big_quote_cold      $2,400 quote with no contact in 12.8 days
20  31.2   Q-1023  Tina Grady         $18,000  generic_checkin     No contact in 5.8 days, quote is 6.5 days old
21  18.5   Q-1025  Karen Nguyen       $850     generic_checkin     No contact in 6.9 days, quote is 6.9 days old
22  18.1   Q-1028  Sal Moss           $420     generic_checkin     No contact in 6.9 days, quote is 6.9 days old
23  18.0   Q-1018  Stan Pruitt        $420     generic_checkin     No contact in 7.1 days, quote is 7.1 days old
24  15.4   Q-1003  Karen Nguyen       $850     generic_checkin     No contact in 15.6 days, quote is 15.8 days old
skipped: closed=3, cooldown=1, no_signal=2
```

### C

```text
$ bin/followup candidates --now 2026-08-24T09:00:00Z
candidates at 2026-08-24T09:00:00Z: 27
#   score  quote   customer           amount   reason              why
1   65.0   Q-1012  Carl Dawson        $18,000  big_quote_cold      $18,000 quote with no contact in 7.0 days
2   65.0   Q-1020  Walt Herrera       $18,000  big_quote_cold      $18,000 quote with no contact in 10.7 days
3   65.0   Q-1021  Judy Faulk         $22,000  big_quote_cold      $22,000 quote with no contact in 7.0 days
4   65.0   Q-1023  Tina Grady         $18,000  big_quote_cold      $18,000 quote with no contact in 7.0 days
5   65.0   Q-1026  Hank Crane         $22,000  big_quote_cold      $22,000 quote with no contact in 7.0 days
6   65.0   Q-1027  Beth Vega          $18,000  big_quote_cold      $18,000 quote with no contact in 7.0 days
7   62.5   Q-1002  Dave Okafor        $12,500  big_quote_cold      $12,500 quote with no contact in 10.5 days
8   62.5   Q-1010  Bill Boone         $12,500  big_quote_cold      $12,500 quote with no contact in 7.0 days
9   62.5   Q-1016  Ray Klein          $12,500  big_quote_cold      $12,500 quote with no contact in 7.0 days
10  62.5   Q-1022  Ned Diaz           $12,500  big_quote_cold      $12,500 quote with no contact in 7.0 days
11  59.8   Q-1024  Gus Lam            $9,800   big_quote_cold      $9,800 quote with no contact in 7.0 days
12  57.5   Q-1006  Jose Thompson      $7,500   big_quote_cold      $7,500 quote with no contact in 7.0 days
13  55.2   Q-1007  Emily Patel        $5,200   big_quote_cold      $5,200 quote with no contact in 7.0 days
14  55.2   Q-1008  Frank Marino       $5,200   big_quote_cold      $5,200 quote with no contact in 7.0 days
15  55.2   Q-1011  Rachel Ferreira    $5,200   big_quote_cold      $5,200 quote with no contact in 7.0 days
16  55.2   Q-1014  Pete Whitman       $5,200   big_quote_cold      $5,200 quote with no contact in 7.0 days
17  55.2   Q-1019  Gloria Sano        $5,200   big_quote_cold      $5,200 quote with no contact in 9.8 days
18  53.8   Q-1005  Linda Rivera       $3,800   big_quote_cold      $3,800 quote with no contact in 7.0 days
19  53.8   Q-1015  Angela Ortiz       $3,800   big_quote_cold      $3,800 quote with no contact in 7.0 days
20  53.8   Q-1029  Wanda Quinn        $3,800   big_quote_cold      $3,800 quote with no contact in 7.0 days
21  52.4   Q-1001  Susan Chen         $2,400   big_quote_cold      $2,400 quote with no contact in 7.0 days
22  52.4   Q-1013  Diane Lugo         $2,400   big_quote_cold      $2,400 quote with no contact in 7.0 days
23  16.0   Q-1025  Karen Nguyen       $850     generic_checkin     No contact in 7.0 days, quote is 13.9 days old
24  15.7   Q-1028  Sal Moss           $420     generic_checkin     No contact in 7.0 days, quote is 13.9 days old
25  15.6   Q-1018  Stan Pruitt        $420     generic_checkin     No contact in 7.0 days, quote is 14.1 days old
26  15.2   Q-1000  Mike Reilly        $850     generic_checkin     No contact in 7.0 days, quote is 16.3 days old
27  12.9   Q-1003  Karen Nguyen       $850     generic_checkin     No contact in 22.6 days, quote is 22.8 days old
skipped: closed=3
```

### D

```text
$ bin/followup candidates --now 2026-08-31T09:00:00Z
candidates at 2026-08-31T09:00:00Z: 24
#   score  quote   customer           amount   reason              why
1   65.0   Q-1020  Walt Herrera       $18,000  big_quote_cold      $18,000 quote with no contact in 7.0 days
2   65.0   Q-1021  Judy Faulk         $22,000  big_quote_cold      $22,000 quote with no contact in 7.0 days
3   65.0   Q-1023  Tina Grady         $18,000  big_quote_cold      $18,000 quote with no contact in 7.0 days
4   65.0   Q-1026  Hank Crane         $22,000  big_quote_cold      $22,000 quote with no contact in 7.0 days
5   62.5   Q-1002  Dave Okafor        $12,500  big_quote_cold      $12,500 quote with no contact in 7.0 days
6   62.5   Q-1010  Bill Boone         $12,500  big_quote_cold      $12,500 quote with no contact in 7.0 days
7   62.5   Q-1016  Ray Klein          $12,500  big_quote_cold      $12,500 quote with no contact in 7.0 days
8   62.5   Q-1022  Ned Diaz           $12,500  big_quote_cold      $12,500 quote with no contact in 7.0 days
9   59.8   Q-1024  Gus Lam            $9,800   big_quote_cold      $9,800 quote with no contact in 7.0 days
10  57.5   Q-1006  Jose Thompson      $7,500   big_quote_cold      $7,500 quote with no contact in 7.0 days
11  55.2   Q-1007  Emily Patel        $5,200   big_quote_cold      $5,200 quote with no contact in 7.0 days
12  55.2   Q-1008  Frank Marino       $5,200   big_quote_cold      $5,200 quote with no contact in 7.0 days
13  55.2   Q-1011  Rachel Ferreira    $5,200   big_quote_cold      $5,200 quote with no contact in 7.0 days
14  55.2   Q-1014  Pete Whitman       $5,200   big_quote_cold      $5,200 quote with no contact in 7.0 days
15  55.2   Q-1019  Gloria Sano        $5,200   big_quote_cold      $5,200 quote with no contact in 7.0 days
16  53.8   Q-1015  Angela Ortiz       $3,800   big_quote_cold      $3,800 quote with no contact in 7.0 days
17  53.8   Q-1029  Wanda Quinn        $3,800   big_quote_cold      $3,800 quote with no contact in 7.0 days
18  52.4   Q-1001  Susan Chen         $2,400   big_quote_cold      $2,400 quote with no contact in 7.0 days
19  52.4   Q-1013  Diane Lugo         $2,400   big_quote_cold      $2,400 quote with no contact in 7.0 days
20  13.6   Q-1025  Karen Nguyen       $850     generic_checkin     No contact in 7.0 days, quote is 20.9 days old
21  13.3   Q-1028  Sal Moss           $420     generic_checkin     No contact in 7.0 days, quote is 20.9 days old
22  13.2   Q-1018  Stan Pruitt        $420     generic_checkin     No contact in 7.0 days, quote is 21.1 days old
23  12.8   Q-1000  Mike Reilly        $850     generic_checkin     No contact in 7.0 days, quote is 23.3 days old
24  10.5   Q-1003  Karen Nguyen       $850     generic_checkin     No contact in 29.6 days, quote is 29.8 days old
skipped: closed=3, max follow-ups reached=3
```

### Reading them together

| Observation | Where | Cause |
|---|---|---|
| Q-1019 is third at A and absent at B | A, B | A `message_sent` event on 08-14 answered her reply and started a cooldown. It is after A and before B. |
| The three `replied_unanswered` quotes at B are `big_quote_cold` at C | B, C | Our send at B answered them. A week later they are large quotes with no contact for 7 days. |
| Nothing is skipped for cooldown at C or D | C, D | Every customer was last contacted at least 7 days earlier |
| 24 candidates at D, down from 27 at C | C, D | Three quotes reached the cap |

## Full test run

```text
$ grep -c 'def test_' test/*_test.rb
test/events_state_test.rb:12
test/guardrails_test.rb:14
test/send_idempotency_test.rb:11
```

```text
$ bin/test --verbose
Run options: --verbose --seed 54644

# Running:

SendIdempotencyTest#test_a_retry_that_fails_again_stays_failed_and_can_be_retried = 0.00 s = .
SendIdempotencyTest#test_nothing_is_sent_without_approval = 0.00 s = .
SendIdempotencyTest#test_a_failed_delivery_is_recorded_as_failed_and_never_as_sent = 0.00 s = .
SendIdempotencyTest#test_a_row_cannot_skip_approval = 0.00 s = .
SendIdempotencyTest#test_retry_only_picks_up_failed_rows = 0.00 s = .
SendIdempotencyTest#test_a_stale_worker_cannot_resend_a_sent_row = 0.00 s = .
SendIdempotencyTest#test_fail_then_retry_delivers_each_message_exactly_once = 0.00 s = .
SendIdempotencyTest#test_retry_runs_the_same_guardrails_as_send = 0.00 s = .
SendIdempotencyTest#test_sending_twice_delivers_once = 0.00 s = .
SendIdempotencyTest#test_sent_is_terminal = 0.00 s = .
SendIdempotencyTest#test_rerunning_the_whole_pipeline_delivers_nothing_more = 0.00 s = .
EventsStateTest#test_a_repeated_event_id_is_stored_once = 0.00 s = .
EventsStateTest#test_a_quote_closed_in_the_snapshot_stays_closed_with_no_event = 0.00 s = .
EventsStateTest#test_events_without_an_id_dedup_on_type_quote_and_timestamp = 0.00 s = .
EventsStateTest#test_ingesting_the_same_events_again_stores_nothing_new = 0.00 s = .
EventsStateTest#test_an_accepted_event_later_than_now_has_not_happened_yet = 0.00 s = .
EventsStateTest#test_a_later_snapshot_cannot_reopen_a_closed_quote = 0.00 s = .
EventsStateTest#test_file_order_does_not_decide_whether_a_reply_was_answered = 0.00 s = .
EventsStateTest#test_activity_after_acceptance_does_not_reopen_the_quote = 0.00 s = .
EventsStateTest#test_an_accepted_event_beats_an_open_status_in_the_snapshot = 0.00 s = .
EventsStateTest#test_seed_file_has_88_lines_and_82_distinct_events_in_time_order = 0.00 s = .
EventsStateTest#test_unusable_records_are_dropped_not_fatal = 0.00 s = .
EventsStateTest#test_events_are_ordered_by_event_time_not_file_order = 0.00 s = .
GuardrailsTest#test_a_reply_after_the_third_follow_up_is_still_answered = 0.00 s = .
GuardrailsTest#test_a_quote_accepted_after_approval_is_blocked = 0.00 s = .
GuardrailsTest#test_the_database_itself_rejects_a_duplicate_idempotency_key = 0.00 s = .
GuardrailsTest#test_a_message_sent_event_that_lands_after_approval_blocks_the_send = 0.00 s = .
GuardrailsTest#test_our_own_send_restarts_the_cooldown_even_after_a_reply = 0.00 s = .
GuardrailsTest#test_policy_skips_a_customer_contacted_on_another_quote = 0.00 s = .
GuardrailsTest#test_cooldown_ends_exactly_three_days_after_the_last_contact = 0.00 s = .
GuardrailsTest#test_a_customer_reply_after_our_last_contact_lifts_the_cooldown = 0.00 s = .
GuardrailsTest#test_drafting_again_in_the_same_week_creates_nothing = 0.00 s = .
GuardrailsTest#test_a_quote_dismissed_in_a_newer_snapshot_is_blocked = 0.00 s = .
GuardrailsTest#test_a_quote_with_three_follow_ups_is_never_a_candidate_again = 0.00 s = .
GuardrailsTest#test_the_same_reason_in_a_later_iso_week_is_a_new_follow_up = 0.00 s = .
GuardrailsTest#test_two_quotes_for_one_customer_send_one_and_block_the_other = 0.00 s = .
GuardrailsTest#test_blocked_is_terminal_and_retry_does_not_touch_it = 0.00 s = .

Finished in 0.022359s, 1654.8146 runs/s, 4338.2978 assertions/s.

37 runs, 97 assertions, 0 failures, 0 errors, 0 skips
```

## Mutation check

Passing tests prove little if they cannot fail. `test/mutation_check.rb`
weakens the code in memory in four ways and runs the whole suite against each.
Nothing on disk is changed.

| Mutation | What is weakened |
|---|---|
| `no_cooldown` | The cooldown condition is removed from the send statement |
| `no_closed` | Both closed-quote conditions are removed from the send statement |
| `no_status` | The row status condition is removed from the send statement |
| `file_order` | Events are kept in file order, with no dedup and no sort |

```text
$ ruby test/mutation_check.rb
no_cooldown: the cooldown condition is removed from the send statement
  37 runs, 91 assertions, 3 failures, 0 errors, 0 skips
  caught by GuardrailsTest#test_a_message_sent_event_that_lands_after_approval_blocks_the_send
  caught by GuardrailsTest#test_cooldown_ends_exactly_three_days_after_the_last_contact
  caught by GuardrailsTest#test_two_quotes_for_one_customer_send_one_and_block_the_other

no_closed: the closed-quote conditions are removed from the send statement
  37 runs, 90 assertions, 3 failures, 0 errors, 0 skips
  caught by GuardrailsTest#test_a_quote_accepted_after_approval_is_blocked
  caught by GuardrailsTest#test_a_quote_dismissed_in_a_newer_snapshot_is_blocked
  caught by SendIdempotencyTest#test_retry_runs_the_same_guardrails_as_send

no_status: the row status condition is removed from the send statement
  37 runs, 94 assertions, 0 failures, 1 errors, 0 skips
  caught by SendIdempotencyTest#test_a_stale_worker_cannot_resend_a_sent_row

file_order: events are kept in file order with no dedup and no sort
  37 runs, 95 assertions, 4 failures, 0 errors, 0 skips
  caught by EventsStateTest#test_a_repeated_event_id_is_stored_once
  caught by EventsStateTest#test_events_are_ordered_by_event_time_not_file_order
  caught by EventsStateTest#test_events_without_an_id_dedup_on_type_quote_and_timestamp
  caught by EventsStateTest#test_seed_file_has_88_lines_and_82_distinct_events_in_time_order

all 4 mutations caught
```

The first time this was run, `no_status` was not caught. Removing the status
condition did not cause a double send, because the row selection, the cooldown
and the transition trigger each stopped it. The test
`test_a_stale_worker_cannot_resend_a_sent_row` was added to isolate that
condition: it calls the send for an already-sent row after the cooldown has
passed. Under the mutation the trigger raises, so the mutation shows as an
error and not a failure.

This is four hand-picked mutations, not a mutation testing tool. It covers the
send statement and the event normalizer. It does not cover the policy.

## Commit log

At the time of the last capture run:

```text
$ git log --reverse --format='%h  %ad  %s' --date=format:'%Y-%m-%d %H:%M'
e634531  2026-09-27 10:56  Step 1: seed data, assignment PDF, data findings
7a00b8c  2026-09-27 11:24  Step 2: ingest and state derivation
3c6d7ed  2026-09-27 11:26  Step 3: follow-up policy and candidates command
e002ce5  2026-09-27 11:30  Step 4: outbox with draft, approve, send, retry and guarded send boundary
d850427  2026-09-27 11:33  Step 5: tests for dedup and ordering, the three guardrails, and idempotent send
da30f64  2026-09-27 11:34  Step 6: README skeleton with demo sequence, policy and where I stopped
2ce1698  2026-09-27 11:53  Step 7: per-quote follow-up cap, README sections for 50 shops and what is next
ca6653e  2026-09-27 17:58  Step 9: documentation in docs/ with captured output, reply exemption for the cap, mutation check
```

## What is not verified

- **Score values and thresholds.** No test asserts a score.
- **The 60-day limit.** No seed quote is old enough and no test covers it.
- **Template wording** and **CLI argument parsing.**
- **Concurrency.** The send statement is written to be safe with two
  processes, and the stale-worker test imitates one. No test runs two
  processes against one database.
- **A real delivery.** `deliver(row)` has two implementations: one that does
  nothing and one that always fails.
- **The policy's own cooldown check** has fewer tests than the send
  statement's. The send statement is the one relied on.
