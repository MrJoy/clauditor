# frozen_string_literal: true

# Clauditor reviews Claude Code session transcripts and reports token usage and
# estimated cost, grouped per project, per day, and per model.
module Clauditor
end

require_relative "clauditor/usage"
require_relative "clauditor/pricing"
require_relative "clauditor/project_normalizer"
require_relative "clauditor/aggregator"
require_relative "clauditor/session_loader"
require_relative "clauditor/store"
require_relative "clauditor/formatters"
require_relative "clauditor/crosstab"
require_relative "clauditor/cli"
