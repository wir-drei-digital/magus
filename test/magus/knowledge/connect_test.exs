defmodule Magus.Knowledge.ConnectTest do
  use Magus.ResourceCase, async: true

  alias Magus.Integrations.Registry
  alias Magus.Knowledge
  alias Magus.Knowledge.Connect
  alias Magus.Knowledge.KnowledgeSource

  # Nextcloud's connect/1 is purely structural (no HTTP), so it exercises the
  # connect -> create -> activate path without touching the network.
  @nextcloud %{
    "base_url" => "https://cloud.example.com",
    "username" => "alice",
    "password" => "app-token"
  }

  describe "connect_and_create/3" do
    test "validates credentials and creates an active source" do
      user = generate(user())

      assert {:ok, source} = Connect.connect_and_create("nextcloud", @nextcloud, actor: user)
      assert source.provider == :nextcloud
      assert source.status == :active
      assert source.name == "Nextcloud"
      assert source.user_id == user.id
    end

    test "uses a supplied name" do
      user = generate(user())

      assert {:ok, source} =
               Connect.connect_and_create("nextcloud", @nextcloud,
                 actor: user,
                 name: "Team Cloud"
               )

      assert source.name == "Team Cloud"
    end

    test "rejects an unknown provider" do
      user = generate(user())

      assert {:error, "Unknown provider"} =
               Connect.connect_and_create("bogus", %{}, actor: user)
    end

    test "affine is no longer a connectable provider" do
      user = generate(user())
      refute "affine" in Magus.Knowledge.Connect.providers()
      assert {:error, "Unknown provider"} = Connect.connect_and_create("affine", %{}, actor: user)
    end

    test "surfaces a connector failure without creating a source" do
      user = generate(user())

      assert {:error, _message} =
               Connect.connect_and_create(
                 "nextcloud",
                 %{"base_url" => "", "username" => "", "password" => ""},
                 actor: user
               )

      assert {:ok, []} = Knowledge.list_sources_for_user(actor: user)
    end
  end

  describe "providers/0 and provider parsing" do
    test "providers/0 lists the drive/oauth wizard providers" do
      assert Connect.providers() ==
               ~w(google_drive onedrive dropbox notion nextcloud kdrive webdav web)
    end

    test "webdav parses and reaches its connector, failing credential validation" do
      user = generate(user())

      # With the generic WebDAV connector wired in, an empty auth_config no longer
      # hits the "Provider not available" guard: it reaches connect/1 and fails on
      # the missing base_url/credentials, surfaced through friendly_error.
      result = Connect.connect_and_create("webdav", %{}, actor: user)

      assert {:error, message} = result
      refute message == "Provider not available"
    end

    test "kdrive parses and reaches its connector, failing credential validation" do
      user = generate(user())

      # With the kDrive connector wired in, an empty auth_config no longer hits
      # the "Provider not available" guard: it reaches connect/1 and fails on the
      # missing api_token, surfaced through friendly_error.
      result = Connect.connect_and_create("kdrive", %{}, actor: user)

      assert {:error, message} = result
      refute message == "Provider not available"
    end

    test "onedrive parses and reaches its connector, failing credential validation" do
      user = generate(user())

      # With the OneDrive connector wired in, an empty auth_config no longer hits
      # the "Provider not available" guard: it reaches connect/1 and fails on the
      # missing access token, surfaced through friendly_error.
      result = Connect.connect_and_create("onedrive", %{}, actor: user)

      assert {:error, message} = result
      refute message == "Provider not available"
    end

    test "dropbox parses and reaches its connector, failing credential validation" do
      user = generate(user())

      # With the Dropbox connector wired in, an empty auth_config no longer hits
      # the "Provider not available" guard: it reaches connect/1 and fails on the
      # missing access token, surfaced through friendly_error.
      result = Connect.connect_and_create("dropbox", %{}, actor: user)

      assert {:error, message} = result
      refute message == "Provider not available"
    end
  end

  describe "knowledge provider registry entries" do
    test "onedrive_knowledge is a knowledge provider with the Microsoft authorize URL" do
      module = Registry.get(:onedrive_knowledge)
      assert module != nil
      assert module.source_type() == :knowledge
      assert module.requires_admin?() == true

      assert module.oauth_config().authorize_url ==
               "https://login.microsoftonline.com/common/oauth2/v2.0/authorize"
    end

    test "dropbox_knowledge is a knowledge provider carrying token_access_type=offline" do
      module = Registry.get(:dropbox_knowledge)
      assert module != nil
      assert module.source_type() == :knowledge
      assert module.requires_admin?() == true

      config = module.oauth_config()
      assert config.authorize_url == "https://www.dropbox.com/oauth2/authorize"
      assert config.extra_authorize_params == %{token_access_type: "offline"}
    end
  end

  describe "connect_source action (SPA RPC surface)" do
    test "returns a source summary map" do
      user = generate(user())

      assert {:ok, summary} =
               KnowledgeSource
               |> Ash.ActionInput.for_action(
                 :connect_source,
                 %{provider: "nextcloud", auth_config: @nextcloud},
                 actor: user
               )
               |> Ash.run_action()

      assert summary.provider == "nextcloud"
      assert summary.status == "active"
      assert is_binary(summary.id)
    end
  end

  describe "connect_source action: form providers end-to-end (Bypass)" do
    # These mirror the SPA wizard's exact server calls: the form provider posts
    # its fields through `connect_source` (creating an ACTIVE source), then the
    # wizard browses folders through `source_folders`. The Bypass server stands
    # in for the real WebDAV / kDrive endpoint so the round-trip is exercised
    # without touching the network.

    test "webdav: connect_source creates an active source, then folders browse against the DAV root" do
      user = generate(user())
      dav = Bypass.open()
      base = "http://localhost:#{dav.port}"

      auth_config = %{
        "base_url" => base,
        "username" => "alice",
        "password" => "app-token"
      }

      assert {:ok, summary} =
               KnowledgeSource
               |> Ash.ActionInput.for_action(
                 :connect_source,
                 %{provider: "webdav", auth_config: auth_config},
                 actor: user
               )
               |> Ash.run_action()

      assert summary.provider == "webdav"
      assert summary.status == "active"
      assert is_binary(summary.id)

      expected_auth = "Basic " <> Base.encode64("alice:app-token")

      Bypass.expect_once(dav, fn conn ->
        assert conn.method == "PROPFIND"
        assert Plug.Conn.get_req_header(conn, "authorization") == [expected_auth]

        multistatus = """
        <?xml version="1.0"?>
        <d:multistatus xmlns:d="DAV:">
          <d:response>
            <d:href>/</d:href>
            <d:propstat><d:prop><d:resourcetype><d:collection/></d:resourcetype></d:prop></d:propstat>
          </d:response>
          <d:response>
            <d:href>/Reports/</d:href>
            <d:propstat>
              <d:prop>
                <d:displayname>Reports</d:displayname>
                <d:resourcetype><d:collection/></d:resourcetype>
              </d:prop>
            </d:propstat>
          </d:response>
        </d:multistatus>
        """

        conn
        |> Plug.Conn.put_resp_content_type("application/xml")
        |> Plug.Conn.resp(207, multistatus)
      end)

      assert {:ok, folders} =
               KnowledgeSource
               |> Ash.ActionInput.for_action(
                 :source_folders,
                 %{source_id: summary.id},
                 actor: user
               )
               |> Ash.run_action()

      assert Enum.any?(folders, &(&1.name == "Reports"))
    end

    test "kdrive: connect_source creates an active source, then folders browse the drives endpoint" do
      user = generate(user())
      api = Bypass.open()
      base = "http://localhost:#{api.port}"

      prev = Application.get_env(:magus, :kdrive_api_base_url)
      Application.put_env(:magus, :kdrive_api_base_url, base)
      on_exit(fn -> Application.put_env(:magus, :kdrive_api_base_url, prev) end)

      auth_config = %{"api_token" => "kd-secret"}

      assert {:ok, summary} =
               KnowledgeSource
               |> Ash.ActionInput.for_action(
                 :connect_source,
                 %{provider: "kdrive", auth_config: auth_config},
                 actor: user
               )
               |> Ash.run_action()

      assert summary.provider == "kdrive"
      assert summary.status == "active"
      assert is_binary(summary.id)

      Bypass.expect_once(api, "GET", "/2/drive", fn conn ->
        assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer kd-secret"]

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(
          200,
          Jason.encode!(%{"data" => [%{"id" => 111, "name" => "Team Drive"}]})
        )
      end)

      assert {:ok, folders} =
               KnowledgeSource
               |> Ash.ActionInput.for_action(
                 :source_folders,
                 %{source_id: summary.id},
                 actor: user
               )
               |> Ash.run_action()

      assert [%{id: "111:root", name: "Team Drive"}] = folders
    end
  end

  describe "create_source_collections action" do
    test "creates a collection per selected folder (deduped by external_id)" do
      user = generate(user())
      {:ok, source} = Connect.connect_and_create("nextcloud", @nextcloud, actor: user)

      folders = [
        %{"id" => "/dav/folderA", "name" => "Folder A", "path" => "/Folder A"},
        %{"id" => "/dav/folderB", "name" => "Folder B", "path" => "/Folder B"}
      ]

      assert {:ok, %{created: 2}} =
               KnowledgeSource
               |> Ash.ActionInput.for_action(
                 :create_source_collections,
                 %{source_id: source.id, folders: folders},
                 actor: user
               )
               |> Ash.run_action()

      assert {:ok, collections} = Knowledge.list_collections_for_source(source.id, actor: user)
      assert length(collections) == 2
      assert "/dav/folderA" in Enum.map(collections, & &1.external_id)
    end
  end

  describe "reconnect_or_create/3" do
    test "updates the existing source for the provider instead of creating a duplicate" do
      user = generate(user())

      {:ok, first} = Connect.connect_and_create("nextcloud", @nextcloud, actor: user)

      {:ok, second} =
        Connect.reconnect_or_create(
          "nextcloud",
          Map.put(@nextcloud, "password", "rotated-token"),
          actor: user
        )

      assert second.id == first.id
      assert {:ok, [_only_one]} = Knowledge.list_sources_for_user(actor: user)
    end

    test "creates a source when none exists for the provider" do
      user = generate(user())

      assert {:ok, source} = Connect.reconnect_or_create("nextcloud", @nextcloud, actor: user)
      assert source.provider == :nextcloud
      assert source.status == :active
    end

    test "heals the source flagged needs_reauth when multiple sources exist for the provider" do
      user = generate(user())

      {:ok, healthy} = Connect.connect_and_create("nextcloud", @nextcloud, actor: user)

      {:ok, broken} =
        Connect.connect_and_create(
          "nextcloud",
          Map.put(@nextcloud, "username", "bob"),
          actor: user
        )

      {:ok, broken} =
        Magus.Knowledge.mark_source_needs_reauth(
          broken,
          %{last_error: "reauth_required"},
          authorize?: false
        )

      assert broken.needs_reauth == true
      assert healthy.needs_reauth == false

      {:ok, healed} =
        Connect.reconnect_or_create(
          "nextcloud",
          Map.put(@nextcloud, "password", "rotated-token"),
          actor: user
        )

      assert healed.id == broken.id
      assert healed.needs_reauth == false

      assert {:ok, [_source_a, _source_b]} = Knowledge.list_sources_for_user(actor: user)
    end
  end
end
