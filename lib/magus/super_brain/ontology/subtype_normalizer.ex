defmodule Magus.SuperBrain.Ontology.SubtypeNormalizer do
  @moduledoc """
  Collapses LLM-emitted entity subtypes to a small canonical vocabulary.

  Used as a secondary merge key alongside `type` during inline
  canonicalize and BuildSuper clustering. Unknown subtypes pass through
  unchanged so the LLM keeps its expressive room; the map only collapses
  known synonyms.

  Iter4's `Reontologize` pass replaces this hand-maintained map with a
  data-driven promotion mechanism.
  """

  @subtype_map %{
    # :person subtypes
    "user" => "user",
    "self" => "user",
    "me" => "user",
    "coworker" => "coworker",
    "teammate" => "coworker",
    "colleague" => "coworker",
    "friend" => "friend",
    "family" => "family",
    "client" => "client",
    "customer" => "client",
    "character" => "character",
    "fictional" => "character",
    "novel_character" => "character",
    "protagonist" => "character",
    "public_figure" => "public_figure",
    "celebrity" => "public_figure",
    "historical_figure" => "historical_figure",

    # :document subtypes
    "paper" => "paper",
    "article" => "paper",
    "research_paper" => "paper",
    "book" => "book",
    "ebook" => "book",
    "novel" => "book",
    "email" => "email",
    "mail" => "email",
    "chapter" => "chapter",
    "report" => "report",

    # :event subtypes
    # NOTE: "deadline" appears in :date subtypes too. Sharing the canonical is
    # intentional: an event titled "Tax filing deadline" and a date entity
    # "April 15 (deadline)" are the same conceptual subtype.
    "meeting" => "meeting",
    "deadline" => "deadline",
    "holiday" => "holiday",

    # :organization subtypes
    # Canonical: "company" for for-profit business entities (corp, inc, llc, ltd).
    "company" => "company",
    "corp" => "company",
    "corporation" => "company",
    "inc" => "company",
    "ltd" => "company",
    "llc" => "company",
    "business" => "company",
    "firm" => "company",
    # Canonical: "startup" kept distinct from "company" because the stage of an
    # organization is often the salient feature ("which startups did X work at").
    "startup" => "startup",
    "start_up" => "startup",
    "start-up" => "startup",
    # Canonical: "nonprofit" (no hyphen) for mission-driven orgs.
    "nonprofit" => "nonprofit",
    "non-profit" => "nonprofit",
    "non_profit" => "nonprofit",
    "ngo" => "nonprofit",
    "charity" => "nonprofit",
    # Canonical: "university" for any degree-granting academic institution.
    "university" => "university",
    "college" => "university",
    "uni" => "university",
    "academic_institution" => "university",
    # Canonical: "government" covers govt bodies, agencies, ministries.
    # NOTE: "agency" intentionally NOT mapped to "government" (iter5 Task 3.5):
    # an ad agency or talent agency is not a government body; keep "agency"
    # as a free-form passthrough so those orgs stay distinct.
    "government" => "government",
    "govt" => "government",
    "gov" => "government",
    "government_agency" => "government",
    # Canonical: "team" covers any small functional group (crew, squad, cohort).
    "team" => "team",
    "group" => "team",
    "crew" => "team",
    "squad" => "team",

    # :project subtypes
    # Canonical: "side_project" covers personal/hobby work done outside main job.
    "side_project" => "side_project",
    "side-project" => "side_project",
    "hobby_project" => "side_project",
    "hobby-project" => "side_project",
    "personal_project" => "side_project",
    # Canonical: "work_project" covers professional, client, billable projects.
    "work_project" => "work_project",
    "work-project" => "work_project",
    "professional_project" => "work_project",
    "client_project" => "work_project",
    # Canonical: "open_source" with underscore.
    "open_source" => "open_source",
    "open-source" => "open_source",
    "oss" => "open_source",
    "foss" => "open_source",
    # Canonical: "research_project" for studies, experiments, investigations.
    "research_project" => "research_project",
    "research-project" => "research_project",
    "study" => "research_project",
    "experiment" => "research_project",

    # :concept subtypes
    # Canonical: "idea" for ad-hoc mental notions/thoughts.
    "idea" => "idea",
    "notion" => "idea",
    "thought" => "idea",
    # Canonical: "theory" for explanatory propositions / hypotheses.
    "theory" => "theory",
    "hypothesis" => "theory",
    # Canonical: "framework" for structured systems of thinking / mental models /
    # paradigms. Note: software frameworks fuse separately under :technology
    # via "framework_tech" to avoid clobbering the conceptual sense.
    # NOTE: "model" intentionally NOT mapped to "framework" (iter5 Task 3.5):
    # a mental model and an ML model have distinct meanings; keep "model" as
    # a free-form passthrough so usage context (statistical model, threat
    # model, etc.) stays disambiguated downstream.
    "framework" => "framework",
    "paradigm" => "framework",
    # Canonical: "principle" for rules, axioms, laws.
    "principle" => "principle",
    "rule" => "principle",
    "law" => "principle",
    "axiom" => "principle",

    # :location subtypes
    # Canonical: "city" for any urban locality (town, metropolis, municipality).
    "city" => "city",
    "town" => "city",
    "metropolis" => "city",
    "municipality" => "city",
    # Canonical: "country" for sovereign nation-state-level entities.
    # NOTE: "state" intentionally NOT mapped to "country" (iter5 Task 3.5):
    # Texas != France. Keep "state" as a free-form passthrough so US states
    # / German Bundesländer / Mexican states stay distinct from sovereign
    # countries; the cosine threshold still catches truly synonymous cases.
    "country" => "country",
    "nation" => "country",
    # Canonical: "region" for sub-national / multi-national areas.
    "region" => "region",
    "area" => "region",
    "territory" => "region",
    "province" => "region",
    # Canonical: "building" for individual physical structures.
    # NOTE: "office" intentionally NOT mapped to "building" (iter5 Task 3.5):
    # "office" often denotes an organizational unit ("the Berlin office",
    # "the Office of the President") rather than a physical structure. Keep
    # it as a free-form passthrough so the org-meaning is preserved.
    "building" => "building",
    "venue" => "building",
    # Canonical: "address" for postal / street identifiers.
    "address" => "address",
    "street_address" => "address",
    "postal_address" => "address",

    # :date subtypes
    # NOTE: "deadline" also serves as an :event canonical above. Shared on purpose.
    "due_date" => "deadline",
    "due-date" => "deadline",
    # Canonical: "anniversary" for recurring date markers.
    # NOTE: "birthday" intentionally NOT mapped to "anniversary" (iter5 Task 3.5):
    # birthdays are person-specific in ways anniversaries are not (wedding
    # anniversaries are couple-specific, work anniversaries are job-specific).
    # Keep "birthday" as a free-form passthrough so the person-anchor is
    # preserved in subtype.
    "anniversary" => "anniversary",
    # Canonical: "milestone" for notable progress markers.
    "milestone" => "milestone",
    "checkpoint" => "milestone",

    # :technology subtypes
    # Canonical: "language" for programming languages.
    "language" => "language",
    "programming_language" => "language",
    "programming-language" => "language",
    "lang" => "language",
    # Canonical: "library" for packaged code dependencies.
    "library" => "library",
    "lib" => "library",
    "package" => "library",
    "dependency" => "library",
    # Canonical: "framework_tech" kept distinct from the conceptual "framework"
    # so a software framework (Phoenix, Rails) and a mental framework
    # (OKRs, RACI) stay separate even though they share a name.
    "framework_tech" => "framework_tech",
    "web_framework" => "framework_tech",
    "software_framework" => "framework_tech",
    # Canonical: "tool" for CLIs, utilities, single-purpose programs.
    "tool" => "tool",
    "utility" => "tool",
    "cli" => "tool",
    "cli_tool" => "tool",
    # Canonical: "platform" for hosted services / SaaS / multi-feature systems.
    "platform" => "platform",
    "service" => "platform",
    "saas" => "platform",
    # Canonical: "database" for any persistent datastore.
    "database" => "database",
    "db" => "database",
    "datastore" => "database",

    # :decision subtypes
    # Canonical: "choice" for picked-one-of-many decisions.
    "choice" => "choice",
    "selection" => "choice",
    "option" => "choice",
    # Canonical: "plan" for forward-looking intentions.
    "plan" => "plan",
    "intent" => "plan",
    "intention" => "plan",
    # Canonical: "commitment" for binding agreements / promises.
    "commitment" => "commitment",
    "agreement" => "commitment",
    "promise" => "commitment",
    # Canonical: "policy" for ongoing rule-like decisions.
    "policy" => "policy",
    "guideline" => "policy",

    # :task subtypes
    # Canonical: "todo" for actionable items.
    "todo" => "todo",
    "to_do" => "todo",
    "to-do" => "todo",
    "action_item" => "todo",
    # Canonical: "goal" for higher-level outcome targets.
    "goal" => "goal",
    "objective" => "goal",
    "target" => "goal",
    # Canonical: "chore" for low-priority routine work.
    "chore" => "chore",
    "errand" => "chore",

    # :fact subtypes
    # Canonical: "claim" for asserted propositions.
    "claim" => "claim",
    "statement" => "claim",
    "assertion" => "claim",
    # Canonical: "observation" for empirical notes / findings.
    "observation" => "observation",
    "note" => "observation",
    "finding" => "observation",
    # Canonical: "preference" for user likes/dislikes/favorites.
    "preference" => "preference",
    "liking" => "preference",
    "favorite" => "preference",
    # Canonical: "metric" for numeric measurements / statistics.
    "metric" => "metric",
    "measurement" => "metric",
    "statistic" => "metric"
  }

  @doc """
  Returns the normalized subtype string, or `nil` for nil/empty input.

  Unknown subtypes pass through with whitespace collapsed and lowercased.
  """
  @spec normalize(String.t() | nil) :: String.t() | nil
  def normalize(nil), do: nil
  def normalize(""), do: nil

  def normalize(subtype) when is_binary(subtype) do
    cleaned =
      subtype
      |> String.downcase()
      |> String.trim()
      |> String.replace(~r/\s+/, "_")

    case cleaned do
      "" -> nil
      key -> Map.get(@subtype_map, key, key)
    end
  end
end
