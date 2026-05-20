# frozen_string_literal: true

require_relative 'chat_tool_hints'

module ChatBackend
  AgentSpec = Data.define(:name, :display_name, :model, :system_prompt, :temperature, :tools) do
    include ChatApp::ToolHints

    def label
      display_name.to_s.strip.empty? ? name.to_s : display_name.to_s
    end

    def tool_names
      Array(tools).filter_map do |tool|
        if tool.respond_to?(:tool_name) && !tool.tool_name.to_s.strip.empty?
          tool.tool_name.to_s
        elsif tool.respond_to?(:name) && tool.class < RubyLLM::Tool
          tool.name.to_s
        else
          tool.to_s
        end
      end
    end

    def tool_classes
      Array(tools).filter_map { |tool| ChatBackend.tool_class_for(tool) }
    end

    def tool_classes_for_feature(feature)
      tool_classes.select do |tool_class|
        tool_class.respond_to?(:supports_feature?) && tool_class.supports_feature?(feature)
      end
    end

    def tool_classes_for_features(features)
      feature_list = Array(features).flatten.compact.map(&:to_sym).uniq
      return tool_classes if feature_list.empty?

      tool_classes.select do |tool_class|
        feature_list.any? { |feature| tool_class.respond_to?(:supports_feature?) && tool_class.supports_feature?(feature) }
      end
    end

    def tool_classes_for_input(text)
      feature_list = tool_hints_for(text)
      selected = tool_classes_for_feature(:baseline)
      selected = tool_classes if selected.empty? && feature_list.empty?
      selected += tool_classes_for_features(feature_list) if feature_list.any?
      selected = tool_classes if selected.empty?
      selected.uniq
    end
  end
end
