# Policy

Which quotes become follow-up candidates, in what order, and why. The code is
`lib/followup/policy.rb`. Every output block is a copy of a file in
`docs/captures/`, written by `ruby docs/capture.rb` from an empty database.

Contents:

- [The constants block](#the-constants-block)
- [Exclusions, in the order they are checked](#exclusions-in-the-order-they-are-checked)
- [Skip reasons](#skip-reasons)
- [Signals](#signals)
- [Scoring](#scoring)
- [Worked examples](#worked-examples)
- [Message templates](#message-templates)
- [Other signals I would look for](#other-signals-i-would-look-for)
- [Limitations](#limitations)

## The constants block

Every threshold and weight is here, copied from the source:

```ruby
    # ---- Every threshold and weight lives here -------------------------------
    DAY = 86_400
    HOUR = 3_600

    COOLDOWN_DAYS      = 3     # per customer, across all of their quotes
    MAX_AGE_DAYS       = 60    # older quotes are never candidates
    MAX_FOLLOWUPS_PER_QUOTE = 3 # message_sent events plus our own sent messages;
                                # does not apply while a customer reply is unanswered
    VIEW_WINDOW_HOURS  = 48    # a view is "recent" for this long
    BIG_AMOUNT         = 2000  # dollars
    BIG_QUIET_DAYS     = 7     # big quote with no contact for this long
    GENERIC_QUIET_DAYS = 5     # any quote with no contact for this long

    # Tiers are spaced wider than the amount bonus, so a reason always outranks
    # the one below it and amount only orders quotes within a reason.
    BASE_SCORE = {
      "replied_unanswered" => 100,
      "viewed_no_reply"    => 70,
      "big_quote_cold"     => 50,
      "generic_checkin"    => 20
    }.freeze
    AMOUNT_POINTS_PER_1000 = 1
    AMOUNT_POINTS_CAP      = 15
    # ---------------------------------------------------------------------------
```

## Exclusions, in the order they are checked

A quote is tested against these in order. The first one that applies is the
skip reason that gets counted, and the rest are not evaluated.

| Order | Rule              | Exclusion applies when                                                                    | Skip reason                                      |
| ----- | ----------------- | ----------------------------------------------------------------------------------------- | ------------------------------------------------ |
| 0     | Not created yet   | The quote's `created_at` is after "now"                                                   | None. The quote is invisible and is not counted. |
| 1     | Closed            | The derived status is `accepted` or `dismissed`                                           | `closed`                                         |
| 2     | 60-day limit      | The quote was created more than 60 days before "now"                                      | `too_old`                                        |
| 3     | Per-quote cap     | The quote has had 3 or more follow-ups, and no customer reply is waiting                  | `max follow-ups reached`                         |
| 4     | Customer cooldown | We contacted this customer less than 3 days before "now", and they have not replied since | `cooldown`                                       |
| 5     | No signal         | None of the four signals below matches                                                    | `no_signal`                                      |

### The per-quote cap

Follow-ups are counted per quote: `message_sent` events at or before "now" that
are not inbound, plus messages this engine has sent for that quote. The
snapshot's `last_contact_at` is not counted, because it records one moment and
says nothing about how many contacts there were.

### The reply exemption

The cap does not apply while a customer reply is waiting. A reply is waiting
when the quote has a `customer_replied` event later than its most recent
outbound contact, or has a reply and no outbound contact at all.

This is the same test the `replied_unanswered` signal uses, in one function, so
the exemption and the signal cannot disagree. A quote that is exempt from the
cap always comes out as `replied_unanswered`.

Once we answer, our message becomes the most recent outbound contact, the reply
is no longer waiting, and the cap applies again.

### The cooldown

The cooldown is per customer, identified by phone number, across all of their
quotes. The last contact is the latest of:

- any `message_sent` event on any of their quotes
- the snapshot's `last_contact_at` on any of their quotes
- any message this engine sent them

A `customer_replied` event is not a contact by us. If the customer's latest
reply is later than our last contact, the cooldown is lifted. A contact exactly
3 days before "now" no longer blocks.

Two details differ between the two checks above, on purpose:

|                    | Per-quote cap exemption            | Cooldown lift                            |
| ------------------ | ---------------------------------- | ---------------------------------------- |
| Scope of the reply | This quote                         | Any of the customer's quotes             |
| Compared against   | This quote's last outbound contact | The customer's last contact on any quote |

### The 60-day limit

The oldest seed quote is under 30 days old at D, the latest "now" in the demo,
so this rule does not fire on the seed data and no test covers it:

```text
$ sqlite3 followup.sqlite3 "SELECT ROUND(julianday('2026-08-31T09:00:00Z') - julianday(MIN(created_at)), 1) || ' days' FROM quotes"
29.8 days
```

## Skip reasons

`bin/followup candidates` prints a count per skip reason on its last line.

| Skip reason              | Meaning                                                                            |
| ------------------------ | ---------------------------------------------------------------------------------- |
| `closed`                 | The quote is accepted or dismissed, from the snapshot or from an event             |
| `too_old`                | The quote is more than 60 days old                                                 |
| `max follow-ups reached` | The quote has had 3 follow-ups and the customer has not replied since the last one |
| `cooldown`               | The customer was contacted in the last 3 days and has not replied since            |
| `no_signal`              | The quote is open and eligible, but nothing about it calls for a follow-up yet     |

Every quote that exists at "now" is either a candidate or counted under one
skip reason. The seed data has 30 quotes, all created before A, so the
candidates and the skip counts add up to 30 in each of these:

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
$ bin/followup candidates --now 2026-08-31T09:00:00Z | sed -n '1,6p;$p'
candidates at 2026-08-31T09:00:00Z: 24
#   score  quote   customer           amount   reason              why
1   65.0   Q-1020  Walt Herrera       $18,000  big_quote_cold      $18,000 quote with no contact in 7.0 days
2   65.0   Q-1021  Judy Faulk         $22,000  big_quote_cold      $22,000 quote with no contact in 7.0 days
3   65.0   Q-1023  Tina Grady         $18,000  big_quote_cold      $18,000 quote with no contact in 7.0 days
4   65.0   Q-1026  Hank Crane         $22,000  big_quote_cold      $22,000 quote with no contact in 7.0 days
skipped: closed=3, max follow-ups reached=3
```

## Signals

Each eligible quote gets the first signal it matches, in this order. A quote
never has two reasons.

| Priority | Reason               | Matches when                                                                                                    | Threshold constants            | Base score |
| -------- | -------------------- | --------------------------------------------------------------------------------------------------------------- | ------------------------------ | ---------- |
| 1        | `replied_unanswered` | A customer reply is waiting, as defined above                                                                   | None                           | 100        |
| 2        | `viewed_no_reply`    | The last view was within 48 hours of "now", and there has been no reply and no outbound contact since that view | `VIEW_WINDOW_HOURS`            | 70         |
| 3        | `big_quote_cold`     | The amount is $2,000 or more, and the quiet period is 7 days or more                                            | `BIG_AMOUNT`, `BIG_QUIET_DAYS` | 50         |
| 4        | `generic_checkin`    | The quiet period is 5 days or more                                                                              | `GENERIC_QUIET_DAYS`           | 20         |

The quiet period runs from the quote's last outbound contact to "now". If
nobody has contacted the customer, it runs from the quote's `created_at`.

### Reason text

Each candidate carries a sentence explaining why it was picked. The parts in
braces are filled in.

| Reason               | Text                                                                    |
| -------------------- | ----------------------------------------------------------------------- |
| `replied_unanswered` | Customer replied {time since reply} ago and nobody has answered         |
| `viewed_no_reply`    | Viewed the quote {time since view} ago, no reply and no follow-up since |
| `big_quote_cold`     | {amount} quote with no contact in {quiet period}                        |
| `generic_checkin`    | No contact in {quiet period}, quote is {age} old                        |

Durations under two days are printed in whole hours. Longer ones are printed
in days to one decimal place.

### Why this order

A reply is a customer waiting on us, which is the most expensive thing to
ignore. A view is interest with a short shelf life. A large quote going quiet
is money at risk. Everything else is a routine check-in.

## Scoring

```text
bonus = min(amount / 1000 * AMOUNT_POINTS_PER_1000, AMOUNT_POINTS_CAP)
score = BASE_SCORE[reason] + bonus

for generic_checkin only:
  decay = max(1 - age_in_days / MAX_AGE_DAYS, 0)
  score = score * decay

score is rounded to one decimal place
```

- **The reason sets the tier.** The smallest gap between two base scores is
  larger than the largest possible bonus, so a quote in one tier always
  outranks every quote in the tier below.
- **The amount orders quotes inside a tier.** It cannot move a quote between
  tiers.
- **Age decay applies to `generic_checkin` only.** A routine check-in matters
  less as a quote ages. A reply, a view or a large amount matters regardless
  of age.
- **Ties break on quote id,** so the order is the same on every run.
- **There is no cap on the number of candidates per run.**

## Worked examples

Three quotes at B, one from each of three tiers. The arithmetic is computed by
`docs/capture.rb` from the constants and the stored quotes, then compared with
the score the policy returned.

```text
Q-1016  Ray Klein  $12,500  replied_unanswered
  why           Customer replied 11.5 days ago and nobody has answered
  base score    100
  amount bonus  min(12500 / 1000 * 1, 15) = 12.5
  age decay     not applied (generic_checkin only)
  score         100 + 12.5 = 112.5
  rounded       112.5
  policy says   112.5  (matches)

Q-1026  Hank Crane  $22,000  viewed_no_reply
  why           Viewed the quote 17h ago, no reply and no follow-up since
  base score    70
  amount bonus  min(22000 / 1000 * 1, 15) = 15
  age decay     not applied (generic_checkin only)
  score         70 + 15 = 85
  rounded       85
  policy says   85  (matches)

Q-1025  Karen Nguyen  $850  generic_checkin
  why           No contact in 6.9 days, quote is 6.9 days old
  base score    20
  amount bonus  min(850 / 1000 * 1, 15) = 0.85
  age           (2026-08-17T09:00:00Z - 2026-08-10T12:00:00Z) = 6.875 days
  age decay     1 - 6.875 / 60 = 0.8854
  score         (20 + 0.85) * 0.8854 = 18.461
  rounded       18.5
  policy says   18.5  (matches)
```

The same three quotes appear with those scores in the full list at B in
[verification.md](verification.md#candidates-at-a-b-c-and-d).

What each shows:

| Quote  | Shows                                                                    |
| ------ | ------------------------------------------------------------------------ |
| Q-1016 | The bonus below its cap                                                  |
| Q-1026 | The bonus at its cap: the amount would give 22 points and 15 are counted |
| Q-1025 | Age decay on a generic check-in                                          |

## Message templates

One template per reason, copied from `lib/followup/templates.rb`. The
placeholders are the customer's first name, the technician's name and the
amount.

```text
replied_unanswered
  Hi %<first_name>s, %<tech>s here. Sorry for the slow reply on your %<amount>s quote. I have your message and I'm around today. What's the best time to talk it through?

viewed_no_reply
  Hi %<first_name>s, %<tech>s here. I saw you had a chance to look over the %<amount>s quote. Any questions I can answer, or anything you'd like me to adjust?

big_quote_cold
  Hi %<first_name>s, %<tech>s here. I know %<amount>s is a real decision, so no rush. Happy to walk through the scope or talk options whenever suits you.

generic_checkin
  Hi %<first_name>s, %<tech>s here, checking in on your %<amount>s quote. Still interested? I can get you on the schedule whenever you're ready.
```

The seed data has a technician name and no shop name, so the technician signs.
Rendered examples from the demo run:

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

## Other signals I would look for

- What the reply said: "too expensive" and "when can you start" need different messages
- Repeat views: three views in a day means more than one
- Whether earlier follow-ups on this quote got any response

## Limitations

- **Thresholds are not tuned.** The values are reasoned guesses. There is no
  outcome data in the seed to tune them against.
- **Scores and thresholds have no tests.** The tests cover exclusions that
  protect customers, not ranking.
- **The cap is flat.** Three follow-ups, then no more unless the customer
  replies. Escalating spacing between touches would be better.
- **The cap and the 60-day limit are not enforced at send.** They decide what
  gets drafted. A row drafted before the cap was reached can still be sent.
- **Both of a customer's quotes can be candidates in the same run.** The
  cooldown at send lets one through and blocks the other.
- **The reply's content is not read.** A customer who replied "no thanks" is
  treated the same as one who replied "when can you start".
