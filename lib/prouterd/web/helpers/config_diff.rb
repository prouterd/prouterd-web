require "diff/lcs"

module Prouterd
  module Web
    module Helpers
      # Line-oriented diff of two rendered configs, returned as a flat list
      # of rows ready for unified-diff rendering. Each row is one of:
      #
      #   { action: "=", text:, left_no:,  right_no: }   # context
      #   { action: "-", text:, left_no:,  right_no: nil } # removed
      #   { action: "+", text:, left_no: nil, right_no: }  # added
      #
      # Diff::LCS's "!" (changed in both) is expanded into a "-" + "+" pair
      # so the view doesn't need to special-case it.
      module ConfigDiff
        module_function

        def lines(left_text, right_text)
          left_lines  = (left_text  || "").split("\n")
          right_lines = (right_text || "").split("\n")

          Diff::LCS.sdiff(left_lines, right_lines).flat_map do |c|
            case c.action
            when "="
              [{ action: "=", text: c.old_element, left_no: c.old_position + 1, right_no: c.new_position + 1 }]
            when "-"
              [{ action: "-", text: c.old_element, left_no: c.old_position + 1, right_no: nil }]
            when "+"
              [{ action: "+", text: c.new_element, left_no: nil,                right_no: c.new_position + 1 }]
            when "!"
              [
                { action: "-", text: c.old_element, left_no: c.old_position + 1, right_no: nil },
                { action: "+", text: c.new_element, left_no: nil,                right_no: c.new_position + 1 }
              ]
            end
          end
        end
      end
    end
  end
end
