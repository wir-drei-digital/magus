defmodule Magus.Library.PromptPropertyTest do
  @moduledoc """
  Property-based tests for Prompt resource.

  Uses StreamData to verify that prompt creation handles
  a variety of valid inputs correctly.
  """
  use Magus.ResourceCase, async: true
  use ExUnitProperties

  import Magus.PropertyGenerators

  alias Magus.Library

  describe "prompt creation" do
    property "accepts all valid prompt types" do
      user = generate(user())

      check all(type <- prompt_type(), max_runs: 10) do
        unique_name = "Test Prompt #{System.unique_integer([:positive])}"

        {:ok, prompt} =
          Library.create_prompt(
            %{name: unique_name, content: "Content for #{type}", type: type},
            actor: user
          )

        assert prompt.type == type
        assert prompt.name == unique_name
      end
    end

    property "accepts various content lengths" do
      user = generate(user())

      check all(
              content <- StreamData.string(:alphanumeric, min_length: 1, max_length: 5000),
              max_runs: 15
            ) do
        unique_name = "Prompt #{System.unique_integer([:positive])}"

        {:ok, prompt} =
          Library.create_prompt(
            %{name: unique_name, content: content, type: :user},
            actor: user
          )

        assert prompt.content == content
      end
    end

    property "accepts alphanumeric names" do
      user = generate(user())

      check all(
              name <- StreamData.string(:alphanumeric, min_length: 1, max_length: 100),
              max_runs: 15
            ) do
        # Add unique suffix to prevent collisions
        unique_name = "#{name}_#{System.unique_integer([:positive])}"

        {:ok, prompt} =
          Library.create_prompt(
            %{name: unique_name, content: "Test content", type: :user},
            actor: user
          )

        assert prompt.name == unique_name
      end
    end
  end
end
