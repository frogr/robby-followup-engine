# frozen_string_literal: true

# Produces every output block quoted in README.md and docs/*.md.
#
#   ruby docs/capture.rb
#
# It deletes followup.sqlite3, runs the demo from an empty database, and writes
# one file per command into docs/captures/. Shell captures start with the
# command that was run. Re-running gives the same files, apart from the random
# seed and timings in the test output.

require "open3"
require "fileutils"

ROOT = File.expand_path("..", __dir__)
OUT = File.join(ROOT, "docs", "captures")
$LOAD_PATH.unshift File.join(ROOT, "lib")
require "followup"

A = "2026-08-13T09:00:00Z"
B = "2026-08-17T09:00:00Z"
C = "2026-08-24T09:00:00Z"
D = "2026-08-31T09:00:00Z"

def write(name, text)
  File.write(File.join(OUT, "#{name}.txt"), text.rstrip + "\n")
  puts format("%-28s %3d lines", name, text.lines.size)
end

def shell(name, command)
  output, = Open3.capture2e("bash", "-c", command, chdir: ROOT)
  write(name, "$ #{command}\n#{output}")
end

def sql(name, statement)
  shell(name, %(sqlite3 followup.sqlite3 "#{statement}"))
end

def table(name, statement)
  shell(name, %(sqlite3 -header -column followup.sqlite3 "#{statement}"))
end

# The arithmetic behind one candidate's score, worked from the constants and
# checked against what the policy itself returned.
def score_walkthrough(candidate, quote, now)
  policy = Followup::Policy
  base = policy::BASE_SCORE.fetch(candidate.reason)
  bonus = [quote.amount / 1000.0 * policy::AMOUNT_POINTS_PER_1000, policy::AMOUNT_POINTS_CAP].min
  lines = ["#{quote.id}  #{quote.customer_name}  #{Followup.money(quote.amount)}  #{candidate.reason}",
           "  why           #{candidate.explanation}",
           "  base score    #{base}",
           "  amount bonus  min(#{quote.amount} / 1000 * #{policy::AMOUNT_POINTS_PER_1000}, " \
           "#{policy::AMOUNT_POINTS_CAP}) = #{bonus.round(3)}"]
  total = base + bonus
  if candidate.reason == "generic_checkin"
    age = (now - quote.created_at) / policy::DAY
    decay = 1.0 - age / policy::MAX_AGE_DAYS
    lines << "  age           (#{now.iso8601} - #{quote.created_at.iso8601}) = #{age.round(3)} days"
    lines << "  age decay     1 - #{age.round(3)} / #{policy::MAX_AGE_DAYS} = #{decay.round(4)}"
    lines << "  score         (#{base} + #{bonus.round(3)}) * #{decay.round(4)} = #{(total * decay).round(3)}"
    total *= decay
  else
    lines << "  age decay     not applied (generic_checkin only)"
    lines << "  score         #{base} + #{bonus.round(3)} = #{total.round(3)}"
  end
  lines << "  rounded       #{total.round(1)}"
  lines << "  policy says   #{candidate.score}  #{total.round(1) == candidate.score ? "(matches)" : "(MISMATCH)"}"
  lines.join("\n")
end

FileUtils.rm_rf(OUT)
FileUtils.mkdir_p(OUT)
FileUtils.rm_f(File.join(ROOT, "followup.sqlite3"))

# ---- ingest -------------------------------------------------------------------
shell "ingest_first", "bin/followup ingest"
shell "ingest_again", "bin/followup ingest"
table "seed_conflict_quotes",
      "SELECT id, status, created_at, last_contact_at FROM quotes WHERE id IN ('Q-1004','Q-1009','Q-1017') ORDER BY id"
table "seed_conflict_events",
      "SELECT quote_id, ts, type FROM events WHERE quote_id IN ('Q-1004','Q-1009','Q-1017') ORDER BY quote_id, ts"
shell "seed_duplicate_lines", "sort data/events.jsonl | uniq -d | wc -l"
table "seed_karen", "SELECT id, customer_name, customer_phone, status, amount FROM quotes WHERE customer_phone = '+19175552003'"

table "seed_event_types", "SELECT type, COUNT(*) AS events FROM events GROUP BY type ORDER BY type"
table "seed_time_range", "SELECT MIN(ts) AS first_event, MAX(ts) AS last_event FROM events"
table "seed_quote_status",
      "SELECT status, COUNT(*) AS quotes, MIN(created_at) AS first_created, MAX(created_at) AS last_created " \
      "FROM quotes GROUP BY status"
