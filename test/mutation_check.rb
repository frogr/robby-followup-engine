# frozen_string_literal: true

# Checks that the tests can fail. Each mutation weakens the code in memory,
# runs the whole suite against it, and reports which tests caught it.
# Nothing on disk is changed.
#
#   ruby test/mutation_check.rb            run every mutation
#   ruby test/mutation_check.rb NAME       run the suite under one mutation

MUTATIONS = {
  "no_cooldown" => "the cooldown condition is removed from the send statement",
  "no_closed"   => "the closed-quote conditions are removed from the send statement",
  "no_status"   => "the row status condition is removed from the send statement",
  "file_order"  => "events are kept in file order with no dedup and no sort"
}.freeze

def mutate_send(pattern, replacement)
  original = Followup::Outbox::GUARDED_SEND
  mutated = original.sub(pattern, replacement)
  raise "mutation did not change the send statement" if mutated == original

  Followup::Outbox.send(:remove_const, :GUARDED_SEND)
  Followup::Outbox.const_set(:GUARDED_SEND, mutated)
end

def apply(name)
  case name
  when "no_cooldown"
    mutate_send(/AND NOT EXISTS \(\s+SELECT 1 FROM customer_contacts.*\z/m, "AND :cutoff IS NOT NULL")
  when "no_closed"
    mutate_send(/AND EXISTS \(SELECT 1 FROM quotes.*?'quote_accepted'\)/m, "")
  when "no_status"
    mutate_send("AND status = :from", "AND :from IS NOT NULL")
  when "file_order"
    Followup::Events.singleton_class.send(:define_method, :normalize) do |raw|
      raw.filter_map { |hash| Followup::Events.parse(hash) }
    end
  else
    raise "unknown mutation #{name.inspect}"
  end
end

if ARGV.empty?
  caught_all = true
  MUTATIONS.each do |name, description|
    output = IO.popen(["ruby", __FILE__, name], err: %i[child out], &:read)
    caught = output.scan(/^(\w+Test#test_\w+)/).flatten.uniq.sort
    caught_all &&= caught.any?
    puts "#{name}: #{description}"
    puts "  #{output[/^\d+ runs.*$/]}"
    puts caught.empty? ? "  NOT CAUGHT" : caught.map { |test| "  caught by #{test}" }
    puts
  end
  puts caught_all ? "all #{MUTATIONS.size} mutations caught" : "at least one mutation was not caught"
  exit(caught_all ? 0 : 1)
else
  $LOAD_PATH.unshift File.expand_path("../lib", __dir__)
  require "followup"
  apply(ARGV.shift)
  Dir.glob(File.expand_path("*_test.rb", __dir__)).sort.each { |file| require file }
end
