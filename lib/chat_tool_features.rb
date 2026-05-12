# frozen_string_literal: true

module ChatApp
  module ToolFeatures
    def features(*values)
      if values.empty?
        @features ||= []
      else
        @features = values.flatten.compact.map(&:to_sym).uniq.freeze
      end
    end

    def supports_feature?(name)
      feature = name.to_s.strip
      return false if feature.empty?

      features.include?(feature.to_sym)
    end

    alias feature? supports_feature?
  end
end
