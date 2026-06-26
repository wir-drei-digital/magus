defmodule Magus.Agents.Support.AiAgent do
  @moduledoc """
  Actor struct used when AI-driven code paths perform Ash operations.

  Fields are optional and default to `nil` so existing callers that
  instantiate `%AiAgent{}` continue to work. When set, `user_id` identifies
  the principal user the agent is running on behalf of, and
  `custom_agent_id` identifies the specific custom agent definition.
  Access-control checks (e.g. `Magus.Workspaces.AccessCheck`) match
  `:custom_agent` grants against `custom_agent_id` and `:user` grants
  against `user_id`.
  """

  defstruct user_id: nil, custom_agent_id: nil
end
