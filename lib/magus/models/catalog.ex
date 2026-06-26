defmodule Magus.Models.Catalog do
  @moduledoc """
  Curated model catalog data — a seed/migration data source, not a
  runtime input.

  Each entry is a flat map of DB-row attributes plus an optional
  `llmdb_*` block (metadata overrides). It is consumed by
  `priv/repo/seeds.exs` and by the data-migration helpers
  `Magus.Models.Backfill` / `Magus.Models.InternalizeExtras`. At runtime
  the LLMDB `:custom` registry is built from DB rows by
  `Magus.Models.CatalogSync` (no longer from this module via config).

  `llmdb_provider_meta/1` exposes the provider metadata table used when
  internalizing static extras.

  Models with `seed?: false` are internal/utility models that should not
  appear in the user-facing catalog (now carried as `internal?: true`
  DB rows via `InternalizeExtras`).

  Adding a new model: append a map to `@models`. Defaults: `seed?: true`.
  Verify with `mix run priv/repo/seeds.exs`.
  """

  @type model :: map()

  @models [
    # ============================================================
    # Anthropic
    # ============================================================
    %{
      name: "Claude Fable 5",
      key: "openrouter:anthropic/claude-fable-5",
      provider: "Anthropic",
      context_window: 1_000_000,
      input_cost: "$10/M",
      output_cost: "$50/M",
      input_cost_value: Decimal.new("10"),
      input_cost_unit: :per_million_tokens,
      output_cost_value: Decimal.new("50"),
      output_cost_unit: :per_million_tokens,
      input_modalities: ["text", "image"],
      output_modalities: ["text"],
      supports_reasoning?: true,
      short_description: "Mythos-class: autonomous knowledge work and coding",
      detailed_description:
        "Claude Fable 5 is Anthropic's Mythos-class model built for autonomous knowledge work and coding. It targets long-running, complex, and asynchronous tasks that previously required frequent human check-ins, excelling at end-to-end work that would otherwise take a person hours, days, or weeks. It executes well-scoped tasks with few mistakes, automatically self-correcting through verification loops, and ships with robust safeguards.",
      short_description_translations: %{
        "en" => "Mythos-class: autonomous knowledge work and coding",
        "de" => "Mythos-Klasse: autonome Wissensarbeit und Programmierung"
      },
      detailed_description_translations: %{
        "en" =>
          "Claude Fable 5 is Anthropic's Mythos-class model built for autonomous knowledge work and coding. It targets long-running, complex, and asynchronous tasks that previously required frequent human check-ins, excelling at end-to-end work that would otherwise take a person hours, days, or weeks. It executes well-scoped tasks with few mistakes, automatically self-correcting through verification loops, and ships with robust safeguards.",
        "de" =>
          "Claude Fable 5 ist Anthropics Modell der Mythos-Klasse, entwickelt für autonome Wissensarbeit und Programmierung. Es ist auf langlaufende, komplexe und asynchrone Aufgaben ausgelegt, die zuvor häufige menschliche Kontrollen erforderten, und überzeugt bei durchgängiger Arbeit, die eine Person sonst Stunden, Tage oder Wochen kosten würde. Es führt klar abgegrenzte Aufgaben mit wenigen Fehlern aus, korrigiert sich automatisch durch Verifikationsschleifen und verfügt über robuste Schutzmechanismen."
      },
      released_at: ~D[2026-06-09],
      allowed_providers: ["anthropic"],
      llmdb_provider: :openrouter,
      llmdb_model_id: "anthropic/claude-fable-5",
      llmdb_output_limit: 128_000,
      llmdb_cache_read: 1.0,
      llmdb_cache_write: 12.5
    },
    %{
      name: "Claude Opus 4.8",
      key: "openrouter:anthropic/claude-opus-4.8",
      provider: "Anthropic",
      context_window: 1_000_000,
      input_cost: "$5/M",
      output_cost: "$25/M",
      input_cost_value: Decimal.new("5"),
      input_cost_unit: :per_million_tokens,
      output_cost_value: Decimal.new("25"),
      output_cost_unit: :per_million_tokens,
      input_modalities: ["text", "image"],
      output_modalities: ["text"],
      supports_reasoning?: true,
      short_description: "Most capable Opus: autonomous agents, long-horizon work",
      detailed_description:
        "Claude Opus 4.8 is Anthropic's most capable model in the Opus family, built for highly autonomous agents, long-horizon agentic work, knowledge work, and memory-driven tasks. It excels at multi-step reasoning, complex coding, and project orchestration while maintaining quality and coherence across extended outputs and sustained sessions.",
      short_description_translations: %{
        "en" => "Most capable Opus: autonomous agents, long-horizon work",
        "de" => "Leistungsstärkstes Opus: autonome Agenten, Langzeitaufgaben"
      },
      detailed_description_translations: %{
        "en" =>
          "Claude Opus 4.8 is Anthropic's most capable model in the Opus family, built for highly autonomous agents, long-horizon agentic work, knowledge work, and memory-driven tasks. It excels at multi-step reasoning, complex coding, and project orchestration while maintaining quality and coherence across extended outputs and sustained sessions.",
        "de" =>
          "Claude Opus 4.8 ist Anthropics leistungsstärkstes Modell der Opus-Familie, entwickelt für hochautonome Agenten, langlaufende agentische Arbeit, Wissensarbeit und gedächtnisgestützte Aufgaben. Es überzeugt bei mehrstufigem Reasoning, komplexer Programmierung und Projektorchestrierung bei konsistenter Qualität über lange Ausgaben und ausgedehnte Sitzungen."
      },
      released_at: ~D[2026-05-27],
      allowed_providers: ["anthropic"],
      llmdb_provider: :openrouter,
      llmdb_model_id: "anthropic/claude-opus-4.8",
      llmdb_output_limit: 32_000,
      llmdb_cache_read: 0.5,
      llmdb_cache_write: 6.25
    },
    %{
      name: "Claude Opus 4.7",
      key: "openrouter:anthropic/claude-opus-4.7",
      provider: "Anthropic",
      context_window: 1_000_000,
      input_cost: "$5/M",
      output_cost: "$25/M",
      input_cost_value: Decimal.new("5"),
      input_cost_unit: :per_million_tokens,
      output_cost_value: Decimal.new("25"),
      output_cost_unit: :per_million_tokens,
      input_modalities: ["text", "image"],
      output_modalities: ["text"],
      supports_reasoning?: true,
      short_description: "Async agents, long-horizon tasks, frontier coding",
      detailed_description:
        "Claude Opus 4.7 is built for long-running, asynchronous agents and excels at complex multi-step tasks. It demonstrates particular strength in code-related work and agentic execution across extended workflows. The model handles knowledge work including document drafting, presentations, and data analysis while maintaining consistency across lengthy outputs and extended sessions.",
      short_description_translations: %{
        "en" => "Async agents, long-horizon tasks, frontier coding",
        "de" => "Asynchrone Agenten, Langzeitaufgaben, Frontier-Coding"
      },
      detailed_description_translations: %{
        "en" =>
          "Claude Opus 4.7 is built for long-running, asynchronous agents and excels at complex multi-step tasks. It demonstrates particular strength in code-related work and agentic execution across extended workflows. The model handles knowledge work including document drafting, presentations, and data analysis while maintaining consistency across lengthy outputs and extended sessions.",
        "de" =>
          "Claude Opus 4.7 wurde für langlaufende, asynchrone Agenten entwickelt und überzeugt bei komplexen mehrstufigen Aufgaben. Es zeigt besondere Stärke bei Coding-Aufgaben und agentischer Ausführung über ausgedehnte Workflows. Das Modell bewältigt Wissensarbeit wie Dokumentenerstellung, Präsentationen und Datenanalyse bei konsistenten Ergebnissen über lange Ausgaben und ausgedehnte Sitzungen."
      },
      released_at: ~D[2026-04-16],
      allowed_providers: ["anthropic"],
      llmdb_provider: :openrouter,
      llmdb_model_id: "anthropic/claude-opus-4.7",
      llmdb_output_limit: 32_000,
      llmdb_cache_read: 0.5,
      llmdb_cache_write: 6.25
    },
    %{
      name: "Claude Opus 4.6",
      key: "openrouter:anthropic/claude-opus-4.6",
      provider: "Anthropic",
      context_window: 1_000_000,
      input_cost: "$5/M",
      output_cost: "$25/M",
      input_cost_value: Decimal.new("5"),
      input_cost_unit: :per_million_tokens,
      output_cost_value: Decimal.new("25"),
      output_cost_unit: :per_million_tokens,
      input_modalities: ["text", "image"],
      output_modalities: ["text"],
      short_description: "Frontier coding, long-running tasks, deep reasoning",
      detailed_description:
        "Claude Opus 4.6 excels at coding and long-running professional tasks with particular strength in handling expansive codebases and multi-step debugging scenarios. It demonstrates deeper contextual understanding, stronger problem decomposition, and greater reliability on hard engineering tasks than prior generations. Beyond technical work, the model produces near-production-ready documents, plans, and analyses in a single pass while maintaining coherence across lengthy outputs, making it suitable for sustained knowledge work including technical design, migration planning, and end-to-end project execution.",
      short_description_translations: %{
        "en" => "Frontier coding, long-running tasks, deep reasoning",
        "de" => "Frontier-Coding, Langzeitaufgaben, tiefes Reasoning"
      },
      detailed_description_translations: %{
        "en" =>
          "Claude Opus 4.6 excels at coding and long-running professional tasks with particular strength in handling expansive codebases and multi-step debugging scenarios. It demonstrates deeper contextual understanding, stronger problem decomposition, and greater reliability on hard engineering tasks than prior generations. Beyond technical work, the model produces near-production-ready documents, plans, and analyses in a single pass while maintaining coherence across lengthy outputs, making it suitable for sustained knowledge work including technical design, migration planning, and end-to-end project execution.",
        "de" =>
          "Claude Opus 4.6 überzeugt bei Programmierung und langfristigen professionellen Aufgaben mit besonderer Stärke bei umfangreichen Codebasen und mehrstufigem Debugging. Es zeigt tieferes kontextuelles Verständnis, stärkere Problemzerlegung und höhere Zuverlässigkeit bei anspruchsvollen Engineering-Aufgaben als frühere Generationen. Das Modell produziert nahezu produktionsreife Dokumente, Pläne und Analysen in einem Durchgang bei Kohärenz über lange Ausgaben."
      },
      supports_reasoning?: true,
      released_at: ~D[2026-02-04],
      allowed_providers: ["anthropic"],
      llmdb_provider: :openrouter,
      llmdb_model_id: "anthropic/claude-opus-4.6",
      llmdb_output_limit: 32_000,
      llmdb_cache_read: 0.5,
      llmdb_cache_write: 6.25
    },
    %{
      name: "Claude Sonnet 4.6",
      key: "openrouter:anthropic/claude-sonnet-4.6",
      provider: "Anthropic",
      context_window: 1_000_000,
      input_cost: "$3/M",
      output_cost: "$15/M",
      input_cost_value: Decimal.new("3"),
      input_cost_unit: :per_million_tokens,
      output_cost_value: Decimal.new("15"),
      output_cost_unit: :per_million_tokens,
      input_modalities: ["text", "image"],
      output_modalities: ["text"],
      supports_reasoning?: true,
      short_description: "Iterative coding, codebase navigation, document creation",
      detailed_description:
        "Claude Sonnet 4.6 excels at iterative development, complex codebase navigation, and end-to-end project management with memory. It delivers polished document creation in a single pass and confident computer use for web QA and workflow automation. With a 1M token context window and 128K max output, it balances strong reasoning and coding performance with efficient cost, making it ideal for sustained development workflows and autonomous agent tasks.",
      short_description_translations: %{
        "en" => "Iterative coding, codebase navigation, document creation",
        "de" => "Iteratives Coding, Codebase-Navigation, Dokumenterstellung"
      },
      detailed_description_translations: %{
        "en" =>
          "Claude Sonnet 4.6 excels at iterative development, complex codebase navigation, and end-to-end project management with memory. It delivers polished document creation in a single pass and confident computer use for web QA and workflow automation. With a 1M token context window and 128K max output, it balances strong reasoning and coding performance with efficient cost, making it ideal for sustained development workflows and autonomous agent tasks.",
        "de" =>
          "Claude Sonnet 4.6 überzeugt bei iterativer Entwicklung, komplexer Codebase-Navigation und durchgängigem Projektmanagement mit Gedächtnis. Es liefert ausgefeilte Dokumenterstellung in einem Durchgang und souveräne Computernutzung für Web-QA und Workflow-Automatisierung. Mit einem 1M Token Kontextfenster und 128K maximaler Ausgabe bietet es eine ausgewogene Balance aus starkem Reasoning, Coding-Leistung und effizienten Kosten."
      },
      released_at: ~D[2026-02-20],
      allowed_providers: ["anthropic"],
      llmdb_provider: :openrouter,
      llmdb_model_id: "anthropic/claude-sonnet-4.6",
      llmdb_output_limit: 128_000,
      llmdb_cache_read: 0.3,
      llmdb_cache_write: 3.75
    },
    # ============================================================
    # xAI
    # ============================================================
    %{
      name: "Grok 4",
      key: "openrouter:x-ai/grok-4",
      provider: "xAI",
      context_window: 256_000,
      input_cost: "$3/M",
      output_cost: "$15/M",
      input_cost_value: Decimal.new("3"),
      input_cost_unit: :per_million_tokens,
      output_cost_value: Decimal.new("15"),
      output_cost_unit: :per_million_tokens,
      input_modalities: ["text", "image"],
      output_modalities: ["text"],
      supports_reasoning?: true,
      short_description: "Deep reasoning, parallel tools, structured output",
      detailed_description:
        "Grok 4 represents xAI's advanced reasoning capability, offering developers a 256,000 token context window for processing extensive information. The model distinguishes itself through support for parallel tool calling, structured outputs, and the ability to accept both image and text inputs. Reasoning processes remain internal to the model for consistent, high-quality outputs.",
      short_description_translations: %{
        "en" => "Deep reasoning, parallel tools, structured output",
        "de" => "Tiefes Reasoning, parallele Tools, strukturierte Ausgabe"
      },
      detailed_description_translations: %{
        "en" =>
          "Grok 4 represents xAI's advanced reasoning capability, offering developers a 256,000 token context window for processing extensive information. The model distinguishes itself through support for parallel tool calling, structured outputs, and the ability to accept both image and text inputs. Reasoning processes remain internal to the model for consistent, high-quality outputs.",
        "de" =>
          "Grok 4 repräsentiert xAIs fortgeschrittene Reasoning-Fähigkeiten und bietet Entwicklern ein 256.000 Token Kontextfenster für die Verarbeitung umfangreicher Informationen. Das Modell zeichnet sich durch paralleles Tool-Calling, strukturierte Ausgaben und die Fähigkeit aus, sowohl Bild- als auch Texteingaben zu akzeptieren."
      },
      released_at: ~D[2025-07-09],
      allowed_providers: ["xai"],
      llmdb_provider: :openrouter,
      llmdb_model_id: "x-ai/grok-4",
      llmdb_output_limit: 32_000
    },
    %{
      name: "Grok 4.1 Fast",
      key: "openrouter:x-ai/grok-4.1-fast",
      provider: "xAI",
      context_window: 2_000_000,
      input_cost: "$0.20/M",
      output_cost: "$0.50/M",
      input_cost_value: Decimal.new("0.20"),
      input_cost_unit: :per_million_tokens,
      output_cost_value: Decimal.new("0.50"),
      output_cost_unit: :per_million_tokens,
      input_modalities: ["text", "image"],
      output_modalities: ["text"],
      supports_reasoning?: true,
      short_description: "Ultra-fast, 2M context, agentic tool calling",
      detailed_description:
        "Grok 4.1 Fast is xAI's fastest variant in the Grok 4.1 series, engineered specifically for applications requiring rapid tool integration and function calling capabilities. With a 2-million-token context window, it accommodates lengthy documents and extended conversations. Users can enable or disable reasoning functionality through API parameters, balancing response speed against computational depth.",
      short_description_translations: %{
        "en" => "Ultra-fast, 2M context, agentic tool calling",
        "de" => "Ultraschnell, 2M Kontext, agentisches Tool-Calling"
      },
      detailed_description_translations: %{
        "en" =>
          "Grok 4.1 Fast is xAI's fastest variant in the Grok 4.1 series, engineered specifically for applications requiring rapid tool integration and function calling capabilities. With a 2-million-token context window, it accommodates lengthy documents and extended conversations. Users can enable or disable reasoning functionality through API parameters, balancing response speed against computational depth.",
        "de" =>
          "Grok 4.1 Fast ist xAIs schnellste Variante der Grok 4.1-Serie, speziell entwickelt für Anwendungen, die schnelle Tool-Integration und Function-Calling-Fähigkeiten benötigen. Mit einem 2-Millionen-Token-Kontextfenster verarbeitet es umfangreiche Dokumente und lange Konversationen. Reasoning kann über API-Parameter aktiviert oder deaktiviert werden."
      },
      released_at: ~D[2025-11-19],
      allowed_providers: ["xai"],
      llmdb_provider: :openrouter,
      llmdb_model_id: "x-ai/grok-4.1-fast",
      llmdb_input_cost: 0.6,
      llmdb_output_cost: 2.4,
      llmdb_output_limit: 32_000,
      llmdb_context: 256_000,
      llmdb_skip_reasoning?: true
    },
    %{
      name: "Grok 4.20",
      key: "openrouter:x-ai/grok-4.20",
      provider: "xAI",
      context_window: 2_000_000,
      input_cost: "$2/M",
      output_cost: "$6/M",
      input_cost_value: Decimal.new("2"),
      input_cost_unit: :per_million_tokens,
      output_cost_value: Decimal.new("6"),
      output_cost_unit: :per_million_tokens,
      input_modalities: ["text", "image"],
      output_modalities: ["text"],
      supports_reasoning?: true,
      short_description: "Flagship speed, 2M context, low hallucination, agentic tool calling",
      detailed_description:
        "Grok 4.20 is xAI's newest flagship model combining industry-leading speed with agentic tool calling capabilities. It features low hallucination rates and strict prompt adherence for precise responses. With a 2-million-token context window, it handles extensive documents and long conversations. Reasoning can be toggled via API parameters, and it supports structured outputs, native web search, and parallel tool calling.",
      short_description_translations: %{
        "en" => "Flagship speed, 2M context, low hallucination, agentic tool calling",
        "de" =>
          "Flaggschiff-Geschwindigkeit, 2M Kontext, niedrige Halluzination, agentisches Tool-Calling"
      },
      detailed_description_translations: %{
        "en" =>
          "Grok 4.20 is xAI's newest flagship model combining industry-leading speed with agentic tool calling capabilities. It features low hallucination rates and strict prompt adherence for precise responses. With a 2-million-token context window, it handles extensive documents and long conversations. Reasoning can be toggled via API parameters, and it supports structured outputs, native web search, and parallel tool calling.",
        "de" =>
          "Grok 4.20 ist xAIs neuestes Flaggschiff-Modell, das branchenführende Geschwindigkeit mit agentischen Tool-Calling-Fähigkeiten kombiniert. Es zeichnet sich durch niedrige Halluzinationsraten und strikte Prompt-Befolgung für präzise Antworten aus. Mit einem 2-Millionen-Token-Kontextfenster verarbeitet es umfangreiche Dokumente und lange Konversationen. Reasoning kann über API-Parameter umgeschaltet werden."
      },
      released_at: ~D[2026-03-31],
      allowed_providers: ["xai"],
      llmdb_provider: :openrouter,
      llmdb_model_id: "x-ai/grok-4.20",
      llmdb_output_limit: 32_000,
      llmdb_cache_read: 0.2
    },
    %{
      name: "Grok 4.3",
      key: "openrouter:x-ai/grok-4.3",
      provider: "xAI",
      context_window: 1_000_000,
      input_cost: "$1.25/M",
      output_cost: "$2.50/M",
      input_cost_value: Decimal.new("1.25"),
      input_cost_unit: :per_million_tokens,
      output_cost_value: Decimal.new("2.50"),
      output_cost_unit: :per_million_tokens,
      input_modalities: ["text", "image"],
      output_modalities: ["text"],
      supports_reasoning?: true,
      short_description: "Always-on reasoning, 1M context, agentic workflows",
      detailed_description:
        "Grok 4.3 is xAI's reasoning model tuned for agentic workflows, instruction-following, and applications requiring high factual accuracy. Reasoning is always active and cannot be disabled. Its 1-million-token context window is designed for long-document analysis and multi-step tasks, with text and image input.",
      short_description_translations: %{
        "en" => "Always-on reasoning, 1M context, agentic workflows",
        "de" => "Reasoning immer aktiv, 1M Kontext, agentische Workflows"
      },
      detailed_description_translations: %{
        "en" =>
          "Grok 4.3 is xAI's reasoning model tuned for agentic workflows, instruction-following, and applications requiring high factual accuracy. Reasoning is always active and cannot be disabled. Its 1-million-token context window is designed for long-document analysis and multi-step tasks, with text and image input.",
        "de" =>
          "Grok 4.3 ist xAIs Reasoning-Modell, optimiert für agentische Workflows, Anweisungsbefolgung und Anwendungen mit hohem Anspruch an faktische Genauigkeit. Reasoning ist permanent aktiv und kann nicht deaktiviert werden. Das 1-Millionen-Token-Kontextfenster ist für die Analyse langer Dokumente und mehrstufige Aufgaben ausgelegt und unterstützt Text- und Bildeingaben."
      },
      released_at: ~D[2026-04-30],
      allowed_providers: ["xai"],
      llmdb_provider: :openrouter,
      llmdb_model_id: "x-ai/grok-4.3",
      llmdb_output_limit: 32_000
    },
    %{
      name: "Grok Imagine Image Quality",
      key: "openrouter:x-ai/grok-imagine-image-quality",
      provider: "xAI",
      context_window: 66_000,
      input_cost: "$0.05/image",
      output_cost: "$0.05/image",
      input_cost_value: Decimal.new("0"),
      input_cost_unit: :per_million_tokens,
      output_cost_value: Decimal.new("0"),
      output_cost_unit: :per_million_tokens,
      input_modalities: ["text", "image"],
      output_modalities: ["image"],
      short_description: "Fast, high-fidelity image generation up to 2K",
      detailed_description:
        "Grok Imagine Image Quality is xAI's fast, high-fidelity image generation and editing model that produces photorealistic outputs at 1K or 2K resolution with flexible aspect ratios. It excels at realistic detail including lighting, physics, and textures with strong multilingual text rendering, and preserves identity and structure when given reference images for use cases like product placement and character consistency.",
      short_description_translations: %{
        "en" => "Fast, high-fidelity image generation up to 2K",
        "de" => "Schnelle, hochauflösende Bildgenerierung bis 2K"
      },
      detailed_description_translations: %{
        "en" =>
          "Grok Imagine Image Quality is xAI's fast, high-fidelity image generation and editing model that produces photorealistic outputs at 1K or 2K resolution with flexible aspect ratios. It excels at realistic detail including lighting, physics, and textures with strong multilingual text rendering, and preserves identity and structure when given reference images for use cases like product placement and character consistency.",
        "de" =>
          "Grok Imagine Image Quality ist xAIs schnelles, hochauflösendes Bildgenerierungs- und Bearbeitungsmodell, das fotorealistische Ausgaben in 1K oder 2K Auflösung mit flexiblen Seitenverhältnissen liefert. Es überzeugt durch realistische Details bei Licht, Physik und Texturen mit starker mehrsprachiger Textwiedergabe und bewahrt Identität und Struktur bei Referenzbildern für Anwendungen wie Produktplatzierung und Charakterkonsistenz."
      },
      released_at: ~D[2026-05-18],
      allowed_providers: ["xai"],
      llmdb_provider: :openrouter,
      llmdb_model_id: "x-ai/grok-imagine-image-quality",
      llmdb_output_limit: 8_192,
      llmdb_skip_tools?: true,
      llmdb_skip_reasoning?: true
    },
    # ============================================================
    # Google
    # ============================================================
    %{
      name: "Gemini 3.1 Pro",
      key: "openrouter:google/gemini-3.1-pro-preview",
      provider: "Google",
      context_window: 1_048_576,
      input_cost: "$2/M",
      output_cost: "$12/M",
      input_cost_value: Decimal.new("2"),
      input_cost_unit: :per_million_tokens,
      output_cost_value: Decimal.new("12"),
      output_cost_unit: :per_million_tokens,
      input_modalities: ["text", "image"],
      output_modalities: ["text"],
      supports_reasoning?: true,
      short_description: "Flagship multimodal reasoning, agentic workflows, STEM",
      detailed_description:
        "Gemini 3.1 Pro is designed for advanced development and agentic workflows, delivering state-of-the-art performance across general reasoning, STEM problem solving, factual QA, and multimodal understanding. The model excels at tool-calling, long-horizon planning, and zero-shot generation for complex tasks like coding, UI creation, and visualization.",
      short_description_translations: %{
        "en" => "Flagship multimodal reasoning, agentic workflows, STEM",
        "de" => "Multimodales Flaggschiff für Reasoning, agentische Workflows, MINT"
      },
      detailed_description_translations: %{
        "en" =>
          "Gemini 3.1 Pro is designed for advanced development and agentic workflows, delivering state-of-the-art performance across general reasoning, STEM problem solving, factual QA, and multimodal understanding. The model excels at tool-calling, long-horizon planning, and zero-shot generation for complex tasks like coding, UI creation, and visualization.",
        "de" =>
          "Gemini 3.1 Pro wurde für fortgeschrittene Entwicklung und agentische Workflows konzipiert und liefert Spitzenleistung bei allgemeinem Reasoning, MINT-Problemlösung, faktischen Fragen und multimodalem Verstehen."
      },
      released_at: ~D[2025-11-18],
      allowed_providers: ["google-ai-studio", "google-vertex"],
      llmdb_provider: :openrouter,
      llmdb_model_id: "google/gemini-3.1-pro-preview",
      llmdb_output_limit: 65_536
    },
    %{
      name: "Gemini 3.1 Flash Lite",
      key: "openrouter:google/gemini-3.1-flash-lite-preview",
      provider: "Google",
      context_window: 1_048_576,
      input_cost: "$0.25/M",
      output_cost: "$1.50/M",
      input_cost_value: Decimal.new("0.25"),
      input_cost_unit: :per_million_tokens,
      output_cost_value: Decimal.new("1.50"),
      output_cost_unit: :per_million_tokens,
      input_modalities: ["text", "image"],
      output_modalities: ["text"],
      supports_reasoning?: true,
      short_description: "Cost-efficient multimodal, fast reasoning, large context",
      detailed_description:
        "Gemini 3.1 Flash Lite is Google's cost-efficient model offering Pro-level reasoning capabilities at a fraction of the cost. With a 1M token context window and 64K max output, it's optimized for high-throughput applications that need strong multimodal understanding without the premium price tag.",
      short_description_translations: %{
        "en" => "Cost-efficient multimodal, fast reasoning, large context",
        "de" => "Kosteneffizientes Multimodal, schnelles Reasoning, großer Kontext"
      },
      detailed_description_translations: %{
        "en" =>
          "Gemini 3.1 Flash Lite is Google's cost-efficient model offering Pro-level reasoning capabilities at a fraction of the cost. With a 1M token context window and 64K max output, it's optimized for high-throughput applications that need strong multimodal understanding without the premium price tag.",
        "de" =>
          "Gemini 3.1 Flash Lite ist Googles kosteneffizientes Modell mit Pro-Level Reasoning-Fähigkeiten zu einem Bruchteil der Kosten. Mit 1M Token Kontextfenster und 64K maximaler Ausgabe ist es für Hochdurchsatz-Anwendungen optimiert."
      },
      released_at: ~D[2026-02-26],
      allowed_providers: ["google-ai-studio", "google-vertex"],
      llmdb_provider: :openrouter,
      llmdb_model_id: "google/gemini-3.1-flash-lite-preview",
      llmdb_output_limit: 65_536
    },
    %{
      name: "Gemini 3.1 Flash Image",
      key: "openrouter:google/gemini-3.1-flash-image-preview",
      provider: "Google",
      context_window: 65_536,
      input_cost: "$0.50/M",
      output_cost: "$3/M",
      input_cost_value: Decimal.new("0.50"),
      input_cost_unit: :per_million_tokens,
      output_cost_value: Decimal.new("3"),
      output_cost_unit: :per_million_tokens,
      input_modalities: ["text", "image"],
      output_modalities: ["image"],
      supports_reasoning?: true,
      short_description: "Pro-level image quality at Flash speed",
      detailed_description:
        "Gemini 3.1 Flash Image is Google's latest image generation and editing model, delivering Pro-level visual quality at Flash speed. It combines contextual understanding with efficient inference for accessible complex image tasks, supporting both text-to-image generation and image editing with configurable reasoning effort levels.",
      short_description_translations: %{
        "en" => "Pro-level image quality at Flash speed",
        "de" => "Pro-Level Bildqualität mit Flash-Geschwindigkeit"
      },
      detailed_description_translations: %{
        "en" =>
          "Gemini 3.1 Flash Image is Google's latest image generation and editing model, delivering Pro-level visual quality at Flash speed. It combines contextual understanding with efficient inference for accessible complex image tasks, supporting both text-to-image generation and image editing with configurable reasoning effort levels.",
        "de" =>
          "Gemini 3.1 Flash Image ist Googles neuestes Bildgenerierungs- und Bearbeitungsmodell, das Pro-Level Bildqualität mit Flash-Geschwindigkeit liefert. Es kombiniert kontextuelles Verständnis mit effizienter Inferenz für zugängliche komplexe Bildaufgaben und unterstützt sowohl Text-zu-Bild-Generierung als auch Bildbearbeitung mit konfigurierbaren Reasoning-Stufen."
      },
      released_at: ~D[2026-02-26],
      allowed_providers: ["google-ai-studio", "google-vertex"],
      llmdb_provider: :openrouter,
      llmdb_model_id: "google/gemini-3.1-flash-image-preview",
      llmdb_output_limit: 8_192,
      llmdb_skip_tools?: true
    },
    %{
      name: "Gemini 3.5 Flash",
      key: "openrouter:google/gemini-3.5-flash",
      provider: "Google",
      context_window: 1_048_576,
      input_cost: "$1.50/M",
      output_cost: "$9/M",
      input_cost_value: Decimal.new("1.50"),
      input_cost_unit: :per_million_tokens,
      output_cost_value: Decimal.new("9"),
      output_cost_unit: :per_million_tokens,
      input_modalities: ["text", "image", "file"],
      output_modalities: ["text"],
      supports_reasoning?: true,
      short_description: "Near-Pro coding and reasoning at Flash speed",
      detailed_description:
        "Gemini 3.5 Flash is Google's high-efficiency multimodal model delivering near-Pro level coding and reasoning at Flash-tier cost and speed. Optimized for coding tasks and parallel agentic execution, it supports configurable thinking effort levels (minimal, low, medium, high) with medium as the default and handles text, image, video, audio, and PDF inputs.",
      short_description_translations: %{
        "en" => "Near-Pro coding and reasoning at Flash speed",
        "de" => "Pro-nahes Coding und Reasoning mit Flash-Geschwindigkeit"
      },
      detailed_description_translations: %{
        "en" =>
          "Gemini 3.5 Flash is Google's high-efficiency multimodal model delivering near-Pro level coding and reasoning at Flash-tier cost and speed. Optimized for coding tasks and parallel agentic execution, it supports configurable thinking effort levels (minimal, low, medium, high) with medium as the default and handles text, image, video, audio, and PDF inputs.",
        "de" =>
          "Gemini 3.5 Flash ist Googles hocheffizientes multimodales Modell, das Pro-nahe Coding- und Reasoning-Leistung mit Flash-Geschwindigkeit und -Kosten liefert. Optimiert für Coding-Aufgaben und parallele agentische Ausführung, unterstützt es konfigurierbare Reasoning-Stufen (minimal, niedrig, mittel, hoch) mit mittel als Standard und verarbeitet Text-, Bild-, Video-, Audio- und PDF-Eingaben."
      },
      released_at: ~D[2026-05-19],
      allowed_providers: ["google-ai-studio", "google-vertex"],
      llmdb_provider: :openrouter,
      llmdb_model_id: "google/gemini-3.5-flash",
      llmdb_output_limit: 65_536
    },
    # ============================================================
    # OpenAI
    # ============================================================
    %{
      name: "GPT-5.5",
      key: "openrouter:openai/gpt-5.5",
      provider: "OpenAI",
      context_window: 1_050_000,
      input_cost: "$5/M",
      output_cost: "$30/M",
      input_cost_value: Decimal.new("5"),
      input_cost_unit: :per_million_tokens,
      output_cost_value: Decimal.new("30"),
      output_cost_unit: :per_million_tokens,
      input_modalities: ["text", "image"],
      output_modalities: ["text"],
      supports_reasoning?: true,
      short_description: "Frontier reasoning, advanced agents, deep research",
      detailed_description:
        "GPT-5.5 is OpenAI's flagship frontier reasoning model, engineered for the most demanding agentic workflows, deep research, and complex problem-solving tasks. With a 1M+ context window and 128K output, it handles entire codebases, lengthy documents, and multi-step reasoning chains while maintaining coherence and accuracy.",
      short_description_translations: %{
        "en" => "Frontier reasoning, advanced agents, deep research",
        "de" => "Frontier-Reasoning, fortschrittliche Agenten, Deep Research"
      },
      detailed_description_translations: %{
        "en" =>
          "GPT-5.5 is OpenAI's flagship frontier reasoning model, engineered for the most demanding agentic workflows, deep research, and complex problem-solving tasks. With a 1M+ context window and 128K output, it handles entire codebases, lengthy documents, and multi-step reasoning chains while maintaining coherence and accuracy.",
        "de" =>
          "GPT-5.5 ist OpenAIs Spitzenmodell für anspruchsvollste agentische Workflows, Deep Research und komplexe Problemlösung. Mit über 1M Kontextfenster und 128K Ausgabe verarbeitet es ganze Codebasen, lange Dokumente und mehrstufige Reasoning-Ketten."
      },
      allowed_providers: ["openai"],
      llmdb_provider: :openrouter,
      llmdb_model_id: "openai/gpt-5.5",
      llmdb_output_limit: 128_000
    },
    %{
      name: "GPT-5.4",
      key: "openrouter:openai/gpt-5.4",
      provider: "OpenAI",
      context_window: 1_050_000,
      input_cost: "$2.50/M",
      output_cost: "$15/M",
      input_cost_value: Decimal.new("2.50"),
      input_cost_unit: :per_million_tokens,
      output_cost_value: Decimal.new("15"),
      output_cost_unit: :per_million_tokens,
      input_modalities: ["text", "image", "file"],
      output_modalities: ["text"],
      supports_reasoning?: true,
      short_description: "Strong reasoning, file input, agentic workflows",
      detailed_description:
        "GPT-5.4 is OpenAI's balanced reasoning model offering strong performance for everyday agentic workflows. With native file input support, large context window, and 128K output, it's well-suited for document analysis, code review, and multi-step reasoning tasks where the flagship cost isn't justified.",
      short_description_translations: %{
        "en" => "Strong reasoning, file input, agentic workflows",
        "de" => "Starkes Reasoning, Datei-Input, agentische Workflows"
      },
      detailed_description_translations: %{
        "en" =>
          "GPT-5.4 is OpenAI's balanced reasoning model offering strong performance for everyday agentic workflows. With native file input support, large context window, and 128K output, it's well-suited for document analysis, code review, and multi-step reasoning tasks where the flagship cost isn't justified.",
        "de" =>
          "GPT-5.4 ist OpenAIs ausgewogenes Reasoning-Modell mit starker Leistung für alltägliche agentische Workflows. Mit nativer Datei-Unterstützung, großem Kontextfenster und 128K Ausgabe eignet es sich für Dokumentenanalyse, Code-Review und mehrstufiges Reasoning."
      },
      allowed_providers: ["openai"],
      llmdb_provider: :openrouter,
      llmdb_model_id: "openai/gpt-5.4",
      llmdb_output_limit: 128_000
    },
    %{
      name: "GPT-5.4 Image 2",
      key: "openrouter:openai/gpt-5.4-image-2",
      provider: "OpenAI",
      context_window: 272_000,
      input_cost: "$8/M",
      output_cost: "$15/M",
      input_cost_value: Decimal.new("8"),
      input_cost_unit: :per_million_tokens,
      output_cost_value: Decimal.new("15"),
      output_cost_unit: :per_million_tokens,
      input_modalities: ["text", "image"],
      output_modalities: ["text", "image"],
      short_description: "Native image input + output, multimodal",
      detailed_description:
        "GPT-5.4 Image 2 is OpenAI's multimodal model with native image generation alongside text input and output. It enables seamless visual workflows where the same model can both understand and produce images, suitable for design exploration, visual reasoning, and creative tasks.",
      short_description_translations: %{
        "en" => "Native image input + output, multimodal",
        "de" => "Nativer Bild-Input + -Output, multimodal"
      },
      detailed_description_translations: %{
        "en" =>
          "GPT-5.4 Image 2 is OpenAI's multimodal model with native image generation alongside text input and output. It enables seamless visual workflows where the same model can both understand and produce images, suitable for design exploration, visual reasoning, and creative tasks.",
        "de" =>
          "GPT-5.4 Image 2 ist OpenAIs multimodales Modell mit nativer Bildgenerierung neben Text-Input und -Output. Es ermöglicht nahtlose visuelle Workflows, in denen dasselbe Modell Bilder sowohl verstehen als auch erzeugen kann."
      },
      allowed_providers: ["openai"],
      llmdb_provider: :openrouter,
      llmdb_model_id: "openai/gpt-5.4-image-2",
      llmdb_output_limit: 16_384,
      llmdb_skip_reasoning?: true
    },
    %{
      name: "GPT-5.3 Chat",
      key: "openrouter:openai/gpt-5.3-chat",
      provider: "OpenAI",
      context_window: 128_000,
      input_cost: "$1.75/M",
      output_cost: "$14/M",
      input_cost_value: Decimal.new("1.75"),
      input_cost_unit: :per_million_tokens,
      output_cost_value: Decimal.new("14"),
      output_cost_unit: :per_million_tokens,
      input_modalities: ["text", "image", "file"],
      output_modalities: ["text"],
      short_description: "Conversational, fast, multimodal input",
      detailed_description:
        "GPT-5.3 Chat is OpenAI's chat-optimized model with fast response times and multimodal input support. Suitable for conversational interfaces, customer support, and tasks where reasoning depth isn't required but multimodal understanding is.",
      short_description_translations: %{
        "en" => "Conversational, fast, multimodal input",
        "de" => "Konversationell, schnell, multimodaler Input"
      },
      detailed_description_translations: %{
        "en" =>
          "GPT-5.3 Chat is OpenAI's chat-optimized model with fast response times and multimodal input support. Suitable for conversational interfaces, customer support, and tasks where reasoning depth isn't required but multimodal understanding is.",
        "de" =>
          "GPT-5.3 Chat ist OpenAIs auf Konversation optimiertes Modell mit schnellen Antwortzeiten und multimodalem Input. Geeignet für konversationelle Schnittstellen, Kundensupport und Aufgaben ohne tiefes Reasoning."
      },
      allowed_providers: ["openai"],
      llmdb_provider: :openrouter,
      llmdb_model_id: "openai/gpt-5.3-chat",
      llmdb_output_limit: 16_384,
      llmdb_skip_reasoning?: true
    },
    # ============================================================
    # z.ai (GLM)
    # ============================================================
    %{
      name: "GLM 5",
      key: "openrouter:z-ai/glm-5",
      provider: "Z.ai",
      context_window: 202_752,
      input_cost: "$1.00/M",
      output_cost: "$3.20/M",
      input_cost_value: Decimal.new("1.00"),
      input_cost_unit: :per_million_tokens,
      output_cost_value: Decimal.new("3.20"),
      output_cost_unit: :per_million_tokens,
      input_modalities: ["text"],
      output_modalities: ["text"],
      supports_reasoning?: true,
      short_description: "Open weights, reasoning, agentic tool calling",
      detailed_description:
        "GLM 5 is Zhipu AI's open-weight reasoning model with strong agentic capabilities. It supports tool calling, structured outputs, and configurable reasoning depth. With a 200K+ context window, it handles substantial documents and codebases at competitive cost.",
      short_description_translations: %{
        "en" => "Open weights, reasoning, agentic tool calling",
        "de" => "Offene Gewichte, Reasoning, agentisches Tool-Calling"
      },
      detailed_description_translations: %{
        "en" =>
          "GLM 5 is Zhipu AI's open-weight reasoning model with strong agentic capabilities. It supports tool calling, structured outputs, and configurable reasoning depth. With a 200K+ context window, it handles substantial documents and codebases at competitive cost.",
        "de" =>
          "GLM 5 ist Zhipu AIs offenes Reasoning-Modell mit starken agentischen Fähigkeiten. Es unterstützt Tool-Calling, strukturierte Ausgaben und konfigurierbare Reasoning-Tiefe."
      },
      allowed_providers: ["z-ai", "novita"],
      llmdb_provider: :openrouter,
      llmdb_model_id: "z-ai/glm-5",
      llmdb_input_cost: 0.8,
      llmdb_output_cost: 2.56,
      llmdb_output_limit: 32_000
    },
    %{
      name: "GLM 5.1",
      key: "openrouter:z-ai/glm-5.1",
      provider: "Z.ai",
      context_window: 202_752,
      input_cost: "$1.26/M",
      output_cost: "$3.96/M",
      input_cost_value: Decimal.new("1.26"),
      input_cost_unit: :per_million_tokens,
      output_cost_value: Decimal.new("3.96"),
      output_cost_unit: :per_million_tokens,
      input_modalities: ["text"],
      output_modalities: ["text"],
      supports_reasoning?: true,
      short_description: "Open weights, improved reasoning, agentic flows",
      detailed_description:
        "GLM 5.1 is the latest iteration of Zhipu AI's open-weight reasoning model with improved benchmarks across coding, math, and tool-calling tasks. Suitable for cost-conscious deployments needing strong reasoning capabilities.",
      short_description_translations: %{
        "en" => "Open weights, improved reasoning, agentic flows",
        "de" => "Offene Gewichte, verbessertes Reasoning, agentische Abläufe"
      },
      detailed_description_translations: %{
        "en" =>
          "GLM 5.1 is the latest iteration of Zhipu AI's open-weight reasoning model with improved benchmarks across coding, math, and tool-calling tasks. Suitable for cost-conscious deployments needing strong reasoning capabilities.",
        "de" =>
          "GLM 5.1 ist die neueste Iteration von Zhipu AIs offenem Reasoning-Modell mit verbesserten Benchmarks bei Coding, Mathematik und Tool-Calling."
      },
      allowed_providers: ["z-ai", "novita"],
      llmdb_provider: :openrouter,
      llmdb_model_id: "z-ai/glm-5.1",
      llmdb_output_limit: 32_000
    },
    # ============================================================
    # Mistral
    # ============================================================
    %{
      name: "Mistral Large 2512",
      key: "openrouter:mistralai/mistral-large-2512",
      provider: "Mistral AI",
      context_window: 256_000,
      input_cost: "$0.50/M",
      output_cost: "$1.50/M",
      input_cost_value: Decimal.new("0.50"),
      input_cost_unit: :per_million_tokens,
      output_cost_value: Decimal.new("1.50"),
      output_cost_unit: :per_million_tokens,
      input_modalities: ["text", "image"],
      output_modalities: ["text"],
      short_description: "Sparse 675B MoE, multimodal, code & reasoning",
      detailed_description:
        "Mistral Large 2512 is a 675B parameter sparse mixture-of-experts model that activates only a portion of its parameters per query for efficient processing while maintaining high performance. It supports multimodal input, complex reasoning, code generation, and comprehensive content analysis.",
      short_description_translations: %{
        "en" => "Sparse 675B MoE, multimodal, code & reasoning",
        "de" => "Spärliches 675B MoE, multimodal, Code & Reasoning"
      },
      detailed_description_translations: %{
        "en" =>
          "Mistral Large 2512 is a 675B parameter sparse mixture-of-experts model that activates only a portion of its parameters per query for efficient processing while maintaining high performance. It supports multimodal input, complex reasoning, code generation, and comprehensive content analysis.",
        "de" =>
          "Dieses Modell stellt einen bedeutenden Fortschritt in Mistrals Fähigkeiten dar und verwendet eine spezialisierte Architektur, die für jede Anfrage nur einen Teil seiner 675 Milliarden Parameter aktiviert."
      },
      released_at: ~D[2025-12-01],
      allowed_providers: ["mistral"],
      llmdb_provider: :openrouter,
      llmdb_model_id: "mistralai/mistral-large-2512",
      llmdb_output_limit: 8_192,
      llmdb_context: 262_144
    },
    %{
      name: "Mistral Medium 3.5",
      key: "openrouter:mistralai/mistral-medium-3-5",
      provider: "Mistral AI",
      context_window: 262_144,
      input_cost: "$1.50/M",
      output_cost: "$7.50/M",
      input_cost_value: Decimal.new("1.50"),
      input_cost_unit: :per_million_tokens,
      output_cost_value: Decimal.new("7.50"),
      output_cost_unit: :per_million_tokens,
      input_modalities: ["text", "image"],
      output_modalities: ["text"],
      supports_reasoning?: true,
      short_description: "Agentic workflows, coding, reliable multi-tool calling",
      detailed_description:
        "Mistral Medium 3.5 is a 128B parameter instruction-following model optimized for agentic workflows, coding, and complex multi-step reasoning. It features a custom vision encoder for variable image sizes, configurable reasoning effort per request, and is particularly strong at reliable multi-tool calling. Open-weight and self-hostable on four GPUs.",
      short_description_translations: %{
        "en" => "Agentic workflows, coding, reliable multi-tool calling",
        "de" => "Agentische Workflows, Coding, zuverlässiges Multi-Tool-Calling"
      },
      detailed_description_translations: %{
        "en" =>
          "Mistral Medium 3.5 is a 128B parameter instruction-following model optimized for agentic workflows, coding, and complex multi-step reasoning. It features a custom vision encoder for variable image sizes, configurable reasoning effort per request, and is particularly strong at reliable multi-tool calling. Open-weight and self-hostable on four GPUs.",
        "de" =>
          "Mistral Medium 3.5 ist ein 128B-Parameter-Modell, optimiert für agentische Workflows, Coding und komplexes mehrstufiges Reasoning. Es verfügt über einen eigenen Vision-Encoder für variable Bildgrößen, konfigurierbaren Reasoning-Aufwand pro Anfrage und überzeugt besonders bei zuverlässigem Multi-Tool-Calling. Offene Gewichte, auf vier GPUs selbst hostbar."
      },
      released_at: ~D[2026-04-30],
      allowed_providers: ["mistral"],
      llmdb_provider: :openrouter,
      llmdb_model_id: "mistralai/mistral-medium-3-5",
      llmdb_output_limit: 8_192
    },
    # ============================================================
    # MiniMax
    # ============================================================
    %{
      name: "MiniMax M2 Her",
      key: "openrouter:minimax/minimax-m2-her",
      provider: "MiniMax",
      context_window: 65_536,
      input_cost: "$0.30/M",
      output_cost: "$1.20/M",
      input_cost_value: Decimal.new("0.30"),
      input_cost_unit: :per_million_tokens,
      output_cost_value: Decimal.new("1.20"),
      output_cost_unit: :per_million_tokens,
      input_modalities: ["text"],
      output_modalities: ["text"],
      short_description: "Conversational, expressive, role-playing",
      detailed_description:
        "MiniMax M2 Her is optimized for conversational and expressive interactions including role-playing, character-driven dialogue, and emotionally nuanced responses. It's tuned for engagement rather than reasoning depth.",
      short_description_translations: %{
        "en" => "Conversational, expressive, role-playing",
        "de" => "Konversationell, expressiv, Rollenspiel"
      },
      detailed_description_translations: %{
        "en" =>
          "MiniMax M2 Her is optimized for conversational and expressive interactions including role-playing, character-driven dialogue, and emotionally nuanced responses. It's tuned for engagement rather than reasoning depth.",
        "de" =>
          "MiniMax M2 Her ist auf konversationelle und expressive Interaktionen optimiert, einschließlich Rollenspiel, charaktergetriebener Dialoge und emotional nuancierter Antworten."
      },
      allowed_providers: ["minimax"],
      llmdb_provider: :openrouter,
      llmdb_model_id: "minimax/minimax-m2-her",
      llmdb_output_limit: 2_048,
      llmdb_simple_streaming?: true,
      llmdb_skip_tools?: true,
      llmdb_skip_reasoning?: true
    },
    %{
      name: "MiniMax M2.5",
      key: "openrouter:minimax/minimax-m2.5",
      provider: "MiniMax",
      context_window: 196_608,
      input_cost: "$0.30/M",
      output_cost: "$1.20/M",
      input_cost_value: Decimal.new("0.30"),
      input_cost_unit: :per_million_tokens,
      output_cost_value: Decimal.new("1.20"),
      output_cost_unit: :per_million_tokens,
      input_modalities: ["text"],
      output_modalities: ["text"],
      supports_reasoning?: true,
      short_description: "Coding, multi-agent, office automation",
      detailed_description:
        "MiniMax M2.5 is a large language model designed for real-world productivity tasks. The model excels at software engineering with 80.2% on SWE-Bench Verified, multi-agent scenarios, and office automation including Word, Excel, and PowerPoint file generation. It features mandatory reasoning with think tags and supports tool calling and structured outputs.",
      short_description_translations: %{
        "en" => "Coding, multi-agent, office automation",
        "de" => "Coding, Multi-Agenten, Büroautomatisierung"
      },
      detailed_description_translations: %{
        "en" =>
          "MiniMax M2.5 is a large language model designed for real-world productivity tasks. The model excels at software engineering with 80.2% on SWE-Bench Verified, multi-agent scenarios, and office automation including Word, Excel, and PowerPoint file generation. It features mandatory reasoning with think tags and supports tool calling and structured outputs.",
        "de" =>
          "MiniMax M2.5 ist ein großes Sprachmodell für reale Produktivitätsaufgaben. Das Modell überzeugt bei Software-Engineering mit 80,2% auf SWE-Bench Verified, Multi-Agenten-Szenarien und Büroautomatisierung einschließlich Word-, Excel- und PowerPoint-Dateigenerierung. Es verfügt über obligatorisches Reasoning mit Think-Tags und unterstützt Tool-Calling und strukturierte Ausgaben."
      },
      released_at: ~D[2026-02-12],
      allowed_providers: [
        "together",
        "deepinfra",
        "novita",
        "parasail",
        "chutes",
        "sambanova",
        "venice",
        "inceptron",
        "atlascloud",
        "nextbit",
        "ionstream",
        "minimax",
        "siliconflow"
      ],
      llmdb_provider: :openrouter,
      llmdb_model_id: "minimax/minimax-m2.5"
    },
    %{
      name: "MiniMax M3",
      key: "openrouter:minimax/minimax-m3",
      provider: "MiniMax",
      context_window: 1_048_576,
      input_cost: "$0.30/M",
      output_cost: "$1.20/M",
      input_cost_value: Decimal.new("0.30"),
      input_cost_unit: :per_million_tokens,
      output_cost_value: Decimal.new("1.20"),
      output_cost_unit: :per_million_tokens,
      input_modalities: ["text", "image", "video"],
      output_modalities: ["text"],
      supports_reasoning?: true,
      short_description: "Multimodal, long-horizon agentic, coding, tool use",
      detailed_description:
        "MiniMax M3 is a multimodal foundation model supporting text, image, and video inputs with text output and a 1M-token context window. It is suited for long-horizon agentic work, coding, and tool use, and uses MiniMax Sparse Attention to cut compute cost at full context length while maintaining quality.",
      short_description_translations: %{
        "en" => "Multimodal, long-horizon agentic, coding, tool use",
        "de" => "Multimodal, langfristig agentisch, Coding, Tool-Nutzung"
      },
      detailed_description_translations: %{
        "en" =>
          "MiniMax M3 is a multimodal foundation model supporting text, image, and video inputs with text output and a 1M-token context window. It is suited for long-horizon agentic work, coding, and tool use, and uses MiniMax Sparse Attention to cut compute cost at full context length while maintaining quality.",
        "de" =>
          "MiniMax M3 ist ein multimodales Foundation-Modell, das Text-, Bild- und Videoeingaben mit Textausgabe und einem 1M-Token-Kontextfenster unterstützt. Es eignet sich für langfristige agentische Arbeit, Programmierung und Tool-Nutzung und nutzt MiniMax Sparse Attention, um die Rechenkosten bei voller Kontextlänge zu senken und dabei die Qualität zu erhalten."
      },
      released_at: ~D[2026-05-31],
      allowed_providers: ["minimax"],
      llmdb_provider: :openrouter,
      llmdb_model_id: "minimax/minimax-m3",
      llmdb_cache_read: 0.06
    },
    # ============================================================
    # Qwen (Alibaba)
    # ============================================================
    %{
      name: "Qwen3.7 Max",
      key: "openrouter:qwen/qwen3.7-max",
      provider: "Qwen",
      context_window: 1_000_000,
      input_cost: "$1.25/M",
      output_cost: "$3.75/M",
      input_cost_value: Decimal.new("1.25"),
      input_cost_unit: :per_million_tokens,
      output_cost_value: Decimal.new("3.75"),
      output_cost_unit: :per_million_tokens,
      input_modalities: ["text"],
      output_modalities: ["text"],
      supports_reasoning?: true,
      short_description: "Flagship agentic model: coding, productivity, autonomy",
      detailed_description:
        "Qwen3.7 Max is the flagship model in Alibaba's Qwen3.7 series, built for agent-centric workloads with strengths in coding, productivity tasks, and long-horizon autonomous execution. It supports a 1M-token context window and explicit prompt caching for efficient reuse of repeated context.",
      short_description_translations: %{
        "en" => "Flagship agentic model: coding, productivity, autonomy",
        "de" => "Flaggschiff-Agentenmodell: Coding, Produktivität, Autonomie"
      },
      detailed_description_translations: %{
        "en" =>
          "Qwen3.7 Max is the flagship model in Alibaba's Qwen3.7 series, built for agent-centric workloads with strengths in coding, productivity tasks, and long-horizon autonomous execution. It supports a 1M-token context window and explicit prompt caching for efficient reuse of repeated context.",
        "de" =>
          "Qwen3.7 Max ist das Flaggschiff-Modell der Qwen3.7-Reihe von Alibaba, entwickelt für agentenzentrierte Workloads mit Stärken bei Programmierung, Produktivitätsaufgaben und langfristiger autonomer Ausführung. Es unterstützt ein 1M-Token-Kontextfenster und explizites Prompt-Caching zur effizienten Wiederverwendung wiederkehrender Kontexte."
      },
      released_at: ~D[2026-05-21],
      allowed_providers: ["alibaba"],
      llmdb_provider: :openrouter,
      llmdb_model_id: "qwen/qwen3.7-max",
      llmdb_cache_read: 0.25,
      llmdb_cache_write: 1.5625
    },
    # ============================================================
    # Inception
    # ============================================================
    %{
      name: "Mercury 2",
      key: "openrouter:inception/mercury-2",
      provider: "Inception",
      context_window: 128_000,
      input_cost: "$0.25/M",
      output_cost: "$0.75/M",
      input_cost_value: Decimal.new("0.25"),
      input_cost_unit: :per_million_tokens,
      output_cost_value: Decimal.new("0.75"),
      output_cost_unit: :per_million_tokens,
      input_modalities: ["text"],
      output_modalities: ["text"],
      supports_reasoning?: true,
      short_description: "Diffusion-based, ultra-fast inference, agentic",
      detailed_description:
        "Mercury 2 is Inception's diffusion-based language model offering ultra-fast inference with agentic tool-calling capabilities. The diffusion architecture enables parallel token generation rather than sequential, dramatically reducing latency for long outputs.",
      short_description_translations: %{
        "en" => "Diffusion-based, ultra-fast inference, agentic",
        "de" => "Diffusionsbasiert, ultraschnelle Inferenz, agentisch"
      },
      detailed_description_translations: %{
        "en" =>
          "Mercury 2 is Inception's diffusion-based language model offering ultra-fast inference with agentic tool-calling capabilities. The diffusion architecture enables parallel token generation rather than sequential, dramatically reducing latency for long outputs.",
        "de" =>
          "Mercury 2 ist Inceptions diffusionsbasiertes Sprachmodell mit ultraschneller Inferenz und agentischen Tool-Calling-Fähigkeiten."
      },
      allowed_providers: ["inception"],
      llmdb_provider: :openrouter,
      llmdb_model_id: "inception/mercury-2",
      llmdb_output_limit: 32_000
    },
    # ============================================================
    # PublicAI
    # ============================================================
    %{
      name: "Apertus 70B",
      key: "publicai:swiss-ai/apertus-70b-instruct",
      provider: "Swiss AI",
      api_provider: :publicai,
      context_window: 65_536,
      input_cost: "Free",
      output_cost: "Free",
      input_cost_value: Decimal.new("0"),
      input_cost_unit: :per_million_tokens,
      output_cost_value: Decimal.new("0"),
      output_cost_unit: :per_million_tokens,
      input_modalities: ["text"],
      output_modalities: ["text"],
      supports_tools?: false,
      short_description: "Swiss flagship model, 1800+ languages",
      detailed_description:
        "Apertus 70B is Switzerland's flagship open language model, a 71B parameter model trained on 15 trillion tokens. It natively supports over 1,800 languages. Developed by the Swiss AI Initiative with complete transparency - all weights, training data, and methodology are publicly available. The model achieves performance comparable to closed-source alternatives while maintaining full compliance with EU AI Act requirements.",
      short_description_translations: %{
        "en" => "Swiss flagship model, 1800+ languages",
        "de" => "Schweizer Flaggschiff-Modell, 1800+ Sprachen"
      },
      detailed_description_translations: %{
        "en" =>
          "Apertus 70B is Switzerland's flagship open language model, a 71B parameter model trained on 15 trillion tokens. It natively supports over 1,800 languages. Developed by the Swiss AI Initiative with complete transparency - all weights, training data, and methodology are publicly available. The model achieves performance comparable to closed-source alternatives while maintaining full compliance with EU AI Act requirements.",
        "de" =>
          "Apertus 70B ist das Schweizer Flaggschiff unter den offenen Sprachmodellen, ein 71B Parameter-Modell trainiert auf 15 Billionen Token. Es unterstützt nativ über 1.800 Sprachen. Entwickelt von der Swiss AI Initiative mit vollständiger Transparenz - alle Gewichte, Trainingsdaten und Methodik sind öffentlich verfügbar. Das Modell erreicht Leistung vergleichbar mit Closed-Source-Alternativen."
      },
      released_at: ~D[2025-09-01],
      allowed_providers: [],
      llmdb_provider: :publicai,
      llmdb_model_id: "swiss-ai/apertus-70b-instruct",
      llmdb_simple_capabilities?: true
    },
    # LLMDB-only utility models (not seeded into the user-facing catalog)
    %{
      key: "publicai:swiss-ai/apertus-8b-instruct",
      seed?: false,
      llmdb_provider: :publicai,
      llmdb_model_id: "swiss-ai/apertus-8b-instruct",
      llmdb_simple_capabilities?: true
    },
    %{
      name: "Ministral 3B 2512",
      key: "openrouter:mistralai/ministral-3b-2512",
      seed?: false,
      llmdb_provider: :openrouter,
      llmdb_model_id: "mistralai/ministral-3b-2512",
      llmdb_input_cost: 0.1,
      llmdb_output_cost: 0.1,
      llmdb_output_limit: 8_192,
      llmdb_context: 131_072,
      llmdb_input_modalities: [:text, :image],
      llmdb_output_modalities: [:text],
      llmdb_skip_reasoning?: true
    },
    # ============================================================
    # OpenRouter (Citations) — Perplexity Sonar
    # ============================================================
    %{
      name: "Sonar Pro Search",
      key: "openrouter_citations:perplexity/sonar-pro-search",
      provider: "Perplexity",
      context_window: 200_000,
      input_cost: "$3/M",
      output_cost: "$15/M",
      input_cost_value: Decimal.new("3"),
      input_cost_unit: :per_million_tokens,
      output_cost_value: Decimal.new("15"),
      output_cost_unit: :per_million_tokens,
      input_modalities: ["text"],
      output_modalities: ["text"],
      supports_search?: true,
      short_description: "Real-time web search with citations",
      detailed_description:
        "Sonar Pro Search is Perplexity's flagship search-grounded model, returning answers with verifiable web citations. Optimized for research, fact-checking, and any task requiring up-to-date information from the web.",
      short_description_translations: %{
        "en" => "Real-time web search with citations",
        "de" => "Echtzeit-Web-Suche mit Quellenangaben"
      },
      detailed_description_translations: %{
        "en" =>
          "Sonar Pro Search is Perplexity's flagship search-grounded model, returning answers with verifiable web citations. Optimized for research, fact-checking, and any task requiring up-to-date information from the web.",
        "de" =>
          "Sonar Pro Search ist Perplexitys Flaggschiff-Modell für suchgestützte Antworten mit überprüfbaren Web-Quellenangaben. Optimiert für Recherche, Faktencheck und Aufgaben mit aktuellen Web-Informationen."
      },
      allowed_providers: [],
      llmdb_provider: :openrouter_citations,
      llmdb_model_id: "perplexity/sonar-pro-search",
      llmdb_simple_capabilities?: true
    },
    # ============================================================
    # Video Generation (OpenRouter /api/v1/videos)
    # ============================================================
    %{
      name: "Veo 3.1 Fast",
      key: "openrouter:google/veo-3.1-fast",
      provider: "Google",
      api_provider: :openrouter,
      input_cost: "$0.15/s",
      output_cost: "$0.15/s",
      input_cost_value: Decimal.new("0.15"),
      input_cost_unit: :per_second,
      output_cost_value: Decimal.new("0.15"),
      output_cost_unit: :per_second,
      input_modalities: ["text", "image"],
      output_modalities: ["video"],
      supports_tools?: false,
      short_description: "Fast text/image-to-video with audio, up to 4K, 4-8s",
      detailed_description:
        "Google Veo 3.1 Fast generates high-fidelity video from a text prompt or an input image, with native audio, at up to 4K and 4 to 8 second clips. The accelerated variant trades a little quality for speed.",
      short_description_translations: %{
        "en" => "Fast text/image-to-video with audio, up to 4K, 4-8s",
        "de" => "Schnelles Text-/Bild-zu-Video mit Audio, bis 4K, 4-8s"
      },
      detailed_description_translations: %{
        "en" =>
          "Google Veo 3.1 Fast generates high-fidelity video from a text prompt or an input image, with native audio, at up to 4K and 4 to 8 second clips. The accelerated variant trades a little quality for speed.",
        "de" =>
          "Google Veo 3.1 Fast erzeugt hochwertige Videos aus einem Textprompt oder einem Eingabebild, mit nativem Audio, bis zu 4K und 4 bis 8 Sekunden Länge. Die beschleunigte Variante tauscht etwas Qualität gegen Tempo."
      },
      info: "Videos generate in 1-3 minutes.",
      released_at: ~D[2026-01-01],
      options: %{
        "aspect_ratio" => ["16:9", "9:16"],
        "duration" => ["4", "6", "8"],
        "resolution" => ["720p", "1080p", "4k"],
        "generate_audio" => ["true", "false"]
      },
      allowed_providers: []
    },
    %{
      name: "Veo 3.1",
      key: "openrouter:google/veo-3.1",
      provider: "Google",
      api_provider: :openrouter,
      input_cost: "$0.40/s",
      output_cost: "$0.40/s",
      input_cost_value: Decimal.new("0.40"),
      input_cost_unit: :per_second,
      output_cost_value: Decimal.new("0.40"),
      output_cost_unit: :per_second,
      input_modalities: ["text", "image"],
      output_modalities: ["video"],
      supports_tools?: false,
      short_description: "High-fidelity text/image-to-video with audio, up to 4K",
      detailed_description:
        "Google Veo 3.1 generates cinematic video from a text prompt or an input image, with native audio, at up to 4K and 4 to 8 second clips.",
      short_description_translations: %{
        "en" => "High-fidelity text/image-to-video with audio, up to 4K",
        "de" => "Hochwertiges Text-/Bild-zu-Video mit Audio, bis 4K"
      },
      detailed_description_translations: %{
        "en" =>
          "Google Veo 3.1 generates cinematic video from a text prompt or an input image, with native audio, at up to 4K and 4 to 8 second clips.",
        "de" =>
          "Google Veo 3.1 erzeugt kinoreife Videos aus einem Textprompt oder einem Eingabebild, mit nativem Audio, bis zu 4K und 4 bis 8 Sekunden Länge."
      },
      info: "Videos generate in 1-3 minutes.",
      released_at: ~D[2026-01-01],
      options: %{
        "aspect_ratio" => ["16:9", "9:16"],
        "duration" => ["4", "6", "8"],
        "resolution" => ["720p", "1080p", "4k"],
        "generate_audio" => ["true", "false"]
      },
      allowed_providers: []
    },
    %{
      name: "Sora 2 Pro",
      key: "openrouter:openai/sora-2-pro",
      provider: "OpenAI",
      api_provider: :openrouter,
      input_cost: "$0.40/s",
      output_cost: "$0.40/s",
      input_cost_value: Decimal.new("0.40"),
      input_cost_unit: :per_second,
      output_cost_value: Decimal.new("0.40"),
      output_cost_unit: :per_second,
      input_modalities: ["text"],
      output_modalities: ["video"],
      supports_tools?: false,
      short_description: "Text-to-video, up to 1080p, 4-20s",
      detailed_description:
        "OpenAI Sora 2 Pro generates video from a text prompt at up to 1080p, with clip lengths from 4 to 20 seconds. Text-to-video only.",
      short_description_translations: %{
        "en" => "Text-to-video, up to 1080p, 4-20s",
        "de" => "Text-zu-Video, bis 1080p, 4-20s"
      },
      detailed_description_translations: %{
        "en" =>
          "OpenAI Sora 2 Pro generates video from a text prompt at up to 1080p, with clip lengths from 4 to 20 seconds. Text-to-video only.",
        "de" =>
          "OpenAI Sora 2 Pro erzeugt Videos aus einem Textprompt bis 1080p, mit Längen von 4 bis 20 Sekunden. Nur Text-zu-Video."
      },
      info: "Videos generate in 1-3 minutes.",
      released_at: ~D[2026-01-01],
      options: %{
        "aspect_ratio" => ["16:9", "9:16"],
        "duration" => ["4", "8", "12", "16", "20"],
        "resolution" => ["720p", "1080p"]
      },
      allowed_providers: []
    },
    %{
      name: "Seedance 2.0",
      key: "openrouter:bytedance/seedance-2.0",
      provider: "ByteDance",
      api_provider: :openrouter,
      input_cost: "$0.05/s",
      output_cost: "$0.05/s",
      input_cost_value: Decimal.new("0.05"),
      input_cost_unit: :per_second,
      output_cost_value: Decimal.new("0.05"),
      output_cost_unit: :per_second,
      input_modalities: ["text", "image"],
      output_modalities: ["video"],
      supports_tools?: false,
      short_description: "Affordable text/image-to-video, up to 1080p, 4-15s",
      detailed_description:
        "ByteDance Seedance 2.0 generates video from a text prompt or an input image at up to 1080p, with clip lengths from 4 to 15 seconds at a low price point.",
      short_description_translations: %{
        "en" => "Affordable text/image-to-video, up to 1080p, 4-15s",
        "de" => "Günstiges Text-/Bild-zu-Video, bis 1080p, 4-15s"
      },
      detailed_description_translations: %{
        "en" =>
          "ByteDance Seedance 2.0 generates video from a text prompt or an input image at up to 1080p, with clip lengths from 4 to 15 seconds at a low price point.",
        "de" =>
          "ByteDance Seedance 2.0 erzeugt Videos aus einem Textprompt oder einem Eingabebild bis 1080p, mit Längen von 4 bis 15 Sekunden zu einem niedrigen Preis."
      },
      info: "Videos generate in 1-3 minutes.",
      released_at: ~D[2026-01-01],
      options: %{
        "aspect_ratio" => ["16:9", "9:16", "1:1", "4:3", "3:4"],
        "duration" => ["4", "6", "8", "10", "12"],
        "resolution" => ["480p", "720p", "1080p"]
      },
      allowed_providers: []
    }
  ]

  @doc "All catalog entries (filtered to those that should be seeded)."
  @spec all() :: [model()]
  def all, do: Enum.filter(@models, &Map.get(&1, :seed?, true))

  @doc "All catalog entries, including LLMDB-only utility models."
  @spec all_with_internal() :: [model()]
  def all_with_internal, do: @models

  # Allowlist mirroring `Magus.Chat.Model`'s `:create` action. Anything not
  # in this list is dropped by `to_db_attrs/1`, including the `llmdb_*`
  # internal fields and any forward-compatible keys we add to entries.
  @db_attrs ~w(
    name key provider api_provider allowed_providers context_window
    input_cost output_cost input_cost_value output_cost_value
    input_cost_unit output_cost_unit
    active? settings
    input_modalities output_modalities
    supports_search? supports_reasoning? supports_tools?
    short_description detailed_description
    short_description_translations detailed_description_translations
    info released_at options
  )a

  @doc """
  Returns Magus.Chat.Model attrs for a single catalog entry, keeping
  only fields the resource's `:create` action accepts. Catalog-internal
  fields (`seed?`, `llmdb_*`) and any future keys are dropped here so
  unknown attributes never reach the changeset. The `llmdb_*` override
  fields are folded into the `:llm_metadata` attr via `to_llm_metadata/1`.
  """
  @spec to_db_attrs(model()) :: map()
  def to_db_attrs(model) do
    model
    |> Map.take(@db_attrs)
    |> Map.put(:llm_metadata, to_llm_metadata(model))
  end

  @llm_metadata_mapping [
    llmdb_output_limit: "output_limit",
    llmdb_context: "context",
    llmdb_input_cost: "input_cost",
    llmdb_output_cost: "output_cost",
    llmdb_cache_read: "cache_read",
    llmdb_cache_write: "cache_write",
    llmdb_skip_tools?: "skip_tools",
    llmdb_skip_reasoning?: "skip_reasoning",
    llmdb_simple_streaming?: "simple_streaming",
    llmdb_simple_capabilities?: "simple_capabilities",
    llmdb_input_modalities: "input_modalities",
    llmdb_output_modalities: "output_modalities"
  ]

  @doc """
  Extracts the `llmdb_*` override fields of a catalog entry into the
  string-keyed `llm_metadata` map stored on `Magus.Chat.Model`.
  """
  @spec to_llm_metadata(model()) :: map()
  def to_llm_metadata(entry) do
    for {source, target} <- @llm_metadata_mapping,
        (value = Map.get(entry, source)) != nil,
        into: %{} do
      {target, value}
    end
  end

  # LLMDB provider registry. Each entry must be referenceable by
  # `llmdb_provider:` on a catalog model. To add a new provider, add a
  # row here. `req_llm_id` selects the ReqLLM provider module; it equals
  # the slug for every current entry. This map is the single source of
  # truth for provider metadata (see `InternalizeExtras`).
  @llmdb_providers %{
    openrouter: %{
      name: "OpenRouter",
      req_llm_id: "openrouter",
      base_url: "https://openrouter.ai/api/v1"
    },
    openrouter_citations: %{
      name: "OpenRouter (Citations)",
      req_llm_id: "openrouter_citations",
      base_url: "https://openrouter.ai/api/v1"
    },
    publicai: %{
      name: "PublicAI",
      req_llm_id: "publicai",
      base_url: "https://api.publicai.co/v1"
    }
  }

  @doc """
  Provider metadata (`%{name, req_llm_id, base_url}`) for an LLMDB provider,
  keyed by its slug (the DB Provider `slug`, which equals the catalog key
  prefix). Accepts the slug as a string or an atom. Raises if unknown.
  """
  @spec llmdb_provider_meta(String.t() | atom()) :: %{
          name: String.t(),
          req_llm_id: String.t(),
          base_url: String.t()
        }
  def llmdb_provider_meta(slug) when is_binary(slug),
    do: llmdb_provider_meta(String.to_existing_atom(slug))

  def llmdb_provider_meta(slug) when is_atom(slug),
    do: Map.fetch!(@llmdb_providers, slug)
end
