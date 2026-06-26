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

# Seed AI Models
# Note: All costs are now stored as structured values (input_cost_value, output_cost_value)
# with explicit units (input_cost_unit, output_cost_unit).
# The legacy string fields (input_cost, output_cost) are kept for display only.
models = [
  # Text Models
  %{
    name: "Gemini 3 Pro Preview",
    key: "openrouter:google/gemini-3-pro-preview",
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
    short_description: "Flagship multimodal reasoning, agentic workflows, STEM",
    detailed_description:
      "Gemini 3 Pro Preview is designed for advanced development and agentic workflows, delivering state-of-the-art performance across general reasoning, STEM problem solving, factual QA, and multimodal understanding. The model excels at tool-calling, long-horizon planning, and zero-shot generation for complex tasks like coding, UI creation, and visualization. It's particularly strong for autonomous agents, coding assistants, multimodal analytics, scientific reasoning, and processing large amounts of contextual information.",
    short_description_translations: %{
      "en" => "Flagship multimodal reasoning, agentic workflows, STEM",
      "de" => "Multimodales Flaggschiff für Reasoning, agentische Workflows, MINT"
    },
    detailed_description_translations: %{
      "en" =>
        "Gemini 3 Pro Preview is designed for advanced development and agentic workflows, delivering state-of-the-art performance across general reasoning, STEM problem solving, factual QA, and multimodal understanding. The model excels at tool-calling, long-horizon planning, and zero-shot generation for complex tasks like coding, UI creation, and visualization. It's particularly strong for autonomous agents, coding assistants, multimodal analytics, scientific reasoning, and processing large amounts of contextual information.",
      "de" =>
        "Gemini 3 Pro Preview wurde für fortgeschrittene Entwicklung und agentische Workflows konzipiert und liefert Spitzenleistung bei allgemeinem Reasoning, MINT-Problemlösung, faktischen Fragen und multimodalem Verstehen. Das Modell überzeugt bei Tool-Calling, langfristiger Planung und Zero-Shot-Generierung für komplexe Aufgaben wie Programmierung, UI-Erstellung und Visualisierung."
    },
    released_at: ~D[2025-11-18],
    allowed_providers: ["google-ai-studio", "google-vertex"]
  },
  %{
    name: "Gemini 3 Flash Preview",
    key: "openrouter:google/gemini-3-flash-preview",
    provider: "Google",
    context_window: 1_048_576,
    input_cost: "$0.50/M",
    output_cost: "$3/M",
    input_cost_value: Decimal.new("0.50"),
    input_cost_unit: :per_million_tokens,
    output_cost_value: Decimal.new("3"),
    output_cost_unit: :per_million_tokens,
    input_modalities: ["text", "image"],
    output_modalities: ["text"],
    supports_reasoning?: true,
    short_description: "Fast thinking model, agentic workflows, coding",
    detailed_description:
      "Gemini 3 Flash Preview is a high-speed, high-value thinking model designed for agentic workflows, multi-turn chat, and coding assistance. It delivers strong reasoning performance with lower latency than larger variants, featuring configurable reasoning levels from minimal to high. The model supports multimodal inputs including text, images, audio, video, and PDFs, with automatic context caching for efficient processing.",
    short_description_translations: %{
      "en" => "Fast thinking model, agentic workflows, coding",
      "de" => "Schnelles Denkmodell, agentische Workflows, Programmierung"
    },
    detailed_description_translations: %{
      "en" =>
        "Gemini 3 Flash Preview is a high-speed, high-value thinking model designed for agentic workflows, multi-turn chat, and coding assistance. It delivers strong reasoning performance with lower latency than larger variants, featuring configurable reasoning levels from minimal to high. The model supports multimodal inputs including text, images, audio, video, and PDFs, with automatic context caching for efficient processing.",
      "de" =>
        "Gemini 3 Flash Preview ist ein schnelles, hochwertiges Denkmodell für agentische Workflows, Multi-Turn-Chat und Programmierunterstützung. Es liefert starke Reasoning-Leistung mit geringerer Latenz als größere Varianten und bietet konfigurierbare Reasoning-Level von minimal bis hoch. Das Modell unterstützt multimodale Eingaben wie Text, Bilder, Audio, Video und PDFs mit automatischem Kontext-Caching."
    },
    released_at: ~D[2025-12-17],
    allowed_providers: ["google-ai-studio", "google-vertex"]
  },
  %{
    name: "Claude Opus 4.5",
    key: "openrouter:anthropic/claude-opus-4.5",
    provider: "Anthropic",
    context_window: 200_000,
    input_cost: "$5/M",
    output_cost: "$25/M",
    input_cost_value: Decimal.new("5"),
    input_cost_unit: :per_million_tokens,
    output_cost_value: Decimal.new("25"),
    output_cost_unit: :per_million_tokens,
    input_modalities: ["text", "image"],
    output_modalities: ["text"],
    short_description: "Frontier reasoning, software engineering, computer use",
    detailed_description:
      "Claude Opus 4.5 is optimized for complex software engineering, agentic workflows, and long-horizon computer use with competitive performance across coding and reasoning benchmarks. The model features improved robustness to prompt injection and operates efficiently across varied effort levels, allowing developers to trade off speed, depth, and token usage depending on task requirements. It includes a verbosity parameter for controlling token efficiency and supports advanced tool use, extended context management, and multi-agent setups.",
    short_description_translations: %{
      "en" => "Frontier reasoning, software engineering, computer use",
      "de" => "Frontier-Reasoning, Software-Entwicklung, Computernutzung"
    },
    detailed_description_translations: %{
      "en" =>
        "Claude Opus 4.5 is optimized for complex software engineering, agentic workflows, and long-horizon computer use with competitive performance across coding and reasoning benchmarks. The model features improved robustness to prompt injection and operates efficiently across varied effort levels, allowing developers to trade off speed, depth, and token usage depending on task requirements. It includes a verbosity parameter for controlling token efficiency and supports advanced tool use, extended context management, and multi-agent setups.",
      "de" =>
        "Claude Opus 4.5 ist für komplexe Software-Entwicklung, agentische Workflows und langfristige Computernutzung optimiert, mit wettbewerbsfähiger Leistung bei Coding- und Reasoning-Benchmarks. Das Modell bietet verbesserte Robustheit gegen Prompt-Injection und arbeitet effizient auf verschiedenen Aufwandsstufen, sodass Entwickler zwischen Geschwindigkeit, Tiefe und Token-Nutzung abwägen können."
    },
    released_at: ~D[2025-11-24],
    allowed_providers: ["anthropic"]
  },
  %{
    name: "Claude Sonnet 4.5",
    key: "openrouter:anthropic/claude-sonnet-4.5",
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
    short_description: "Balanced, agentic coding, tool orchestration",
    detailed_description:
      "Anthropic's latest Sonnet iteration represents a significant advancement in the Claude family, featuring state-of-the-art performance on coding benchmarks such as SWE-bench Verified. The model introduces stronger agentic capabilities including improved tool orchestration, speculative parallel execution, and enhanced context management. It's designed for extended autonomous operation while maintaining task continuity across sessions.",
    short_description_translations: %{
      "en" => "Balanced, agentic coding, tool orchestration",
      "de" => "Ausgewogen, agentische Programmierung, Tool-Orchestrierung"
    },
    detailed_description_translations: %{
      "en" =>
        "Anthropic's latest Sonnet iteration represents a significant advancement in the Claude family, featuring state-of-the-art performance on coding benchmarks such as SWE-bench Verified. The model introduces stronger agentic capabilities including improved tool orchestration, speculative parallel execution, and enhanced context management. It's designed for extended autonomous operation while maintaining task continuity across sessions.",
      "de" =>
        "Anthropics neueste Sonnet-Iteration stellt einen bedeutenden Fortschritt in der Claude-Familie dar, mit Spitzenleistung bei Coding-Benchmarks wie SWE-bench Verified. Das Modell bietet stärkere agentische Fähigkeiten, einschließlich verbesserter Tool-Orchestrierung, spekulativer paralleler Ausführung und erweitertem Kontextmanagement."
    },
    released_at: ~D[2025-09-29],
    allowed_providers: ["anthropic"]
  },
  %{
    name: "Claude Haiku 4.5",
    key: "openrouter:anthropic/claude-haiku-4.5",
    provider: "Anthropic",
    context_window: 200_000,
    input_cost: "$1/M",
    output_cost: "$5/M",
    input_cost_value: Decimal.new("1"),
    input_cost_unit: :per_million_tokens,
    output_cost_value: Decimal.new("5"),
    output_cost_unit: :per_million_tokens,
    input_modalities: ["text", "image"],
    output_modalities: ["text"],
    short_description: "Fast, low-cost, strong coding performance",
    detailed_description:
      "Claude Haiku 4.5 is engineered for high-speed performance while maintaining sophisticated reasoning capabilities. The model introduces extended thinking to the Haiku line, enabling adjustable reasoning depth and tool-assisted workflows supporting coding, bash, web search, and computer-use applications. It achieves over 73% on SWE-bench Verified, ranking among the world's leading coding models while sustaining exceptional responsiveness.",
    short_description_translations: %{
      "en" => "Fast, low-cost, strong coding performance",
      "de" => "Schnell, kostengünstig, starke Coding-Leistung"
    },
    detailed_description_translations: %{
      "en" =>
        "Claude Haiku 4.5 is engineered for high-speed performance while maintaining sophisticated reasoning capabilities. The model introduces extended thinking to the Haiku line, enabling adjustable reasoning depth and tool-assisted workflows supporting coding, bash, web search, and computer-use applications. It achieves over 73% on SWE-bench Verified, ranking among the world's leading coding models while sustaining exceptional responsiveness.",
      "de" =>
        "Claude Haiku 4.5 wurde für Hochgeschwindigkeitsleistung bei gleichzeitig anspruchsvollen Reasoning-Fähigkeiten entwickelt. Das Modell führt erweitertes Denken in die Haiku-Linie ein, ermöglicht anpassbare Reasoning-Tiefe und Tool-gestützte Workflows für Programmierung, Bash, Websuche und Computernutzung. Es erreicht über 73% auf SWE-bench Verified."
    },
    released_at: ~D[2025-10-15],
    allowed_providers: ["anthropic"]
  },
  %{
    name: "GPT-5.2 Chat",
    key: "openrouter:openai/gpt-5.2-chat",
    provider: "OpenAI",
    context_window: 128_000,
    input_cost: "$1.75/M",
    output_cost: "$14/M",
    input_cost_value: Decimal.new("1.75"),
    input_cost_unit: :per_million_tokens,
    output_cost_value: Decimal.new("14"),
    output_cost_unit: :per_million_tokens,
    input_modalities: ["text", "image"],
    output_modalities: ["text"],
    short_description: "Adaptive reasoning, math, coding, tool use",
    detailed_description:
      "GPT-5.2 represents OpenAI's newest advancement in the GPT-5 family, featuring adaptive reasoning that dynamically allocates computational resources based on query complexity. The model responds swiftly to straightforward inquiries while dedicating greater analytical depth to intricate problems. It demonstrates consistent performance improvements across mathematics, software development, scientific analysis, and tool integration.",
    short_description_translations: %{
      "en" => "Adaptive reasoning, math, coding, tool use",
      "de" => "Adaptives Reasoning, Mathematik, Programmierung, Tool-Nutzung"
    },
    detailed_description_translations: %{
      "en" =>
        "GPT-5.2 represents OpenAI's newest advancement in the GPT-5 family, featuring adaptive reasoning that dynamically allocates computational resources based on query complexity. The model responds swiftly to straightforward inquiries while dedicating greater analytical depth to intricate problems. It demonstrates consistent performance improvements across mathematics, software development, scientific analysis, and tool integration.",
      "de" =>
        "GPT-5.2 repräsentiert OpenAIs neueste Entwicklung in der GPT-5-Familie mit adaptivem Reasoning, das Rechenressourcen dynamisch basierend auf der Abfragekomplexität zuweist. Das Modell antwortet schnell auf einfache Anfragen und widmet komplexen Problemen mehr analytische Tiefe. Es zeigt konsistente Leistungsverbesserungen in Mathematik, Software-Entwicklung, wissenschaftlicher Analyse und Tool-Integration."
    },
    released_at: ~D[2025-12-10],
    allowed_providers: ["openai"]
  },
  %{
    name: "GPT-5.2",
    key: "openrouter:openai/gpt-5.2",
    provider: "OpenAI",
    context_window: 400_000,
    input_cost: "$1.75/M",
    output_cost: "$14/M",
    input_cost_value: Decimal.new("1.75"),
    input_cost_unit: :per_million_tokens,
    output_cost_value: Decimal.new("14"),
    output_cost_unit: :per_million_tokens,
    input_modalities: ["text", "image"],
    output_modalities: ["text"],
    short_description: "Extended context, long-form tasks, documents",
    detailed_description:
      "GPT-5.2 represents OpenAI's newest advancement in the GPT-5 family, featuring adaptive reasoning that dynamically allocates computational resources based on query complexity. With an extended 400K token context window, it handles extensive documents and complex multi-step tasks while producing more logically coherent lengthy responses and exhibiting improved reliability when utilizing external tools.",
    short_description_translations: %{
      "en" => "Extended context, long-form tasks, documents",
      "de" => "Erweiterter Kontext, Langform-Aufgaben, Dokumente"
    },
    detailed_description_translations: %{
      "en" =>
        "GPT-5.2 represents OpenAI's newest advancement in the GPT-5 family, featuring adaptive reasoning that dynamically allocates computational resources based on query complexity. With an extended 400K token context window, it handles extensive documents and complex multi-step tasks while producing more logically coherent lengthy responses and exhibiting improved reliability when utilizing external tools.",
      "de" =>
        "GPT-5.2 repräsentiert OpenAIs neueste Entwicklung in der GPT-5-Familie mit adaptivem Reasoning. Mit einem erweiterten 400K Token Kontextfenster verarbeitet es umfangreiche Dokumente und komplexe mehrstufige Aufgaben, produziert logisch kohärentere lange Antworten und zeigt verbesserte Zuverlässigkeit bei der Nutzung externer Tools."
    },
    released_at: ~D[2025-12-10],
    allowed_providers: ["openai"]
  },
  %{
    name: "Kimi K2.5",
    key: "openrouter:moonshotai/kimi-k2.5",
    provider: "Moonshot AI",
    context_window: 262_144,
    input_cost: "$0.60/M",
    output_cost: "$3/M",
    input_cost_value: Decimal.new("0.60"),
    input_cost_unit: :per_million_tokens,
    output_cost_value: Decimal.new("3"),
    output_cost_unit: :per_million_tokens,
    input_modalities: ["text", "image"],
    output_modalities: ["text"],
    supports_reasoning?: true,
    short_description: "Multimodal reasoning, visual coding, agentic tools",
    detailed_description:
      "Kimi K2.5 is a native multimodal model from Moonshot AI, delivering state-of-the-art visual coding capability. Built on Kimi K2 with continued pretraining over approximately 15 trillion mixed visual and text tokens, it excels at agentic tool-calling, general reasoning tasks, and visual understanding. The model combines strong reasoning abilities with multimodal input processing.",
    short_description_translations: %{
      "en" => "Multimodal reasoning, visual coding, agentic tools",
      "de" => "Multimodales Reasoning, visuelles Coding, agentische Tools"
    },
    detailed_description_translations: %{
      "en" =>
        "Kimi K2.5 is a native multimodal model from Moonshot AI, delivering state-of-the-art visual coding capability. Built on Kimi K2 with continued pretraining over approximately 15 trillion mixed visual and text tokens, it excels at agentic tool-calling, general reasoning tasks, and visual understanding. The model combines strong reasoning abilities with multimodal input processing.",
      "de" =>
        "Kimi K2.5 ist ein natives multimodales Modell von Moonshot AI mit Spitzenleistung bei visuellem Coding. Aufbauend auf Kimi K2 mit weiterem Pretraining über etwa 15 Billionen gemischte visuelle und Text-Token, überzeugt es bei agentischem Tool-Calling, allgemeinen Reasoning-Aufgaben und visuellem Verstehen."
    },
    released_at: ~D[2026-01-27],
    allowed_providers: [
      "together",
      "fireworks",
      "deepinfra",
      "novita",
      "parasail",
      "chutes",
      "baseten",
      "venice",
      "inceptron",
      "atlascloud",
      "nextbit",
      "phala",
      "moonshot-ai",
      "siliconflow"
    ]
  },
  %{
    name: "GLM 4.7",
    key: "openrouter:z-ai/glm-4.7",
    provider: "Z.AI",
    context_window: 202_752,
    input_cost: "$0.40/M",
    output_cost: "$1.50/M",
    input_cost_value: Decimal.new("0.40"),
    input_cost_unit: :per_million_tokens,
    output_cost_value: Decimal.new("1.50"),
    output_cost_unit: :per_million_tokens,
    input_modalities: ["text"],
    output_modalities: ["text"],
    supports_reasoning?: true,
    short_description: "Enhanced coding, stable multi-step reasoning",
    detailed_description:
      "GLM 4.7 is Z.AI's flagship model featuring enhanced programming capabilities and more stable multi-step reasoning and execution. The model demonstrates notable improvements in handling sophisticated agent workflows while providing more natural dialogue quality. It uses configurable reasoning tokens for complex analytical tasks.",
    short_description_translations: %{
      "en" => "Enhanced coding, stable multi-step reasoning",
      "de" => "Verbessertes Coding, stabiles mehrstufiges Reasoning"
    },
    detailed_description_translations: %{
      "en" =>
        "GLM 4.7 is Z.AI's flagship model featuring enhanced programming capabilities and more stable multi-step reasoning and execution. The model demonstrates notable improvements in handling sophisticated agent workflows while providing more natural dialogue quality. It uses configurable reasoning tokens for complex analytical tasks.",
      "de" =>
        "GLM 4.7 ist Z.AIs Flaggschiff-Modell mit verbesserten Programmierfähigkeiten und stabilerem mehrstufigem Reasoning und Ausführung. Das Modell zeigt deutliche Verbesserungen bei der Handhabung anspruchsvoller Agenten-Workflows und bietet natürlichere Dialogqualität. Es verwendet konfigurierbare Reasoning-Token für komplexe analytische Aufgaben."
    },
    released_at: ~D[2025-12-22],
    allowed_providers: [
      "together",
      "fireworks",
      "deepinfra",
      "novita",
      "parasail",
      "venice",
      "ambient",
      "io-net",
      "atlascloud",
      "gmicloud",
      "z-ai",
      "siliconflow"
    ]
  },
  %{
    name: "DeepSeek V3.2",
    key: "openrouter:deepseek/deepseek-v3.2",
    provider: "DeepSeek",
    context_window: 163_840,
    input_cost: "$0.25/M",
    output_cost: "$0.38/M",
    input_cost_value: Decimal.new("0.25"),
    input_cost_unit: :per_million_tokens,
    output_cost_value: Decimal.new("0.38"),
    output_cost_unit: :per_million_tokens,
    input_modalities: ["text"],
    output_modalities: ["text"],
    supports_reasoning?: true,
    short_description: "Efficient reasoning, sparse attention, math olympiad",
    detailed_description:
      "DeepSeek V3.2 balances computational efficiency with strong reasoning capabilities. It introduces DeepSeek Sparse Attention (DSA), a fine-grained sparse attention mechanism that reduces training and inference cost while maintaining quality for extended contexts. The system uses reinforcement learning post-training to enhance reasoning performance and demonstrates competitive results on mathematical olympiad problems.",
    short_description_translations: %{
      "en" => "Efficient reasoning, sparse attention, math olympiad",
      "de" => "Effizientes Reasoning, Sparse Attention, Mathematik-Olympiade"
    },
    detailed_description_translations: %{
      "en" =>
        "DeepSeek V3.2 balances computational efficiency with strong reasoning capabilities. It introduces DeepSeek Sparse Attention (DSA), a fine-grained sparse attention mechanism that reduces training and inference cost while maintaining quality for extended contexts. The system uses reinforcement learning post-training to enhance reasoning performance and demonstrates competitive results on mathematical olympiad problems.",
      "de" =>
        "DeepSeek V3.2 kombiniert rechnerische Effizienz mit starken Reasoning-Fähigkeiten. Es führt DeepSeek Sparse Attention (DSA) ein, einen feingranularen Sparse-Attention-Mechanismus, der Trainings- und Inferenzkosten reduziert und gleichzeitig Qualität bei erweiterten Kontexten erhält. Das System verwendet Reinforcement Learning Post-Training und zeigt wettbewerbsfähige Ergebnisse bei mathematischen Olympiade-Problemen."
    },
    released_at: ~D[2025-12-01],
    allowed_providers: ["deepinfra", "novita", "atlascloud"]
  },
  %{
    name: "Qwen3 VL 32B",
    key: "openrouter:qwen/qwen3-vl-32b-instruct",
    provider: "Qwen",
    context_window: 262_144,
    input_cost: "$0.50/M",
    output_cost: "$1.50/M",
    input_cost_value: Decimal.new("0.50"),
    input_cost_unit: :per_million_tokens,
    output_cost_value: Decimal.new("1.50"),
    output_cost_unit: :per_million_tokens,
    input_modalities: ["text", "image"],
    output_modalities: ["text"],
    short_description: "Vision-language, OCR, document analysis, video",
    detailed_description:
      "Qwen3 VL 32B is a multimodal vision-language model with 32 billion parameters designed for understanding across text, images, and video. The model features fine-grained spatial reasoning, document and scene analysis, and long-horizon video understanding with OCR capabilities across 32 languages and enhanced multimodal fusion through specialized architectures.",
    short_description_translations: %{
      "en" => "Vision-language, OCR, document analysis, video",
      "de" => "Vision-Sprache, OCR, Dokumentenanalyse, Video"
    },
    detailed_description_translations: %{
      "en" =>
        "Qwen3 VL 32B is a multimodal vision-language model with 32 billion parameters designed for understanding across text, images, and video. The model features fine-grained spatial reasoning, document and scene analysis, and long-horizon video understanding with OCR capabilities across 32 languages and enhanced multimodal fusion through specialized architectures.",
      "de" =>
        "Qwen3 VL 32B ist ein multimodales Vision-Sprache-Modell mit 32 Milliarden Parametern für das Verstehen von Text, Bildern und Video. Das Modell bietet feingranulares räumliches Reasoning, Dokument- und Szenenanalyse sowie langfristiges Videoverstehen mit OCR-Fähigkeiten in 32 Sprachen und verbesserter multimodaler Fusion."
    },
    released_at: ~D[2025-10-23],
    allowed_providers: ["alibaba", "atlascloud", "novita"]
  },
  # Image Generation Models
  %{
    name: "Gemini 3 Pro Image",
    key: "openrouter:google/gemini-3-pro-image-preview",
    provider: "Google",
    context_window: 1_048_576,
    input_cost: "$1.25/M",
    output_cost: "$5/M",
    input_cost_value: Decimal.new("1.25"),
    input_cost_unit: :per_million_tokens,
    output_cost_value: Decimal.new("5"),
    output_cost_unit: :per_million_tokens,
    input_modalities: ["text", "image"],
    output_modalities: ["image"],
    short_description: "Text + image generation, multimodal reasoning",
    detailed_description:
      "Gemini 3 Pro Image combines the advanced reasoning capabilities of Gemini 3 Pro with native image generation, enabling seamless multimodal workflows. The model can understand, analyze, and generate images while maintaining the full context window and reasoning abilities of the text model, making it ideal for creative and analytical visual tasks.",
    short_description_translations: %{
      "en" => "Text + image generation, multimodal reasoning",
      "de" => "Text + Bildgenerierung, multimodales Reasoning"
    },
    detailed_description_translations: %{
      "en" =>
        "Gemini 3 Pro Image combines the advanced reasoning capabilities of Gemini 3 Pro with native image generation, enabling seamless multimodal workflows. The model can understand, analyze, and generate images while maintaining the full context window and reasoning abilities of the text model, making it ideal for creative and analytical visual tasks.",
      "de" =>
        "Gemini 3 Pro Image kombiniert die fortgeschrittenen Reasoning-Fähigkeiten von Gemini 3 Pro mit nativer Bildgenerierung für nahtlose multimodale Workflows. Das Modell kann Bilder verstehen, analysieren und generieren, während es das volle Kontextfenster und die Reasoning-Fähigkeiten des Textmodells beibehält."
    },
    allowed_providers: ["google-ai-studio", "google-vertex"]
  },
  %{
    name: "FLUX.2 Pro",
    key: "openrouter:black-forest-labs/flux.2-pro",
    provider: "Black Forest Labs",
    input_cost: "$0.015/MP",
    output_cost: "$0.03/MP",
    input_cost_value: Decimal.new("0.015"),
    input_cost_unit: :per_megapixel,
    output_cost_value: Decimal.new("0.03"),
    output_cost_unit: :per_megapixel,
    input_modalities: ["text", "image"],
    output_modalities: ["image"],
    short_description: "Premium image quality, prompt adherence, up to 4MP",
    detailed_description:
      "FLUX.2 Pro represents Black Forest Labs' advanced approach to image synthesis, combining frontier-level visual capabilities with production-ready stability. The model excels at rendering sharp textures, maintaining consistent lighting conditions, and reproducing subjects reliably across multi-reference inputs. It supports both text-to-image generation and sophisticated image editing workflows, handling resolutions up to 4 MP.",
    short_description_translations: %{
      "en" => "Premium image quality, prompt adherence, up to 4MP",
      "de" => "Premium-Bildqualität, Prompt-Treue, bis zu 4MP"
    },
    detailed_description_translations: %{
      "en" =>
        "FLUX.2 Pro represents Black Forest Labs' advanced approach to image synthesis, combining frontier-level visual capabilities with production-ready stability. The model excels at rendering sharp textures, maintaining consistent lighting conditions, and reproducing subjects reliably across multi-reference inputs. It supports both text-to-image generation and sophisticated image editing workflows, handling resolutions up to 4 MP.",
      "de" =>
        "FLUX.2 Pro repräsentiert Black Forest Labs' fortgeschrittenen Ansatz zur Bildsynthese, der Spitzen-Visualfähigkeiten mit produktionsreifer Stabilität kombiniert. Das Modell überzeugt beim Rendern scharfer Texturen, konsistenter Beleuchtung und zuverlässiger Subjektreproduktion. Es unterstützt Text-zu-Bild-Generierung und Bildbearbeitung bis zu 4 MP."
    },
    released_at: ~D[2025-11-25],
    allowed_providers: ["black-forest-labs"]
  },
  %{
    name: "GPT-5 Image",
    key: "openrouter:openai/gpt-5-image",
    provider: "OpenAI",
    context_window: 400_000,
    input_cost: "$10/M",
    output_cost: "$10/M",
    input_cost_value: Decimal.new("10"),
    input_cost_unit: :per_million_tokens,
    output_cost_value: Decimal.new("10"),
    output_cost_unit: :per_million_tokens,
    input_modalities: ["text", "image", "file"],
    output_modalities: ["text", "image"],
    short_description: "Image generation, file processing, multimodal",
    detailed_description:
      "GPT-5 Image extends OpenAI's GPT-5 capabilities with native image generation and comprehensive file understanding. The model handles text, images, and files as inputs while producing both text and images as outputs, enabling end-to-end multimodal workflows for creative, analytical, and document-processing tasks.",
    short_description_translations: %{
      "en" => "Image generation, file processing, multimodal",
      "de" => "Bildgenerierung, Dateiverarbeitung, multimodal"
    },
    detailed_description_translations: %{
      "en" =>
        "GPT-5 Image extends OpenAI's GPT-5 capabilities with native image generation and comprehensive file understanding. The model handles text, images, and files as inputs while producing both text and images as outputs, enabling end-to-end multimodal workflows for creative, analytical, and document-processing tasks.",
      "de" =>
        "GPT-5 Image erweitert OpenAIs GPT-5-Fähigkeiten um native Bildgenerierung und umfassendes Dateiverstehen. Das Modell verarbeitet Text, Bilder und Dateien als Eingabe und produziert sowohl Text als auch Bilder, was End-to-End multimodale Workflows für kreative, analytische und Dokumentenverarbeitungsaufgaben ermöglicht."
    },
    allowed_providers: ["openai"]
  },
  # xAI Direct API Models
  %{
    name: "Grok 2 Image",
    key: "xai:grok-2-image",
    provider: "xAI",
    api_provider: :xai,
    input_cost: "$0.10/image",
    output_cost: "$0.10/image",
    input_cost_value: Decimal.new("0.10"),
    input_cost_unit: :per_image,
    output_cost_value: Decimal.new("0.10"),
    output_cost_unit: :per_image,
    input_modalities: ["text"],
    output_modalities: ["image"],
    supports_tools?: false,
    short_description: "Fast image generation from xAI",
    detailed_description:
      "Grok 2 Image is xAI's dedicated image generation model, providing fast and high-quality image synthesis. The model accepts text prompts and generates JPG images, supporting up to 10 images per request. Built on xAI's infrastructure, it offers a streamlined API for creative applications requiring reliable image output.",
    short_description_translations: %{
      "en" => "Fast image generation from xAI",
      "de" => "Schnelle Bildgenerierung von xAI"
    },
    detailed_description_translations: %{
      "en" =>
        "Grok 2 Image is xAI's dedicated image generation model, providing fast and high-quality image synthesis. The model accepts text prompts and generates JPG images, supporting up to 10 images per request. Built on xAI's infrastructure, it offers a streamlined API for creative applications requiring reliable image output.",
      "de" =>
        "Grok 2 Image ist xAIs dediziertes Bildgenerierungsmodell für schnelle und hochwertige Bildsynthese. Das Modell akzeptiert Textprompts und generiert JPG-Bilder, bis zu 10 Bilder pro Anfrage. Aufgebaut auf xAIs Infrastruktur bietet es eine optimierte API für kreative Anwendungen."
    },
    info: "This model has no context of prior images or prompts. Each generation is independent.",
    released_at: ~D[2024-12-12],
    allowed_providers: []
  },
  # PublicAI Models (Swiss AI)
  # Video Generation Models (AIML API)
  %{
    name: "Veo 3.1 (Text)",
    key: "aimlapi:google/veo-3.1-t2v",
    provider: "Google",
    api_provider: :aimlapi,
    input_cost: "$0.21/s",
    output_cost: "$0.21/s",
    input_cost_value: Decimal.new("0.21"),
    input_cost_unit: :per_second,
    output_cost_value: Decimal.new("0.21"),
    output_cost_unit: :per_second,
    input_modalities: ["text"],
    output_modalities: ["video"],
    supports_tools?: false,
    active?: false,
    short_description: "Text-to-video with audio, 1080p, lip-sync, 4-8s",
    detailed_description:
      "Google DeepMind Veo 3.1 creates high-fidelity videos from text with cinematic realism, native audio generation (ambient sounds, dialogue, music), and realistic lip-sync for speaking characters. Features natural lighting, smooth camera transitions, and subject consistency. Produces 4-8 second videos at up to 1080p, 24 fps.",
    short_description_translations: %{
      "en" => "Text-to-video with audio, 1080p, lip-sync, 4-8s",
      "de" => "Text-zu-Video mit Audio, 1080p, Lippensync, 4-8s"
    },
    detailed_description_translations: %{
      "en" =>
        "Google DeepMind Veo 3.1 creates high-fidelity videos from text with cinematic realism, native audio generation (ambient sounds, dialogue, music), and realistic lip-sync for speaking characters. Features natural lighting, smooth camera transitions, and subject consistency. Produces 4-8 second videos at up to 1080p, 24 fps.",
      "de" =>
        "Google DeepMind Veo 3.1 erstellt hochwertige Videos aus Text mit kinoreifem Realismus, nativer Audiogenerierung (Umgebungsgeräusche, Dialog, Musik) und realistischem Lippensync. Mit natürlicher Beleuchtung, fließenden Kameraübergängen und Subjektkonsistenz. Produziert 4-8 Sekunden Videos bis 1080p, 24 fps."
    },
    info: "Videos generate in 1-3 minutes.",
    released_at: ~D[2025-12-01],
    options: %{
      "aspect_ratio" => ["16:9", "9:16"],
      "duration" => ["4", "6", "8"],
      "resolution" => ["720p", "1080p"],
      "generate_audio" => ["true", "false"]
    },
    allowed_providers: []
  },
  %{
    name: "Veo 3.1 (Image)",
    key: "aimlapi:google/veo-3.1-i2v",
    provider: "Google",
    api_provider: :aimlapi,
    input_cost: "$0.21/s",
    output_cost: "$0.21/s",
    input_cost_value: Decimal.new("0.21"),
    input_cost_unit: :per_second,
    output_cost_value: Decimal.new("0.21"),
    output_cost_unit: :per_second,
    input_modalities: ["text", "image"],
    output_modalities: ["video"],
    supports_tools?: false,
    active?: false,
    short_description: "Image-to-video with audio, 720p, cinematic motion",
    detailed_description:
      "Google DeepMind Veo 3.1 transforms static images into smooth, cinematic video sequences with native audio generation. Features pan, tilt, zoom, and dolly camera movements, frame interpolation for smooth transitions, and contextual understanding for natural scene flow. Produces up to 8 seconds at 720p.",
    short_description_translations: %{
      "en" => "Image-to-video with audio, 720p, cinematic motion",
      "de" => "Bild-zu-Video mit Audio, 720p, kinoreife Bewegung"
    },
    detailed_description_translations: %{
      "en" =>
        "Google DeepMind Veo 3.1 transforms static images into smooth, cinematic video sequences with native audio generation. Features pan, tilt, zoom, and dolly camera movements, frame interpolation for smooth transitions, and contextual understanding for natural scene flow. Produces up to 8 seconds at 720p.",
      "de" =>
        "Google DeepMind Veo 3.1 transformiert statische Bilder in fließende, kinoreife Videosequenzen mit nativer Audiogenerierung. Mit Schwenk-, Neige-, Zoom- und Dolly-Kamerabewegungen, Frame-Interpolation für sanfte Übergänge und kontextuellem Verständnis für natürlichen Szenenfluss. Bis zu 8 Sekunden bei 720p."
    },
    info: "Upload an image and describe the motion. Videos generate in 1-3 minutes.",
    released_at: ~D[2025-12-01],
    options: %{
      "aspect_ratio" => ["16:9", "9:16"],
      "duration" => ["4", "6", "8"],
      "resolution" => ["720p", "1080p"],
      "generate_audio" => ["true", "false"]
    },
    allowed_providers: []
  },
  %{
    name: "Veo 3.1 Fast (Text)",
    key: "aimlapi:google/veo-3.1-t2v-fast",
    provider: "Google",
    api_provider: :aimlapi,
    input_cost: "$0.105/s",
    output_cost: "$0.105/s",
    input_cost_value: Decimal.new("0.105"),
    input_cost_unit: :per_second,
    output_cost_value: Decimal.new("0.105"),
    output_cost_unit: :per_second,
    input_modalities: ["text"],
    output_modalities: ["video"],
    supports_tools?: false,
    active?: false,
    short_description: "Fast text-to-video with audio, 1080p, 8s clips",
    detailed_description:
      "Google DeepMind Veo 3.1 Fast is an accelerated variant for rapid text-to-video generation. Produces high-quality videos at up to 1080p with realistic natural motion, cinematographic camera movements, and synchronized native audio. Generates 8-second clips at 24 fps with cinematic quality, dialogue lip-sync, and integrated sound effects.",
    short_description_translations: %{
      "en" => "Fast text-to-video with audio, 1080p, 8s clips",
      "de" => "Schnelles Text-zu-Video mit Audio, 1080p, 8s Clips"
    },
    detailed_description_translations: %{
      "en" =>
        "Google DeepMind Veo 3.1 Fast is an accelerated variant for rapid text-to-video generation. Produces high-quality videos at up to 1080p with realistic natural motion, cinematographic camera movements, and synchronized native audio. Generates 8-second clips at 24 fps with cinematic quality, dialogue lip-sync, and integrated sound effects.",
      "de" =>
        "Google DeepMind Veo 3.1 Fast ist eine beschleunigte Variante für schnelle Text-zu-Video-Generierung. Produziert hochwertige Videos bis 1080p mit realistischer natürlicher Bewegung, kinematografischen Kamerabewegungen und synchronisiertem nativem Audio. Generiert 8-Sekunden-Clips bei 24 fps mit Kinoqualität."
    },
    info: "Videos generate in 1-3 minutes.",
    released_at: ~D[2025-12-01],
    options: %{
      "aspect_ratio" => ["16:9", "9:16"],
      "duration" => ["4", "6", "8"],
      "resolution" => ["720p", "1080p"],
      "generate_audio" => ["true", "false"]
    },
    allowed_providers: []
  },
  %{
    name: "Veo 3.1 Fast (Image)",
    key: "aimlapi:google/veo-3.1-i2v-fast",
    provider: "Google",
    api_provider: :aimlapi,
    input_cost: "$0.105/s",
    output_cost: "$0.105/s",
    input_cost_value: Decimal.new("0.105"),
    input_cost_unit: :per_second,
    output_cost_value: Decimal.new("0.105"),
    output_cost_unit: :per_second,
    input_modalities: ["text", "image"],
    output_modalities: ["video"],
    supports_tools?: false,
    active?: false,
    short_description: "Fast image-to-video with audio, 1080p, 4-8s",
    detailed_description:
      "Google DeepMind Veo 3.1 Fast converts static images into 1080p videos with synchronized audio at accelerated processing speeds. Features smooth animations, ambient sounds, music, dialogue, and support for 16:9 and 9:16 aspect ratios. Customizable clip lengths of 4, 6, or 8 seconds while preserving original image style.",
    short_description_translations: %{
      "en" => "Fast image-to-video with audio, 1080p, 4-8s",
      "de" => "Schnelles Bild-zu-Video mit Audio, 1080p, 4-8s"
    },
    detailed_description_translations: %{
      "en" =>
        "Google DeepMind Veo 3.1 Fast converts static images into 1080p videos with synchronized audio at accelerated processing speeds. Features smooth animations, ambient sounds, music, dialogue, and support for 16:9 and 9:16 aspect ratios. Customizable clip lengths of 4, 6, or 8 seconds while preserving original image style.",
      "de" =>
        "Google DeepMind Veo 3.1 Fast konvertiert statische Bilder in 1080p-Videos mit synchronisiertem Audio bei beschleunigter Verarbeitung. Mit fließenden Animationen, Umgebungsgeräuschen, Musik, Dialog und Unterstützung für 16:9 und 9:16 Seitenverhältnisse. Anpassbare Cliplängen von 4, 6 oder 8 Sekunden."
    },
    info: "Upload an image and describe the motion. Videos generate in 1-3 minutes.",
    released_at: ~D[2025-12-01],
    options: %{
      "aspect_ratio" => ["16:9", "9:16"],
      "duration" => ["4", "6", "8"],
      "resolution" => ["720p", "1080p"],
      "generate_audio" => ["true", "false"]
    },
    allowed_providers: []
  },
  %{
    name: "Sora 2 Pro (Text)",
    key: "aimlapi:openai/sora-2-pro-t2v",
    provider: "OpenAI",
    api_provider: :aimlapi,
    input_cost: "$0.315/s",
    output_cost: "$0.315/s",
    input_cost_value: Decimal.new("0.315"),
    input_cost_unit: :per_second,
    output_cost_value: Decimal.new("0.315"),
    output_cost_unit: :per_second,
    input_modalities: ["text"],
    output_modalities: ["video"],
    supports_tools?: false,
    active?: false,
    short_description: "Text-to-video with audio, 720p/1080p, physics-aware",
    detailed_description:
      "OpenAI Sora 2 Pro generates high-quality videos from text with integrated audio synthesis (speech, effects, music). Features physics-aware rendering for realistic object motion and collisions, multilingual support, and fine-grained style control. Produces 4-12 second videos at 720p or 1080p with 24-30 fps cinematic quality.",
    short_description_translations: %{
      "en" => "Text-to-video with audio, 720p/1080p, physics-aware",
      "de" => "Text-zu-Video mit Audio, 720p/1080p, physik-bewusst"
    },
    detailed_description_translations: %{
      "en" =>
        "OpenAI Sora 2 Pro generates high-quality videos from text with integrated audio synthesis (speech, effects, music). Features physics-aware rendering for realistic object motion and collisions, multilingual support, and fine-grained style control. Produces 4-12 second videos at 720p or 1080p with 24-30 fps cinematic quality.",
      "de" =>
        "OpenAI Sora 2 Pro generiert hochwertige Videos aus Text mit integrierter Audiosynthese (Sprache, Effekte, Musik). Mit physik-bewusstem Rendering für realistische Objektbewegung und Kollisionen, mehrsprachiger Unterstützung und feingranularer Stilkontrolle. Produziert 4-12 Sekunden Videos bei 720p oder 1080p mit 24-30 fps."
    },
    info: "Videos generate in 1-3 minutes.",
    released_at: ~D[2025-11-01],
    options: %{
      "aspect_ratio" => ["16:9", "9:16"],
      "duration" => ["4", "8", "12"],
      "resolution" => ["720p", "1080p"]
    },
    allowed_providers: []
  },
  %{
    name: "Sora 2 Pro (Image)",
    key: "aimlapi:openai/sora-2-pro-i2v",
    provider: "OpenAI",
    api_provider: :aimlapi,
    input_cost: "$0.315/s",
    output_cost: "$0.315/s",
    input_cost_value: Decimal.new("0.315"),
    input_cost_unit: :per_second,
    output_cost_value: Decimal.new("0.315"),
    output_cost_unit: :per_second,
    input_modalities: ["text", "image"],
    output_modalities: ["video"],
    supports_tools?: false,
    active?: false,
    short_description: "Image-to-video with audio, 720p/1080p, physics-aware",
    detailed_description:
      "OpenAI Sora 2 Pro transforms static images into dynamic videos with synchronized audio. Features physics simulation for realistic movement, high customization via text prompts, and maintains visual quality throughout. Produces 4-12 second videos at 720p or 1080p (up to 1792x1024) with 24-30 fps.",
    short_description_translations: %{
      "en" => "Image-to-video with audio, 720p/1080p, physics-aware",
      "de" => "Bild-zu-Video mit Audio, 720p/1080p, physik-bewusst"
    },
    detailed_description_translations: %{
      "en" =>
        "OpenAI Sora 2 Pro transforms static images into dynamic videos with synchronized audio. Features physics simulation for realistic movement, high customization via text prompts, and maintains visual quality throughout. Produces 4-12 second videos at 720p or 1080p (up to 1792x1024) with 24-30 fps.",
      "de" =>
        "OpenAI Sora 2 Pro transformiert statische Bilder in dynamische Videos mit synchronisiertem Audio. Mit Physiksimulation für realistische Bewegung, hoher Anpassung über Textprompts und durchgehender visueller Qualität. Produziert 4-12 Sekunden Videos bei 720p oder 1080p (bis zu 1792x1024) mit 24-30 fps."
    },
    info: "Upload an image and describe the motion. Videos generate in 1-3 minutes.",
    released_at: ~D[2025-11-01],
    options: %{
      "aspect_ratio" => ["16:9", "9:16"],
      "duration" => ["4", "8", "12"],
      "resolution" => ["720p", "1080p"]
    },
    allowed_providers: []
  },
  %{
    name: "Seedance 1.0 Lite (Text)",
    key: "aimlapi:bytedance/seedance-1-0-lite-t2v",
    provider: "ByteDance",
    api_provider: :aimlapi,
    input_cost: "$0.05/video",
    output_cost: "$0.05/video",
    input_cost_value: Decimal.new("0.05"),
    input_cost_unit: :per_video,
    output_cost_value: Decimal.new("0.05"),
    output_cost_unit: :per_video,
    input_modalities: ["text"],
    output_modalities: ["video"],
    supports_tools?: false,
    active?: false,
    short_description: "Fast text-to-video, 5-10s, character control",
    detailed_description:
      "Seedance 1.0 Lite from ByteDance is a high-speed, cost-effective video generation model producing 5-10 second videos up to 1080p at 24 FPS. Features fine-grained character control for facial expressions, clothing, and multi-subject motion. Supports diverse styles including anime, cinematic, 3D, and sketch.",
    short_description_translations: %{
      "en" => "Fast text-to-video, 5-10s, character control",
      "de" => "Schnelles Text-zu-Video, 5-10s, Charakterkontrolle"
    },
    detailed_description_translations: %{
      "en" =>
        "Seedance 1.0 Lite from ByteDance is a high-speed, cost-effective video generation model producing 5-10 second videos up to 1080p at 24 FPS. Features fine-grained character control for facial expressions, clothing, and multi-subject motion. Supports diverse styles including anime, cinematic, 3D, and sketch.",
      "de" =>
        "Seedance 1.0 Lite von ByteDance ist ein schnelles, kosteneffektives Videogenerierungsmodell für 5-10 Sekunden Videos bis 1080p bei 24 FPS. Mit feingranularer Charakterkontrolle für Gesichtsausdrücke, Kleidung und Mehrsubjekt-Bewegung. Unterstützt verschiedene Stile wie Anime, Kino, 3D und Skizze."
    },
    info:
      "Videos generate in ~40-50 seconds. Supports camera controls: pan, zoom, aerial, follow, and handheld movements.",
    released_at: ~D[2025-06-01],
    options: %{
      "duration" => ["5", "10"],
      "resolution" => ["480p", "720p", "1080p"]
    },
    allowed_providers: []
  },
  %{
    name: "Seedance 1.0 Lite (Image)",
    key: "aimlapi:bytedance/seedance-1-0-lite-i2v",
    provider: "ByteDance",
    api_provider: :aimlapi,
    input_cost: "$0.05/video",
    output_cost: "$0.05/video",
    input_cost_value: Decimal.new("0.05"),
    input_cost_unit: :per_video,
    output_cost_value: Decimal.new("0.05"),
    output_cost_unit: :per_video,
    input_modalities: ["text", "image"],
    output_modalities: ["video"],
    supports_tools?: false,
    active?: false,
    short_description: "Image-to-video, 5-10s, cinematic motion",
    detailed_description:
      "Seedance 1.0 Lite Image-to-Video transforms single images into smooth, cinematic 5-10 second video clips at up to 1080p resolution. Maintains character appearance consistency with professional-grade motion and film-style lighting effects.",
    short_description_translations: %{
      "en" => "Image-to-video, 5-10s, cinematic motion",
      "de" => "Bild-zu-Video, 5-10s, kinoreife Bewegung"
    },
    detailed_description_translations: %{
      "en" =>
        "Seedance 1.0 Lite Image-to-Video transforms single images into smooth, cinematic 5-10 second video clips at up to 1080p resolution. Maintains character appearance consistency with professional-grade motion and film-style lighting effects.",
      "de" =>
        "Seedance 1.0 Lite Bild-zu-Video transformiert einzelne Bilder in fließende, kinoreife 5-10 Sekunden Videoclips bis zu 1080p Auflösung. Erhält Charakterkonsistenz mit professioneller Bewegung und filmreifer Beleuchtung."
    },
    info:
      "Upload an image and describe the motion. Generates in ~15 seconds. Supports camera controls: pan, zoom, follow, aerial, handheld.",
    released_at: ~D[2025-06-01],
    options: %{
      "duration" => ["5", "10"],
      "resolution" => ["480p", "720p", "1080p"]
    },
    allowed_providers: []
  },
  # Video Generation Models (Fal.ai)
  %{
    name: "Veo 3.1 (Text)",
    key: "fal:fal-ai/veo3.1",
    provider: "Google",
    api_provider: :fal,
    input_cost: "$0.20-0.60/s",
    output_cost: "$0.20-0.60/s",
    input_cost_value: Decimal.new("0.20"),
    input_cost_unit: :per_second,
    output_cost_value: Decimal.new("0.20"),
    output_cost_unit: :per_second,
    input_modalities: ["text"],
    output_modalities: ["video"],
    supports_tools?: false,
    active?: false,
    short_description: "Text-to-video with audio, up to 4K, lip-sync, 4-8s",
    detailed_description:
      "Google DeepMind Veo 3.1 via Fal creates high-fidelity videos from text with cinematic realism, native audio generation (ambient sounds, dialogue, music), and realistic lip-sync. Produces 4-8 second videos at up to 4K resolution.",
    short_description_translations: %{
      "en" => "Text-to-video with audio, up to 4K, lip-sync, 4-8s",
      "de" => "Text-zu-Video mit Audio, bis 4K, Lippensync, 4-8s"
    },
    detailed_description_translations: %{
      "en" =>
        "Google DeepMind Veo 3.1 via Fal creates high-fidelity videos from text with cinematic realism, native audio generation (ambient sounds, dialogue, music), and realistic lip-sync. Produces 4-8 second videos at up to 4K resolution.",
      "de" =>
        "Google DeepMind Veo 3.1 über Fal erstellt hochwertige Videos aus Text mit kinoreifem Realismus, nativer Audiogenerierung (Umgebungsgeräusche, Dialog, Musik) und realistischem Lippensync. Produziert 4-8 Sekunden Videos bis zu 4K Auflösung."
    },
    info: "Videos generate in 1-5 minutes.",
    released_at: ~D[2025-12-01],
    options: %{
      "aspect_ratio" => ["16:9", "9:16"],
      "duration" => ["4", "6", "8"],
      "resolution" => ["720p", "1080p", "4k"],
      "generate_audio" => ["true", "false"]
    },
    allowed_providers: []
  },
  %{
    name: "Veo 3.1 Fast (Text)",
    key: "fal:fal-ai/veo3.1/fast",
    provider: "Google",
    api_provider: :fal,
    input_cost: "$0.10-0.35/s",
    output_cost: "$0.10-0.35/s",
    input_cost_value: Decimal.new("0.10"),
    input_cost_unit: :per_second,
    output_cost_value: Decimal.new("0.10"),
    output_cost_unit: :per_second,
    input_modalities: ["text"],
    output_modalities: ["video"],
    supports_tools?: false,
    active?: false,
    short_description: "Fast text-to-video with audio, up to 4K, 4-8s",
    detailed_description:
      "Google DeepMind Veo 3.1 Fast via Fal is an accelerated variant for rapid text-to-video generation with audio. Produces high-quality videos at up to 4K with realistic motion and synchronized audio.",
    short_description_translations: %{
      "en" => "Fast text-to-video with audio, up to 4K, 4-8s",
      "de" => "Schnelles Text-zu-Video mit Audio, bis 4K, 4-8s"
    },
    detailed_description_translations: %{
      "en" =>
        "Google DeepMind Veo 3.1 Fast via Fal is an accelerated variant for rapid text-to-video generation with audio. Produces high-quality videos at up to 4K with realistic motion and synchronized audio.",
      "de" =>
        "Google DeepMind Veo 3.1 Fast über Fal ist eine beschleunigte Variante für schnelle Text-zu-Video-Generierung mit Audio. Produziert hochwertige Videos bis 4K mit realistischer Bewegung und synchronisiertem Audio."
    },
    info: "Videos generate in 1-3 minutes.",
    released_at: ~D[2025-12-01],
    options: %{
      "aspect_ratio" => ["16:9", "9:16"],
      "duration" => ["4", "6", "8"],
      "resolution" => ["720p", "1080p", "4k"],
      "generate_audio" => ["true", "false"]
    },
    allowed_providers: []
  },
  %{
    name: "Veo 3.1 (Image)",
    key: "fal:fal-ai/veo3.1/image-to-video",
    provider: "Google",
    api_provider: :fal,
    input_cost: "$0.20-0.60/s",
    output_cost: "$0.20-0.60/s",
    input_cost_value: Decimal.new("0.20"),
    input_cost_unit: :per_second,
    output_cost_value: Decimal.new("0.20"),
    output_cost_unit: :per_second,
    input_modalities: ["text", "image"],
    output_modalities: ["video"],
    supports_tools?: false,
    active?: false,
    short_description: "Image-to-video with audio, up to 4K, cinematic motion",
    detailed_description:
      "Google DeepMind Veo 3.1 via Fal transforms static images into smooth, cinematic video sequences with native audio generation. Supports up to 4K resolution.",
    short_description_translations: %{
      "en" => "Image-to-video with audio, up to 4K, cinematic motion",
      "de" => "Bild-zu-Video mit Audio, bis 4K, kinoreife Bewegung"
    },
    detailed_description_translations: %{
      "en" =>
        "Google DeepMind Veo 3.1 via Fal transforms static images into smooth, cinematic video sequences with native audio generation. Supports up to 4K resolution.",
      "de" =>
        "Google DeepMind Veo 3.1 über Fal transformiert statische Bilder in fließende, kinoreife Videosequenzen mit nativer Audiogenerierung. Unterstützt bis zu 4K Auflösung."
    },
    info: "Upload an image and describe the motion. Videos generate in 1-5 minutes.",
    released_at: ~D[2025-12-01],
    options: %{
      "aspect_ratio" => ["auto", "16:9", "9:16"],
      "duration" => ["4", "6", "8"],
      "resolution" => ["720p", "1080p", "4k"],
      "generate_audio" => ["true", "false"]
    },
    allowed_providers: []
  },
  %{
    name: "Veo 3.1 Fast (Image)",
    key: "fal:fal-ai/veo3.1/fast/image-to-video",
    provider: "Google",
    api_provider: :fal,
    input_cost: "$0.10-0.35/s",
    output_cost: "$0.10-0.35/s",
    input_cost_value: Decimal.new("0.10"),
    input_cost_unit: :per_second,
    output_cost_value: Decimal.new("0.10"),
    output_cost_unit: :per_second,
    input_modalities: ["text", "image"],
    output_modalities: ["video"],
    supports_tools?: false,
    active?: false,
    short_description: "Fast image-to-video with audio, up to 4K, 4-8s",
    detailed_description:
      "Google DeepMind Veo 3.1 Fast via Fal converts static images into videos with synchronized audio at accelerated processing speeds. Supports up to 4K resolution.",
    short_description_translations: %{
      "en" => "Fast image-to-video with audio, up to 4K, 4-8s",
      "de" => "Schnelles Bild-zu-Video mit Audio, bis 4K, 4-8s"
    },
    detailed_description_translations: %{
      "en" =>
        "Google DeepMind Veo 3.1 Fast via Fal converts static images into videos with synchronized audio at accelerated processing speeds. Supports up to 4K resolution.",
      "de" =>
        "Google DeepMind Veo 3.1 Fast über Fal konvertiert statische Bilder in Videos mit synchronisiertem Audio bei beschleunigter Verarbeitung. Unterstützt bis zu 4K Auflösung."
    },
    info: "Upload an image and describe the motion. Videos generate in 1-3 minutes.",
    released_at: ~D[2025-12-01],
    options: %{
      "aspect_ratio" => ["auto", "16:9", "9:16"],
      "duration" => ["4", "6", "8"],
      "resolution" => ["720p", "1080p", "4k"],
      "generate_audio" => ["true", "false"]
    },
    allowed_providers: []
  },
  %{
    name: "Sora 2 (Text)",
    key: "fal:fal-ai/sora-2/text-to-video",
    provider: "OpenAI",
    api_provider: :fal,
    input_cost: "$0.10/s",
    output_cost: "$0.10/s",
    input_cost_value: Decimal.new("0.10"),
    input_cost_unit: :per_second,
    output_cost_value: Decimal.new("0.10"),
    output_cost_unit: :per_second,
    input_modalities: ["text"],
    output_modalities: ["video"],
    supports_tools?: false,
    active?: false,
    short_description: "Text-to-video, 720p, up to 20s, physics-aware",
    detailed_description:
      "OpenAI Sora 2 via Fal generates high-quality videos from text with physics-aware rendering. Produces 4-20 second videos at 720p.",
    short_description_translations: %{
      "en" => "Text-to-video, 720p, up to 20s, physics-aware",
      "de" => "Text-zu-Video, 720p, bis 20s, physik-bewusst"
    },
    detailed_description_translations: %{
      "en" =>
        "OpenAI Sora 2 via Fal generates high-quality videos from text with physics-aware rendering. Produces 4-20 second videos at 720p.",
      "de" =>
        "OpenAI Sora 2 über Fal generiert hochwertige Videos aus Text mit physik-bewusstem Rendering. Produziert 4-20 Sekunden Videos bei 720p."
    },
    info: "Videos generate in 1-5 minutes.",
    released_at: ~D[2025-11-01],
    options: %{
      "aspect_ratio" => ["16:9", "9:16"],
      "duration" => ["4", "8", "12", "16", "20"],
      "resolution" => ["auto", "720p"]
    },
    allowed_providers: []
  },
  %{
    name: "Sora 2 (Image)",
    key: "fal:fal-ai/sora-2/image-to-video",
    provider: "OpenAI",
    api_provider: :fal,
    input_cost: "$0.10/s",
    output_cost: "$0.10/s",
    input_cost_value: Decimal.new("0.10"),
    input_cost_unit: :per_second,
    output_cost_value: Decimal.new("0.10"),
    output_cost_unit: :per_second,
    input_modalities: ["text", "image"],
    output_modalities: ["video"],
    supports_tools?: false,
    active?: false,
    short_description: "Image-to-video, 720p, up to 20s, physics-aware",
    detailed_description:
      "OpenAI Sora 2 via Fal transforms images into dynamic videos with physics simulation. Produces 4-20 second videos at 720p.",
    short_description_translations: %{
      "en" => "Image-to-video, 720p, up to 20s, physics-aware",
      "de" => "Bild-zu-Video, 720p, bis 20s, physik-bewusst"
    },
    detailed_description_translations: %{
      "en" =>
        "OpenAI Sora 2 via Fal transforms images into dynamic videos with physics simulation. Produces 4-20 second videos at 720p.",
      "de" =>
        "OpenAI Sora 2 über Fal transformiert Bilder in dynamische Videos mit Physiksimulation. Produziert 4-20 Sekunden Videos bei 720p."
    },
    info: "Upload an image and describe the motion. Videos generate in 1-5 minutes.",
    released_at: ~D[2025-11-01],
    options: %{
      "aspect_ratio" => ["auto", "16:9", "9:16"],
      "duration" => ["4", "8", "12", "16", "20"],
      "resolution" => ["auto", "720p"]
    },
    allowed_providers: []
  },
  %{
    name: "Seedance 1.0 Lite (Text)",
    key: "fal:fal-ai/bytedance/seedance/v1/lite/text-to-video",
    provider: "ByteDance",
    api_provider: :fal,
    input_cost: "$0.18/video (720p 5s)",
    output_cost: "$0.18/video (720p 5s)",
    input_cost_value: Decimal.new("0.036"),
    input_cost_unit: :per_second,
    output_cost_value: Decimal.new("0.036"),
    output_cost_unit: :per_second,
    input_modalities: ["text"],
    output_modalities: ["video"],
    supports_tools?: false,
    active?: false,
    short_description: "Fast text-to-video, 2-12s, character control, budget-friendly",
    detailed_description:
      "Seedance 1.0 Lite from ByteDance via Fal is a cost-effective video generation model producing 2-12 second videos up to 1080p. Features character control, diverse styles, and camera movements.",
    short_description_translations: %{
      "en" => "Fast text-to-video, 2-12s, character control, budget-friendly",
      "de" => "Schnelles Text-zu-Video, 2-12s, Charakterkontrolle, günstig"
    },
    detailed_description_translations: %{
      "en" =>
        "Seedance 1.0 Lite from ByteDance via Fal is a cost-effective video generation model producing 2-12 second videos up to 1080p. Features character control, diverse styles, and camera movements.",
      "de" =>
        "Seedance 1.0 Lite von ByteDance über Fal ist ein kosteneffektives Videogenerierungsmodell für 2-12 Sekunden Videos bis 1080p. Mit Charakterkontrolle, verschiedenen Stilen und Kamerabewegungen."
    },
    info: "Videos generate in ~40-50 seconds. Most affordable video model.",
    released_at: ~D[2025-06-01],
    options: %{
      "aspect_ratio" => ["21:9", "16:9", "4:3", "1:1", "3:4", "9:16", "9:21"],
      "duration" => ["2", "3", "4", "5", "6", "8", "10", "12"],
      "resolution" => ["480p", "720p", "1080p"]
    },
    allowed_providers: []
  },
  %{
    name: "Seedance 1.0 Lite (Image)",
    key: "fal:fal-ai/bytedance/seedance/v1/lite/image-to-video",
    provider: "ByteDance",
    api_provider: :fal,
    input_cost: "$0.18/video (720p 5s)",
    output_cost: "$0.18/video (720p 5s)",
    input_cost_value: Decimal.new("0.036"),
    input_cost_unit: :per_second,
    output_cost_value: Decimal.new("0.036"),
    output_cost_unit: :per_second,
    input_modalities: ["text", "image"],
    output_modalities: ["video"],
    supports_tools?: false,
    active?: false,
    short_description: "Image-to-video, 2-12s, cinematic motion, budget-friendly",
    detailed_description:
      "Seedance 1.0 Lite Image-to-Video via Fal transforms images into 2-12 second video clips at up to 1080p. Maintains character consistency with cinematic motion.",
    short_description_translations: %{
      "en" => "Image-to-video, 2-12s, cinematic motion, budget-friendly",
      "de" => "Bild-zu-Video, 2-12s, kinoreife Bewegung, günstig"
    },
    detailed_description_translations: %{
      "en" =>
        "Seedance 1.0 Lite Image-to-Video via Fal transforms images into 2-12 second video clips at up to 1080p. Maintains character consistency with cinematic motion.",
      "de" =>
        "Seedance 1.0 Lite Bild-zu-Video über Fal transformiert Bilder in 2-12 Sekunden Videoclips bis 1080p. Erhält Charakterkonsistenz mit kinoreifer Bewegung."
    },
    info:
      "Upload an image and describe the motion. Generates in ~15 seconds. Most affordable i2v model.",
    released_at: ~D[2025-06-01],
    options: %{
      "aspect_ratio" => ["auto", "21:9", "16:9", "4:3", "1:1", "3:4", "9:16", "9:21"],
      "duration" => ["2", "3", "4", "5", "6", "8", "10", "12"],
      "resolution" => ["480p", "720p", "1080p"]
    },
    allowed_providers: []
  }
]

