defmodule Magus.Integrations.Providers.DataSourceBehaviourTest do
  use ExUnit.Case, async: true

  defmodule TestDataSource do
    @behaviour Magus.Integrations.Providers.DataSourceBehaviour

    @impl true
    def parse_ingestion_payload(payload, _headers) do
      {:ok,
       [
         %{
           content: payload["message"],
           severity: :info,
           metadata: %{},
           occurred_at: DateTime.utc_now()
         }
       ]}
    end

    @impl true
    def classify(%{content: "CRASH" <> _}), do: %{severity: :critical, title: "Crash detected"}
    def classify(_entry), do: %{severity: :info, title: nil}
  end

  test "TestDataSource implements required callbacks" do
    assert {:ok, [entry]} = TestDataSource.parse_ingestion_payload(%{"message" => "hello"}, [])
    assert entry.content == "hello"

    assert %{severity: :critical, title: "Crash detected"} =
             TestDataSource.classify(%{content: "CRASH in app"})

    assert %{severity: :info, title: nil} = TestDataSource.classify(%{content: "normal log"})
  end
end
