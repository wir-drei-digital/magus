defmodule Magus.SystemActor do
  @moduledoc """
  Internal machine actor for cross-boundary writes (cloud billing -> core
  resources). Policies that previously used `authorize_if always()` bypasses
  authorize this actor instead. Seeds the magus-0873 formalization.
  """
  defstruct []
end
