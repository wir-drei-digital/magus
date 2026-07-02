# Script for populating the database. You can run it as:
#
#     mix run priv/repo/seeds.exs
#
# Inside the script, you can read and write to any of your
# repositories directly:
#
#     Magus.Repo.insert!(%Magus.SomeSchema{})
#
# We recommend using the bang functions (`insert!`, `update!`
# and so on) as they will fail if something goes wrong.

require Ash.Query

# === Model catalog ===
# OSS ships an empty model catalog (magus-mxj5.6): a fresh self-host install
# starts with no models. The operator adds a provider and imports models via
# the admin. The curated catalog and default model-role assignments are seeded
# by magus_cloud (MagusCloud.Models.Catalog), not here.

# Seed default tags for the public library
tags = ~w(
  learning
  productivity
  development
  design
  writing
  research
  templates
  examples
  tutorials
  reference
  coding
  debugging
  api
  integration
  automation
  creative
  analysis
  brainstorming
)

for tag_name <- tags do
  case Magus.Library.Tag
       |> Ash.Query.filter(name == ^tag_name)
       |> Ash.read_one(authorize?: false) do
    {:ok, nil} ->
      Magus.Library.Tag
      |> Ash.Changeset.for_create(:create, %{name: tag_name})
      |> Ash.create!(authorize?: false)

      IO.puts("Created tag: #{tag_name}")

    {:ok, _existing} ->
      IO.puts("Tag already exists: #{tag_name}")

    {:error, error} ->
      IO.puts("Error checking tag #{tag_name}: #{inspect(error)}")
  end
end

# Seed Subscription Plans
IO.puts("\n--- Seeding Subscription Plans ---")

plans = [
  %{
    key: "free",
    name: "Free",
    description: "Get started with AI",
    price_monthly_cents: 0,
    stripe_price_id_monthly: nil,
    stripe_price_id_yearly: nil,
    storage_bytes: 1_073_741_824,
    max_upload_bytes: 10_485_760,
    image_generation_enabled: false,
    video_generation_enabled: false,
    is_active: true,
    sort_order: 0
  },
  %{
    key: "starter",
    name: "Starter",
    description: "For regular users",
    price_monthly_cents: 1500,
    stripe_price_id_monthly: nil,
    stripe_price_id_yearly: nil,
    storage_bytes: 10_737_418_240,
    max_upload_bytes: 52_428_800,
    image_generation_enabled: true,
    video_generation_enabled: false,
    is_active: true,
    sort_order: 1
  },
  %{
    key: "pro",
    name: "Pro",
    description: "For power users",
    price_monthly_cents: 3000,
    stripe_price_id_monthly: nil,
    stripe_price_id_yearly: nil,
    storage_bytes: 53_687_091_200,
    max_upload_bytes: 104_857_600,
    image_generation_enabled: true,
    video_generation_enabled: true,
    is_active: true,
    sort_order: 2
  },
  %{
    key: "enterprise",
    name: "Enterprise",
    description: "For teams and organizations",
    price_monthly_cents: 6000,
    stripe_price_id_monthly: nil,
    stripe_price_id_yearly: nil,
    storage_bytes: 107_374_182_400,
    max_upload_bytes: 209_715_200,
    image_generation_enabled: true,
    video_generation_enabled: true,
    is_active: true,
    sort_order: 3
  },
  # The pay-as-you-go entitlement plan. Base-fee subscribers carry this to
  # satisfy the required usage_plan_id FK; it grants full entitlements (all
  # models, media on, Pro-level storage) while the *price* lives on PricingTier,
  # not here (so stripe price ids stay nil). `is_active: false` keeps it out of
  # the legacy upgrade picker (`list_active_plans`); it's resolved by key.
  %{
    key: "payg",
    name: "Pay-as-you-go",
    description: "Base fee + usage at cost",
    price_monthly_cents: 0,
    stripe_price_id_monthly: nil,
    stripe_price_id_yearly: nil,
    storage_bytes: 53_687_091_200,
    max_upload_bytes: 104_857_600,
    max_routing_tier: :complex,
    image_generation_enabled: true,
    video_generation_enabled: true,
    is_active: false,
    sort_order: 10
  }
]

for plan <- plans do
  case Magus.Usage.Policy
       |> Ash.Query.filter(key == ^plan.key)
       |> Ash.read_one(authorize?: false) do
    {:ok, nil} ->
      Magus.Usage.create_usage_plan!(plan, authorize?: false)
      IO.puts("Created plan: #{plan.name}")

    {:ok, _existing} ->
      IO.puts("Plan already exists: #{plan.name} (skipping)")

    {:error, error} ->
      IO.puts("Error checking plan #{plan.name}: #{inspect(error)}")
  end
end

# Billing-edition pricing data (PricingTier + PlatformPricing) lives in a
# separate fragment (seeds_billing.exs) so a pure-OSS seed run stays free of
# Magus.Billing. Run it only when the billing edition is compiled in; the
# combined/cloud app seeds it identically.
billing_seeds = Path.join(__DIR__, "seeds_billing.exs")

if Code.ensure_loaded?(Magus.Billing) and File.exists?(billing_seeds) do
  Code.eval_file(billing_seeds)
else
  IO.puts("Skipping billing pricing seeds (billing edition not present)")
end

IO.puts("\n--- Seed Complete ---")