# Ensure provider rows exist for all api_provider values already in the DB,
# link existing models via model_provider_id, and backfill llm_metadata.
# Idempotent; safe on every seed run.
Magus.Models.Backfill.run()

provider_by_slug =
  Magus.Models.list_providers!(authorize?: false)
  |> Map.new(fn provider -> {provider.slug, provider} end)

# Prepend catalog-managed models so the seed loop processes them first.
# See `Magus.Models.Catalog` for the canonical metadata.
catalog_models =
  Magus.Models.Catalog.all()
  |> Enum.map(&Magus.Models.Catalog.to_db_attrs/1)

models = catalog_models ++ models

for model_attrs <- models do
  # Link to the Provider row matching the key prefix (nil-safe when the
  # provider row doesn't exist yet; Backfill.run/0 below links those later).
  key_prefix = model_attrs.key |> String.split(":", parts: 2) |> List.first()

  model_attrs =
    case provider_by_slug[key_prefix] do
      nil -> model_attrs
      provider -> Map.put(model_attrs, :model_provider_id, provider.id)
    end

  # Check if model already exists by key
  case Magus.Chat.Model
       |> Ash.Query.filter(key == ^model_attrs.key)
       |> Ash.read_one(authorize?: false) do
    {:ok, nil} ->
      # Model doesn't exist, create it
      Magus.Chat.Model
      |> Ash.Changeset.for_create(:create, model_attrs)
      |> Ash.create!(authorize?: false)

      IO.puts("Created model: #{model_attrs.name}")

    {:ok, existing} ->
      # Update existing model with description fields and costs.
      # Fields intentionally NOT updated on existing rows so operator changes
      # in the DB are preserved: active?, settings,
      # input_modalities, output_modalities, supports_reasoning?,
      # supports_tools?, supports_search?.
      update_attrs =
        model_attrs
        |> Map.take([
          :short_description,
          :detailed_description,
          :short_description_translations,
          :detailed_description_translations,
          :info,
          :released_at,
          :input_cost,
          :output_cost,
          :input_cost_value,
          :input_cost_unit,
          :output_cost_value,
          :output_cost_unit,
          :options,
          :allowed_providers,
          :provider,
          :api_provider
        ])
        |> Enum.filter(fn {key, value} ->
          # Always update these fields; others only if nil
          (value != nil or key == :allowed_providers) and
            (key in [
               :short_description,
               :short_description_translations,
               :detailed_description_translations,
               :info,
               :input_cost,
               :output_cost,
               :input_cost_value,
               :input_cost_unit,
               :output_cost_value,
               :output_cost_unit,
               :options,
               :allowed_providers,
               :provider,
               :api_provider
             ] or
               Map.get(existing, key) == nil)
        end)
        |> Map.new()

      if map_size(update_attrs) > 0 do
        existing
        |> Ash.Changeset.for_update(:update, update_attrs)
        |> Ash.update!(authorize?: false)

        IO.puts("Updated model: #{model_attrs.name}")
      else
        IO.puts("Model already exists: #{model_attrs.name}")
      end

    {:error, error} ->
      IO.puts("Error checking model #{model_attrs.name}: #{inspect(error)}")
  end
