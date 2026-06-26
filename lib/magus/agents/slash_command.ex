defmodule Magus.Agents.SlashCommand do
  @moduledoc """
  Embedded resource representing a custom slash command defined by an agent.

  Each command has a `/name` that users type (or click from the menu),
  a title map with localized strings (e.g. `%{en: "...", de: "..."}`),
  and an instruction injected into the message before the LLM sees it.
  """

  use Ash.Resource,
    otp_app: :magus,
    data_layer: :embedded

  attributes do
    attribute :name, :string do
      allow_nil? false
      public? true
      constraints min_length: 1, max_length: 32
      description "Command name (used as /name)"
    end

    attribute :title, :map do
      allow_nil? false
      public? true
      description "Localized title map, e.g. %{en: \"Search the web\", de: \"Im Web suchen\"}"
    end

    attribute :instruction, :string do
      allow_nil? false
      public? true
      constraints min_length: 1
      description "Instruction text injected into the message for the LLM"
    end

    attribute :icon, :string do
      allow_nil? true
      public? true
      description "Optional icon identifier (e.g. hero-bell)"
    end
  end
end