table "seed_last_contact",
      "SELECT COUNT(*) AS quotes, SUM(last_contact_at IS NOT latest) AS disagree, " \
      "SUM(last_contact_at IS NOT NULL AND latest IS NULL) AS contact_but_no_event, " \
      "SUM(last_contact_at IS NULL AND latest IS NOT NULL) AS event_but_no_contact, " \
      "SUM(last_contact_at < latest) AS event_is_later, SUM(last_contact_at > latest) AS snapshot_is_later " \
      "FROM (SELECT q.last_contact_at, (SELECT MAX(ts) FROM events e WHERE e.quote_id = q.id " \
      "AND e.type = 'message_sent') AS latest FROM quotes q)"
shell "seed_out_of_order",
      %q(ruby -rjson -e 't = File.readlines("data/events.jsonl").map { |l| JSON.parse(l)["timestamp"] }; ) +
      %q(puts "#{t.size} lines, #{t.each_cons(2).count { |a, b| b < a }} adjacent pairs out of order"')

sql   "seed_orphan_events", "SELECT COUNT(*) FROM events WHERE quote_id NOT IN (SELECT id FROM quotes)"
sql   "seed_closed_without_event",
      "SELECT id || ' ' || status FROM quotes q WHERE status <> 'open' AND NOT EXISTS " \
      "(SELECT 1 FROM events e WHERE e.quote_id = q.id AND e.type = 'quote_accepted')"
sql   "seed_accepted_event_but_open",
      "SELECT COUNT(*) FROM quotes q WHERE status = 'open' AND EXISTS " \
      "(SELECT 1 FROM events e WHERE e.quote_id = q.id AND e.type = 'quote_accepted')"
sql   "seed_oldest_quote_age_at_d",
      "SELECT ROUND(julianday('#{D}') - julianday(MIN(created_at)), 1) || ' days' FROM quotes"

table "seed_directions", "SELECT type, direction, COUNT(*) AS events FROM events WHERE type = 'message_sent' GROUP BY 1, 2"
table "seed_quote_sent",
      "SELECT COUNT(*) AS quote_sent_events, COUNT(DISTINCT e.quote_id) AS quotes_covered, " \
      "SUM(e.ts = q.created_at) AS stamped_at_created_at " \
      "FROM events e JOIN quotes q ON q.id = e.quote_id WHERE e.type = 'quote_sent'"
table "seed_phone_format",
      "SELECT COUNT(*) AS quotes, SUM(customer_phone GLOB '+1[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]') " \
      "AS plus_one_then_ten_digits FROM quotes"

# ---- policy, before anything is sent --------------------------------------------
shell "candidates_a", "bin/followup candidates --now #{A}"
shell "candidates_b", "bin/followup candidates --now #{B}"
shell "candidates_a_short", "bin/followup candidates --now #{A} | sed -n '1,6p;$p'"
shell "candidates_b_short", "bin/followup candidates --now #{B} | sed -n '1,6p;$p'"

db = Followup::DB.open(File.join(ROOT, "followup.sqlite3"))
now_b = Followup.time(B)
quotes = Followup::DB.quotes(db)
candidates = Followup::Policy.run(quotes, Followup::DB.events(db), now_b).candidates
walkthrough = %w[Q-1016 Q-1026 Q-1025].map do |id|
  score_walkthrough(candidates.find { |c| c.quote_id == id }, quotes.find { |q| q.id == id }, now_b)
end
write "score_walkthrough", walkthrough.join("\n\n")
db.close

# ---- outbox at B ----------------------------------------------------------------
shell "draft_b", "bin/followup draft --now #{B}"
shell "draft_b_again", "bin/followup draft --now #{B}"
sql   "reject_skip_approval", "UPDATE outbox SET status = 'sent' WHERE id = 1"
sql   "reject_duplicate_key",
      "INSERT INTO outbox (quote_id, customer_phone, reason, score, body, idempotency_key, created_at) " \
      "SELECT quote_id, customer_phone, reason, score, body, idempotency_key, created_at FROM outbox WHERE id = 1"
shell "send_unapproved", "bin/followup send --now #{B}"
shell "approve_b", "bin/followup approve --all"
shell "send_b", "bin/followup send --now #{B}"
shell "send_b_again", "bin/followup send --now #{B}"
shell "outbox_karen_b", "bin/followup outbox | awk '/^#/{show = /Karen Nguyen/} show'"
sql   "reject_sent_to_pending", "UPDATE outbox SET status = 'pending' WHERE id = 1"
sql   "reject_blocked_to_approved", "UPDATE outbox SET status = 'approved' WHERE status = 'blocked'"
sql   "reject_delete", "DELETE FROM outbox WHERE id = 1"
shell "draft_b_after_send", "bin/followup draft --now #{B}"

# ---- outbox at C: a new ISO week, a forced failure, a retry ------------------------
shell "candidates_c", "bin/followup candidates --now #{C}"
shell "draft_c", "bin/followup draft --now #{C}"
shell "approve_c", "bin/followup approve --all"
shell "send_c_fail", "bin/followup send --now #{C} --fail | head -4"
shell "outbox_status_after_fail", "bin/followup outbox | head -1"
table "outbox_failed_rows", "SELECT status, attempts, sent_at, last_error, COUNT(*) AS n FROM outbox GROUP BY 1, 2, 3, 4 ORDER BY 1, 2, 3"
shell "retry_c", "bin/followup retry --now #{C}"
shell "retry_c_again", "bin/followup retry --now #{C}"
table "outbox_attempts", "SELECT status, attempts, sent_at, COUNT(*) AS n FROM outbox GROUP BY 1, 2, 3 ORDER BY 3, 1, 2"

# ---- two weeks on: the cap --------------------------------------------------------
shell "candidates_d", "bin/followup candidates --now #{D}"
shell "candidates_d_short", "bin/followup candidates --now #{D} | sed -n '1,6p;$p'"
table "capped_quotes",
      "SELECT q.id, " \
      "(SELECT COUNT(*) FROM events e WHERE e.quote_id = q.id AND e.type = 'message_sent') AS message_sent_events, " \
      "(SELECT COUNT(*) FROM outbox o WHERE o.quote_id = q.id AND o.status = 'sent') AS sent_by_engine " \
      "FROM quotes q WHERE message_sent_events + sent_by_engine >= 3 ORDER BY q.id"

# ---- final state ------------------------------------------------------------------
shell "outbox_summary", "bin/followup outbox | head -1"
shell "outbox_first_rows", "bin/followup outbox | head -9"
shell "outbox_karen", "bin/followup outbox | awk '/^#/{show = /Karen Nguyen/} show'"
shell "outbox_full", "bin/followup outbox"
shell "schema", "sqlite3 followup.sqlite3 .schema"

# ---- replaying an earlier now, on a separate database ---------------------------------
REPLAY = "FOLLOWUP_DB=replay.sqlite3"
FileUtils.rm_f(File.join(ROOT, "replay.sqlite3"))
shell "replay_setup", "#{REPLAY} bin/followup ingest | tail -2 && #{REPLAY} bin/followup draft --now #{A} && " \
                      "#{REPLAY} bin/followup approve --all"
shell "replay_send_a", "#{REPLAY} bin/followup send --now #{A}"
shell "replay_blocked_rows",
      %(sqlite3 -header -column replay.sqlite3 "SELECT id, quote_id, status FROM outbox WHERE status = 'blocked'")
shell "replay_q1019_events",
      %(sqlite3 -header -column replay.sqlite3 "SELECT quote_id, ts, type FROM events WHERE quote_id = 'Q-1019' ORDER BY ts")
FileUtils.rm_f(File.join(ROOT, "replay.sqlite3"))

# ---- code quoted in the docs --------------------------------------------------------
write "guarded_send", Followup::Outbox::GUARDED_SEND
policy_source = File.readlines(File.join(ROOT, "lib/followup/policy.rb"))
first = policy_source.index { |line| line.include?("Every threshold and weight lives here") }
last = policy_source.index { |line| line.match?(/^\s+# -{60,}\s*$/) }
write "policy_constants", policy_source[first..last].join
write "templates", Followup::Templates::TEMPLATES.map { |reason, text| "#{reason}\n  #{text}" }.join("\n\n")

# ---- tests --------------------------------------------------------------------------
shell "test_counts", "grep -c 'def test_' test/*_test.rb"
shell "tests", "bin/test"
shell "tests_verbose", "bin/test --verbose"
shell "mutation_check", "ruby test/mutation_check.rb"
shell "git_log", "git log --reverse --format='%h  %ad  %s' --date=format:'%Y-%m-%d %H:%M'"