end

# Second pass: on a fresh database the providers only exist after the model
# rows above were inserted (Backfill derives them from api_provider values),
# so run again to create providers and link any models still unlinked.
Magus.Models.Backfill.run()

# Seed default-model role assignments (single source of truth for the
# default chat/image/video model; replaces the legacy default*? flags).
# Idempotent: skip a role that already has an assignment so operator
# choices in the DB are preserved.
default_role_models = [
  {"chat_default", "openrouter:anthropic/claude-sonnet-4.6"},
  {"image_default", "openrouter:google/gemini-3-pro-image-preview"},
  {"video_t2v", "openrouter:google/veo-3.1-fast"}
]

for {role, model_key} <- default_role_models do
  case Magus.Models.get_role_assignment(role, authorize?: false) do
    {:ok, %Magus.Models.RoleAssignment{}} ->
      IO.puts("Role assignment already exists: #{role}")

    _ ->
      case Magus.Chat.Model
           |> Ash.Query.filter(key == ^model_key)
           |> Ash.read_one(authorize?: false) do
        {:ok, %{id: model_id}} ->
          Magus.Models.assign_role(%{role: role, model_id: model_id},
            authorize?: false
          )

          IO.puts("Assigned default role: #{role} -> #{model_key}")

        _ ->
          IO.puts("Skipped #{role}: model #{model_key} not found")
      end
  end
end

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
    sponsorable_seats: nil,
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
    sponsorable_seats: nil,
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
    sponsorable_seats: nil,
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
    sponsorable_seats: nil,
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
    sponsorable_seats: nil,
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
