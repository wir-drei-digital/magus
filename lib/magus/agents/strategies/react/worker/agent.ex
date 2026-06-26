defmodule Magus.Agents.Strategies.ReactStrategy.Worker.Agent do
  @moduledoc false

  use Jido.Agent,
    name: "react_worker_agent",
    description: "Internal delegated ReAct runtime worker",
    default_plugins: false,
    plugins: [],
    strategy: {Magus.Agents.Strategies.ReactStrategy.Worker.Strategy, []},
    schema:
      Zoi.object(%{
        __strategy__: Zoi.map() |> Zoi.default(%{})
      })
end
