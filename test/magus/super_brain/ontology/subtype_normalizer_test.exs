defmodule Magus.SuperBrain.Ontology.SubtypeNormalizerTest do
  use ExUnit.Case, async: true

  alias Magus.SuperBrain.Ontology.SubtypeNormalizer

  describe "normalize/1" do
    test "returns nil for nil and empty input" do
      assert SubtypeNormalizer.normalize(nil) == nil
      assert SubtypeNormalizer.normalize("") == nil
    end

    test "collapses person subtypes" do
      assert SubtypeNormalizer.normalize("user") == "user"
      assert SubtypeNormalizer.normalize("self") == "user"
      assert SubtypeNormalizer.normalize("me") == "user"
      assert SubtypeNormalizer.normalize("coworker") == "coworker"
      assert SubtypeNormalizer.normalize("teammate") == "coworker"
      assert SubtypeNormalizer.normalize("colleague") == "coworker"
      assert SubtypeNormalizer.normalize("character") == "character"
      assert SubtypeNormalizer.normalize("fictional") == "character"
      assert SubtypeNormalizer.normalize("novel_character") == "character"
      assert SubtypeNormalizer.normalize("protagonist") == "character"
      assert SubtypeNormalizer.normalize("client") == "client"
      assert SubtypeNormalizer.normalize("customer") == "client"
    end

    test "collapses document subtypes" do
      assert SubtypeNormalizer.normalize("paper") == "paper"
      assert SubtypeNormalizer.normalize("article") == "paper"
      assert SubtypeNormalizer.normalize("research_paper") == "paper"
      assert SubtypeNormalizer.normalize("book") == "book"
      assert SubtypeNormalizer.normalize("novel") == "book"
      assert SubtypeNormalizer.normalize("email") == "email"
      assert SubtypeNormalizer.normalize("mail") == "email"
    end

    test "is case- and whitespace-insensitive" do
      assert SubtypeNormalizer.normalize("USER") == "user"
      assert SubtypeNormalizer.normalize("  Coworker  ") == "coworker"
      assert SubtypeNormalizer.normalize("Research Paper") == "paper"
    end

    test "unknown subtypes pass through normalized" do
      assert SubtypeNormalizer.normalize("influencer") == "influencer"
      assert SubtypeNormalizer.normalize("  Galaxy Brain  ") == "galaxy_brain"
    end
  end

  describe "organization subtypes" do
    test "company variants fuse to company" do
      assert SubtypeNormalizer.normalize("company") == "company"
      assert SubtypeNormalizer.normalize("corp") == "company"
      assert SubtypeNormalizer.normalize("corporation") == "company"
      assert SubtypeNormalizer.normalize("inc") == "company"
      assert SubtypeNormalizer.normalize("ltd") == "company"
      assert SubtypeNormalizer.normalize("llc") == "company"
      assert SubtypeNormalizer.normalize("business") == "company"
      assert SubtypeNormalizer.normalize("firm") == "company"
    end

    test "startup variants fuse to startup" do
      assert SubtypeNormalizer.normalize("startup") == "startup"
      assert SubtypeNormalizer.normalize("start_up") == "startup"
      assert SubtypeNormalizer.normalize("start-up") == "startup"
    end

    test "non-profit variants fuse to nonprofit" do
      assert SubtypeNormalizer.normalize("nonprofit") == "nonprofit"
      assert SubtypeNormalizer.normalize("non-profit") == "nonprofit"
      assert SubtypeNormalizer.normalize("non_profit") == "nonprofit"
      assert SubtypeNormalizer.normalize("ngo") == "nonprofit"
      assert SubtypeNormalizer.normalize("charity") == "nonprofit"
    end

    test "academic institution variants fuse to university" do
      assert SubtypeNormalizer.normalize("university") == "university"
      assert SubtypeNormalizer.normalize("college") == "university"
      assert SubtypeNormalizer.normalize("uni") == "university"
      assert SubtypeNormalizer.normalize("academic_institution") == "university"
    end

    test "government variants fuse to government" do
      assert SubtypeNormalizer.normalize("government") == "government"
      assert SubtypeNormalizer.normalize("govt") == "government"
      assert SubtypeNormalizer.normalize("gov") == "government"
      assert SubtypeNormalizer.normalize("government_agency") == "government"
    end

    test "iter5 Task 3.5: 'agency' does NOT fuse with 'government'" do
      # An ad agency or talent agency is not a government body. Keep
      # "agency" as a free-form passthrough so those orgs stay distinct.
      assert SubtypeNormalizer.normalize("agency") == "agency"
      refute SubtypeNormalizer.normalize("agency") == SubtypeNormalizer.normalize("government")
    end

    test "team/group variants fuse to team" do
      assert SubtypeNormalizer.normalize("team") == "team"
      assert SubtypeNormalizer.normalize("group") == "team"
      assert SubtypeNormalizer.normalize("crew") == "team"
    end
  end

  describe "project subtypes" do
    test "side-project variants fuse to side_project" do
      assert SubtypeNormalizer.normalize("side_project") == "side_project"
      assert SubtypeNormalizer.normalize("side-project") == "side_project"
      assert SubtypeNormalizer.normalize("hobby_project") == "side_project"
      assert SubtypeNormalizer.normalize("hobby-project") == "side_project"
      assert SubtypeNormalizer.normalize("personal_project") == "side_project"
    end

    test "work-project variants fuse to work_project" do
      assert SubtypeNormalizer.normalize("work_project") == "work_project"
      assert SubtypeNormalizer.normalize("work-project") == "work_project"
      assert SubtypeNormalizer.normalize("professional_project") == "work_project"
      assert SubtypeNormalizer.normalize("client_project") == "work_project"
    end

    test "open-source variants fuse to open_source" do
      assert SubtypeNormalizer.normalize("open_source") == "open_source"
      assert SubtypeNormalizer.normalize("open-source") == "open_source"
      assert SubtypeNormalizer.normalize("oss") == "open_source"
      assert SubtypeNormalizer.normalize("foss") == "open_source"
    end

    test "research project variants fuse to research_project" do
      assert SubtypeNormalizer.normalize("research_project") == "research_project"
      assert SubtypeNormalizer.normalize("research-project") == "research_project"
      assert SubtypeNormalizer.normalize("study") == "research_project"
    end
  end

  describe "concept subtypes" do
    test "idea variants fuse to idea" do
      assert SubtypeNormalizer.normalize("idea") == "idea"
      assert SubtypeNormalizer.normalize("notion") == "idea"
      assert SubtypeNormalizer.normalize("thought") == "idea"
    end

    test "theory variants fuse to theory" do
      assert SubtypeNormalizer.normalize("theory") == "theory"
      assert SubtypeNormalizer.normalize("hypothesis") == "theory"
    end

    test "framework variants fuse to framework" do
      assert SubtypeNormalizer.normalize("framework") == "framework"
      assert SubtypeNormalizer.normalize("paradigm") == "framework"
    end

    test "iter5 Task 3.5: 'model' does NOT fuse with 'framework'" do
      # Mental models, ML models, threat models, statistical models all
      # share the word but mean different things. Keep "model" as a
      # free-form passthrough so context disambiguates.
      assert SubtypeNormalizer.normalize("model") == "model"
      refute SubtypeNormalizer.normalize("model") == SubtypeNormalizer.normalize("framework")
    end

    test "principle variants fuse to principle" do
      assert SubtypeNormalizer.normalize("principle") == "principle"
      assert SubtypeNormalizer.normalize("rule") == "principle"
      assert SubtypeNormalizer.normalize("law") == "principle"
    end
  end

  describe "location subtypes" do
    test "city variants fuse to city" do
      assert SubtypeNormalizer.normalize("city") == "city"
      assert SubtypeNormalizer.normalize("town") == "city"
      assert SubtypeNormalizer.normalize("metropolis") == "city"
      assert SubtypeNormalizer.normalize("municipality") == "city"
    end

    test "country variants fuse to country" do
      assert SubtypeNormalizer.normalize("country") == "country"
      assert SubtypeNormalizer.normalize("nation") == "country"
    end

    test "iter5 Task 3.5: 'state' does NOT fuse with 'country'" do
      # Texas is not France. US states / Bundesländer / Mexican states are
      # political subdivisions, not sovereign nations. Keep "state" as a
      # free-form passthrough so the granularity is preserved.
      assert SubtypeNormalizer.normalize("state") == "state"
      refute SubtypeNormalizer.normalize("state") == SubtypeNormalizer.normalize("country")
    end

    test "region variants fuse to region" do
      assert SubtypeNormalizer.normalize("region") == "region"
      assert SubtypeNormalizer.normalize("area") == "region"
      assert SubtypeNormalizer.normalize("territory") == "region"
      assert SubtypeNormalizer.normalize("province") == "region"
    end

    test "building variants fuse to building" do
      assert SubtypeNormalizer.normalize("building") == "building"
      assert SubtypeNormalizer.normalize("venue") == "building"
    end

    test "iter5 Task 3.5: 'office' does NOT fuse with 'building'" do
      # "Office" frequently denotes an organizational unit ("the Berlin
      # office", "the Office of the President") rather than a physical
      # structure. Keep "office" as a free-form passthrough so the org
      # meaning is preserved.
      assert SubtypeNormalizer.normalize("office") == "office"
      refute SubtypeNormalizer.normalize("office") == SubtypeNormalizer.normalize("building")
    end

    test "address variants fuse to address" do
      assert SubtypeNormalizer.normalize("address") == "address"
      assert SubtypeNormalizer.normalize("street_address") == "address"
      assert SubtypeNormalizer.normalize("postal_address") == "address"
    end
  end

  describe "date subtypes" do
    test "deadline variants fuse to deadline" do
      assert SubtypeNormalizer.normalize("deadline") == "deadline"
      assert SubtypeNormalizer.normalize("due_date") == "deadline"
      assert SubtypeNormalizer.normalize("due-date") == "deadline"
    end

    test "anniversary variants fuse to anniversary" do
      assert SubtypeNormalizer.normalize("anniversary") == "anniversary"
    end

    test "iter5 Task 3.5: 'birthday' does NOT fuse with 'anniversary'" do
      # Birthdays are person-specific in ways anniversaries are not
      # (wedding anniversaries are couple-specific, work anniversaries are
      # job-specific). Keep "birthday" as a free-form passthrough so the
      # person-anchor stays in subtype.
      assert SubtypeNormalizer.normalize("birthday") == "birthday"
      refute SubtypeNormalizer.normalize("birthday") == SubtypeNormalizer.normalize("anniversary")
    end

    test "milestone variants fuse to milestone" do
      assert SubtypeNormalizer.normalize("milestone") == "milestone"
      assert SubtypeNormalizer.normalize("checkpoint") == "milestone"
    end
  end

  describe "technology subtypes" do
    test "language variants fuse to language" do
      assert SubtypeNormalizer.normalize("language") == "language"
      assert SubtypeNormalizer.normalize("programming_language") == "language"
      assert SubtypeNormalizer.normalize("programming-language") == "language"
      assert SubtypeNormalizer.normalize("lang") == "language"
    end

    test "library variants fuse to library" do
      assert SubtypeNormalizer.normalize("library") == "library"
      assert SubtypeNormalizer.normalize("lib") == "library"
      assert SubtypeNormalizer.normalize("package") == "library"
      assert SubtypeNormalizer.normalize("dependency") == "library"
    end

    test "framework_tech variants fuse to framework_tech" do
      assert SubtypeNormalizer.normalize("web_framework") == "framework_tech"
      assert SubtypeNormalizer.normalize("framework_tech") == "framework_tech"
    end

    test "tool variants fuse to tool" do
      assert SubtypeNormalizer.normalize("tool") == "tool"
      assert SubtypeNormalizer.normalize("utility") == "tool"
      assert SubtypeNormalizer.normalize("cli") == "tool"
      assert SubtypeNormalizer.normalize("cli_tool") == "tool"
    end

    test "platform variants fuse to platform" do
      assert SubtypeNormalizer.normalize("platform") == "platform"
      assert SubtypeNormalizer.normalize("service") == "platform"
      assert SubtypeNormalizer.normalize("saas") == "platform"
    end

    test "database variants fuse to database" do
      assert SubtypeNormalizer.normalize("database") == "database"
      assert SubtypeNormalizer.normalize("db") == "database"
      assert SubtypeNormalizer.normalize("datastore") == "database"
    end
  end

  describe "decision subtypes" do
    test "choice variants fuse to choice" do
      assert SubtypeNormalizer.normalize("choice") == "choice"
      assert SubtypeNormalizer.normalize("selection") == "choice"
      assert SubtypeNormalizer.normalize("option") == "choice"
    end

    test "plan variants fuse to plan" do
      assert SubtypeNormalizer.normalize("plan") == "plan"
      assert SubtypeNormalizer.normalize("intent") == "plan"
      assert SubtypeNormalizer.normalize("intention") == "plan"
    end

    test "commitment variants fuse to commitment" do
      assert SubtypeNormalizer.normalize("commitment") == "commitment"
      assert SubtypeNormalizer.normalize("agreement") == "commitment"
      assert SubtypeNormalizer.normalize("promise") == "commitment"
    end

    test "policy variants fuse to policy" do
      assert SubtypeNormalizer.normalize("policy") == "policy"
      assert SubtypeNormalizer.normalize("guideline") == "policy"
    end
  end

  describe "task subtypes" do
    test "todo variants fuse to todo" do
      assert SubtypeNormalizer.normalize("todo") == "todo"
      assert SubtypeNormalizer.normalize("to_do") == "todo"
      assert SubtypeNormalizer.normalize("to-do") == "todo"
      assert SubtypeNormalizer.normalize("action_item") == "todo"
    end

    test "goal variants fuse to goal" do
      assert SubtypeNormalizer.normalize("goal") == "goal"
      assert SubtypeNormalizer.normalize("objective") == "goal"
      assert SubtypeNormalizer.normalize("target") == "goal"
    end

    test "chore variants fuse to chore" do
      assert SubtypeNormalizer.normalize("chore") == "chore"
      assert SubtypeNormalizer.normalize("errand") == "chore"
    end
  end

  describe "fact subtypes" do
    test "claim variants fuse to claim" do
      assert SubtypeNormalizer.normalize("claim") == "claim"
      assert SubtypeNormalizer.normalize("statement") == "claim"
      assert SubtypeNormalizer.normalize("assertion") == "claim"
    end

    test "observation variants fuse to observation" do
      assert SubtypeNormalizer.normalize("observation") == "observation"
      assert SubtypeNormalizer.normalize("note") == "observation"
      assert SubtypeNormalizer.normalize("finding") == "observation"
    end

    test "preference variants fuse to preference" do
      assert SubtypeNormalizer.normalize("preference") == "preference"
      assert SubtypeNormalizer.normalize("liking") == "preference"
      assert SubtypeNormalizer.normalize("favorite") == "preference"
    end

    test "metric variants fuse to metric" do
      assert SubtypeNormalizer.normalize("metric") == "metric"
      assert SubtypeNormalizer.normalize("measurement") == "metric"
      assert SubtypeNormalizer.normalize("statistic") == "metric"
    end
  end
end
