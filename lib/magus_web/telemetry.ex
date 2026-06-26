defmodule MagusWeb.Telemetry do
  use Supervisor
  import Telemetry.Metrics

  def start_link(arg) do
    Supervisor.start_link(__MODULE__, arg, name: __MODULE__)
  end

  @impl true
  def init(_arg) do
    children = [
      # Telemetry poller will execute the given period measurements
      # every 10_000ms. Learn more here: https://hexdocs.pm/telemetry_metrics
      {:telemetry_poller, measurements: periodic_measurements(), period: 10_000}
      # Add reporters as children of your supervision tree.
      # {Telemetry.Metrics.ConsoleReporter, metrics: metrics()}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end

  def metrics do
    [
      # Phoenix Metrics
      summary("phoenix.endpoint.start.system_time",
        unit: {:native, :millisecond}
      ),
      summary("phoenix.endpoint.stop.duration",
        unit: {:native, :millisecond}
      ),
      summary("phoenix.router_dispatch.start.system_time",
        tags: [:route],
        unit: {:native, :millisecond}
      ),
      summary("phoenix.router_dispatch.exception.duration",
        tags: [:route],
        unit: {:native, :millisecond}
      ),
      summary("phoenix.router_dispatch.stop.duration",
        tags: [:route],
        unit: {:native, :millisecond}
      ),
      summary("phoenix.socket_connected.duration",
        unit: {:native, :millisecond}
      ),
      sum("phoenix.socket_drain.count"),
      summary("phoenix.channel_joined.duration",
        unit: {:native, :millisecond}
      ),
      summary("phoenix.channel_handled_in.duration",
        tags: [:event],
        unit: {:native, :millisecond}
      ),

      # Database Metrics
      summary("magus.repo.query.total_time",
        unit: {:native, :millisecond},
        description: "The sum of the other measurements"
      ),
      summary("magus.repo.query.decode_time",
        unit: {:native, :millisecond},
        description: "The time spent decoding the data received from the database"
      ),
      summary("magus.repo.query.query_time",
        unit: {:native, :millisecond},
        description: "The time spent executing the query"
      ),
      summary("magus.repo.query.queue_time",
        unit: {:native, :millisecond},
        description: "The time spent waiting for a database connection"
      ),
      summary("magus.repo.query.idle_time",
        unit: {:native, :millisecond},
        description:
          "The time the connection spent waiting before being checked out for the query"
      ),

      # VM Metrics
      summary("vm.memory.total", unit: {:byte, :kilobyte}),
      summary("vm.total_run_queue_lengths.total"),
      summary("vm.total_run_queue_lengths.cpu"),
      summary("vm.total_run_queue_lengths.io"),

      # Sandbox Metrics
      summary("magus.sandbox.execution.stop.duration",
        unit: {:native, :millisecond},
        description: "Time spent executing Python code in sandbox"
      ),
      counter("magus.sandbox.execution.stop.duration",
        tags: [:success],
        description: "Count of sandbox executions by success/failure"
      ),
      summary("magus.sandbox.provision.duration",
        unit: {:native, :millisecond},
        description: "Time spent provisioning new sandbox sprites"
      ),
      summary("magus.sandbox.suspend.duration",
        unit: {:native, :millisecond},
        description: "Time spent suspending sandbox sprites"
      ),
      summary("magus.sandbox.resume.duration",
        unit: {:native, :millisecond},
        description: "Time spent resuming sandbox sprites"
      ),
      summary("magus.sandbox.terminate.duration",
        unit: {:native, :millisecond},
        description: "Time spent terminating sandbox sprites"
      ),

      # Agent Metrics
      counter("magus.agents.started.count",
        tags: [:type],
        description: "Number of agents started by type (conversation, memory, input)"
      ),
      counter("magus.agents.hibernated.count",
        tags: [:type],
        description: "Number of agents hibernated to PostgreSQL"
      ),
      counter("magus.agents.thawed.count",
        tags: [:type],
        description: "Number of agents thawed from hibernation"
      ),
      summary("magus.agents.tool.duration",
        unit: {:native, :millisecond},
        tags: [:tool],
        description: "Time spent executing tools"
      ),
      counter("magus.agents.tool.count",
        tags: [:tool, :success],
        description: "Number of tool executions by tool name and success/failure"
      ),
      counter("magus.agents.memory_timeout.count",
        description: "Number of memory context request timeouts"
      ),

      # LLM Metrics
      summary("magus.llm.stream.duration",
        unit: {:native, :millisecond},
        tags: [:model, :mode],
        description: "Time spent streaming LLM responses"
      ),
      sum("magus.llm.tokens.input",
        tags: [:model],
        description: "Total input tokens consumed by model"
      ),
      sum("magus.llm.tokens.output",
        tags: [:model],
        description: "Total output tokens generated by model"
      ),
      counter("magus.llm.request.count",
        tags: [:model, :mode, :success],
        description: "Number of LLM requests by model, mode, and success/failure"
      ),

      # Agent LLM call metrics ([:magus, :agents, :llm, :call]) — one event per
      # ReAct turn. Powers the /admin/telemetry view of latency, tokens, empty
      # turns, and blank-answer retries.
      summary("magus.agents.llm.call.duration",
        unit: :millisecond,
        tags: [:model],
        description: "Total wall-clock latency of a single agent LLM turn"
      ),
      summary("magus.agents.llm.call.ttft",
        unit: :millisecond,
        tags: [:model],
        description: "Time to first streamed token for an agent LLM turn"
      ),
      counter("magus.agents.llm.call.duration",
        tags: [:model, :empty?, :success],
        description: "Count of agent LLM turns by model, empty-result, and success"
      ),
      sum("magus.agents.llm.call.prompt_tokens",
        tags: [:model],
        description: "Prompt tokens consumed by agent LLM turns"
      ),
      sum("magus.agents.llm.call.completion_tokens",
        tags: [:model],
        description: "Completion tokens generated by agent LLM turns"
      ),
      sum("magus.agents.llm.call.empty_retries",
        tags: [:model],
        description: "Blank-final-answer re-asks performed during agent LLM turns"
      ),

      # Integration Metrics
      counter("magus.integrations.webhook.count",
        tags: [:provider, :status],
        description: "Number of webhooks received by provider and status"
      ),
      counter("magus.integrations.rate_limited.count",
        tags: [:provider, :operation],
        description: "Number of rate-limited requests by provider and operation"
      ),
      summary("magus.integrations.operation.duration",
        unit: {:native, :millisecond},
        tags: [:provider, :operation],
        description: "Time spent executing integration operations"
      ),

      # Memory Metrics
      summary("magus.memory.context.duration",
        unit: {:native, :millisecond},
        description: "Time spent loading memory context"
      ),
      counter("magus.memory.extraction.count",
        tags: [:scope],
        description: "Number of memory extractions by scope (local, global)"
      ),
      counter("magus.memory.search.count",
        tags: [:scope],
        description: "Number of memory searches by scope"
      ),

      # Reactor Metrics
      summary("magus.reactor.duration",
        unit: {:native, :millisecond},
        tags: [:reactor],
        description: "Time spent running reactors"
      ),
      counter("magus.reactor.count",
        tags: [:reactor, :success],
        description: "Number of reactor runs by name and success/failure"
      )
    ]
  end

  defp periodic_measurements do
    [
      # A module, function and arguments to be invoked periodically.
      # This function must call :telemetry.execute/3 and a metric must be added above.
      # {MagusWeb, :count_users, []}
    ]
  end
end
