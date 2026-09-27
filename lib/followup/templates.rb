# frozen_string_literal: true

module Followup
  module Templates
    # One template per reason, so the message matches why we are writing.
    # The seed data has a tech name but no shop name, so the tech signs.
    TEMPLATES = {
      "replied_unanswered" =>
        "Hi %<first_name>s, %<tech>s here. Sorry for the slow reply on your %<amount>s quote. " \
        "I have your message and I'm around today. What's the best time to talk it through?",
      "viewed_no_reply" =>
        "Hi %<first_name>s, %<tech>s here. I saw you had a chance to look over the %<amount>s quote. " \
        "Any questions I can answer, or anything you'd like me to adjust?",
      "big_quote_cold" =>
        "Hi %<first_name>s, %<tech>s here. I know %<amount>s is a real decision, so no rush. " \
        "Happy to walk through the scope or talk options whenever suits you.",
      "generic_checkin" =>
        "Hi %<first_name>s, %<tech>s here, checking in on your %<amount>s quote. " \
        "Still interested? I can get you on the schedule whenever you're ready."
    }.freeze

    def self.render(candidate)
      format(TEMPLATES.fetch(candidate.reason),
             first_name: candidate.customer_name.to_s.split.first || "there",
             tech: candidate.tech_name.to_s.empty? ? "your technician" : candidate.tech_name,
             amount: Followup.money(candidate.amount))
    end
  end
end
