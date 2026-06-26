defmodule Magus.Models do
  @moduledoc """
  Domain for the model catalog: providers (LLM API endpoints with
  instance-level credentials) and, transitively, the chat models that
  reference them.

  `Magus.Chat.Model` stays in the Chat domain; this domain owns the
  Provider resource and catalog-level services (CatalogSync, request
  option resolution).
  """

  use Ash.Domain, otp_app: :magus

  resources do
    resource Magus.Models.Provider do
      define :create_provider, action: :create
      define :update_provider, action: :update
      define :destroy_provider, action: :destroy
      define :list_providers, action: :read
      define :list_enabled_providers, action: :enabled
      define :get_provider_by_slug, action: :by_slug, args: [:slug]
    end

    resource Magus.Models.RoleAssignment do
      define :assign_role, action: :assign
      define :list_role_assignments, action: :read
      define :get_role_assignment, action: :by_role, args: [:role]
      define :destroy_role_assignment, action: :destroy
    end
  end
end
