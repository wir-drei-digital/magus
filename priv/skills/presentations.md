---
name: presentations
description: Create beautiful image-rich PDF presentations with AI-generated visuals and consistent design
tags:
  - documents
  - presentations
  - pdf
  - images
tools:
  - generate_image
  - sandbox_upload_file
  - run_code
  - sandbox_write_file
  - sandbox_read_file
  - sandbox_edit_file
  - sandbox_search
  - sandbox_list_files
  - sandbox_download_file
---

# Presentations

You are helping the user create a beautiful, image-rich PDF presentation. The deck sits between a Keynote-style image-forward pitch deck and a business explainer: visuals carry the energy, but each slide has enough text to stand on its own. You will use `generate_image` for visuals and WeasyPrint (preinstalled in the sandbox) to render the final PDF.

This skill is opinionated about workflow. Follow the four phases in order. The outline approval gate (Phase 2) is mandatory: generating images before the user approves the outline spends budget on the wrong direction.

## Workflow Overview

1. **Discovery** — ask 5 questions to establish audience, intent, length, style, and palette.
2. **Outline + approval gate** — draft a text outline; wait for explicit user approval before any image generation.
3. **Anchor + batch generation** — generate one anchor image, confirm direction, then generate the rest with the anchor as a visual reference.
4. **Render + iterate** — assemble HTML, render to PDF, share preview, iterate.

## Phase 1: Discovery

Ask these 5 questions, one or two at a time. Use menus where possible: they are easier for the user than open-ended prompts.

1. **Audience.** "Who is this for?" (Open question. Get one sentence.)
2. **Intent.** "What's the goal of the deck? Choose one: **inform** (teach or update), **persuade** (build a case for a decision), **pitch** (investor/sales), **teach** (training material)."
3. **Length.** "Roughly how many slides? **5** (lightning), **10** (standard), or **20** (full deck)."
4. **Visual style direction.** "Pick the visual lane: **minimal editorial** (clean typography, sparse imagery), **bold modern** (heavy type, vivid color), **photoreal cinematic** (rich photography, dramatic lighting), **flat illustration** (geometric shapes, friendly), or **hand-drawn** (sketchy, organic)."
5. **Color/mood.** "Pick a palette: **warm muted** (terracotta, cream, sand), **cool tech** (navy, slate, electric blue), **monochrome** (black, white, one accent), **vivid brand** (saturated, high-contrast), or **earthy natural** (moss, clay, ochre)."

### Recommend a model based on the style answer

After Q4, surface a model recommendation using this mapping:

| Visual style direction | Recommended model | Why |
|---|---|---|
| Photoreal cinematic | `openrouter:black-forest-labs/flux.2-pro` | Best photoreal output |
| Bold modern | `openrouter:openai/gpt-5-image` | Strong on dense, graphic compositions |
| Minimal editorial | `openrouter:google/gemini-3-pro-image-preview` | High-fidelity, clean output |
| Flat illustration / hand-drawn | `openrouter:google/gemini-3.1-flash-image-preview` | Fast, strong illustrative defaults |

Tell the user the recommendation and the cost note, then ask: "I'll use **{model}** for image generation. Override?" If they accept, lock in the model. If they want a different one from the list above, use that.

## Phase 2: Outline + Approval Gate

**Do not call `generate_image` in this phase.**

Draft a compact text outline. Show the user a numbered list, one row per slide, in this exact shape:

```
Slide 1 — Title: "<title>"
  Content: <1-2 sentence summary>
  Image brief: <one line describing the visual>
```

End the outline with this question, verbatim:

> "Does this outline look right? I'll only start generating images once you confirm: image generation has a usage cost and I want to make sure the direction is right first."

**Wait for explicit approval ("yes", "go ahead", "approved", or equivalent).** If the user requests changes, revise the outline and ask again. Only after explicit approval do you proceed to Phase 3.

If the user tries to skip ahead ("just make some images," "I trust you, go for it"), refuse politely: "I can't generate images before we agree on the outline — that's how usage spend gets wasted on the wrong direction. Give me a minute for the outline first." Then re-present (or first present) the outline.

## Phase 3: Anchor + Batch Generation

### Generate the anchor first

The anchor image is the visual reference for the entire deck. Generate it before any other image. Use the title slide's image brief, or, if the title slide is text-only, pick the most visually expressive slide.

Build the prompt from this template:

```
{style_direction} illustration, {color_palette} palette, no text in image,
{medium hint}. Subject: {image brief}.
```

Visual consistency comes from the `reference_file_ids` anchor, not from prompt wording. The template intentionally does not say "consistent style" — anchoring does that work.

Where `{medium hint}` is one of: `flat vector`, `photograph`, `oil painting`, `isometric 3D`, `line drawing`. Pick whichever matches the style direction.

Call `generate_image` with:
- `prompt`: the assembled prompt
- `aspect_ratio`: `"16:9"`
- `quality`: `"1K"` (screen viewing; bump only if the deck will be printed at large format)
- `model`: the model_key chosen in Phase 1
- `auto_reference_last_image`: `false` (this is the first image; no reference)

Then **confirm direction with the user**: "Here's the anchor image. Does the visual direction feel right? I'll use it as a style reference for the rest of the deck." If they say no, regenerate. If yes, capture the returned `file_id` (call this `anchor_file_id`) and proceed.

### Generate the remaining images

For each remaining slide that needs an image, call `generate_image` with:
- `prompt`: built from the same template, with the per-slide image brief
- `aspect_ratio`: `"16:9"`
- `quality`: `"1K"` (screen viewing; bump only if the deck will be printed at large format)
- `model`: the chosen model_key
- `reference_file_ids`: `[anchor_file_id]`. This locks the visual identity.
- `auto_reference_last_image`: `false`. Explicit anchor wins; don't drift.

Capture each returned `file_id`.

### When the anchor needs to change

If mid-deck the user wants a different direction, regenerate the anchor **and all dependent images**. Partial re-anchoring (some slides anchored to the new image, some to the old) looks worse than no anchoring at all.

## Phase 4: Render + Iterate

### Upload images to the sandbox

For each generated image, call `sandbox_upload_file` with the `file_id` and a path like `/workspace/img/slide-01.png`. Walk through the deck in order so filenames match slide numbers.

### Write and run the render script

Use `sandbox_write_file` to create `/workspace/render.py`:

```python
import weasyprint

# Slide dimensions: 16:9 widescreen
# 10in × 5.625in = 254mm × 143mm

html = """
<!DOCTYPE html>
<html>
<head>
<style>
  @page {
    size: 10in 5.625in;
    margin: 0;
  }
  *, *::before, *::after { box-sizing: border-box; }
  body {
    margin: 0;
    font-family: 'Helvetica', 'Arial', sans-serif;
    color: #1a1a1a;
  }
  .slide {
    width: 10in;
    height: 5.625in;
    page-break-after: always;
    position: relative;
    overflow: hidden;
    background: #fff;
  }
  .slide:last-child { page-break-after: auto; }

  /* TEMPLATE: Title slide */
  .title-slide {
    display: flex;
    flex-direction: column;
    justify-content: center;
    padding: 0.75in;
  }
  .title-slide .display {
    font-size: 96pt;
    font-weight: 700;
    line-height: 1.05;
    letter-spacing: -0.02em;
    margin: 0;
  }
  .title-slide .subtitle {
    font-size: 24pt;
    color: #555;
    margin-top: 0.4in;
  }

  /* TEMPLATE: Content + image, image on right */
  .content-image-right {
    display: grid;
    grid-template-columns: 1fr 1fr;
  }
  .content-image-right .content {
    padding: 0.75in;
    display: flex;
    flex-direction: column;
    justify-content: center;
  }
  .content-image-right .image {
    background-size: cover;
    background-position: center;
  }
  .content-image-right h2 {
    font-size: 48pt;
    line-height: 1.1;
    margin: 0 0 0.3in 0;
    letter-spacing: -0.01em;
  }
  .content-image-right p {
    font-size: 20pt;
    line-height: 1.4;
    color: #333;
    margin: 0;
  }

  /* TEMPLATE: Full-bleed hero with overlay */
  .hero-slide {
    background-size: cover;
    background-position: center;
    color: #fff;
    display: flex;
    align-items: flex-end;
  }
  .hero-slide .overlay {
    width: 100%;
    padding: 0.75in;
    background: linear-gradient(transparent, rgba(0,0,0,0.7));
  }
  .hero-slide h2 {
    font-size: 64pt;
    line-height: 1.1;
    margin: 0;
    letter-spacing: -0.01em;
  }
</style>
</head>
<body>

  <section class="slide title-slide">
    <h1 class="display">Deck title here</h1>
    <p class="subtitle">Subtitle or context</p>
  </section>

  <section class="slide content-image-right">
    <div class="content">
      <h2>Slide headline</h2>
      <p>Supporting prose, 1-2 sentences.</p>
    </div>
    <div class="image" style="background-image: url('img/slide-02.png');"></div>
  </section>

  <section class="slide hero-slide" style="background-image: url('img/slide-03.png');">
    <div class="overlay">
      <h2>Closing thought or call to action</h2>
    </div>
  </section>

</body>
</html>
"""

weasyprint.HTML(string=html, base_url="/workspace/").write_pdf("/workspace/presentation.pdf")
print("Rendered /workspace/presentation.pdf")
```

Render with `exec_command` using the command `python /workspace/render.py`. (Do not use `run_code` for this step — `run_code` only accepts inline Python source, not a file path. The file-based approach is preferred because it lets you iterate with `sandbox_edit_file` instead of regenerating the whole script.)

### Share the preview

**Call `sandbox_download_file` for `/workspace/presentation.pdf` *before* mentioning the file in your reply.** It returns a download URL that the user can preview as a PDF inline. Include the URL as a markdown link.

### Iterate

For text changes, use `sandbox_edit_file` on `/workspace/render.py`. **Never rewrite the entire script to change one slide.**

For image swaps, call `generate_image` again with the same anchor reference, upload the new file over the old path, and re-run.

## Hybrid Templates: 3 Core + Principles

The three templates above (`title-slide`, `content-image-right`, `hero-slide`) cover most needs. Compose richer slides from them using the principles below.

### Variants you can build

- **Content + image on left**: copy `.content-image-right` to `.content-image-left`, swap the `grid-template-columns` and reorder the child divs.
- **Section divider**: a `.title-slide` with no subtitle and a small section number above the display headline.
- **Quote slide**: a `.hero-slide` with a large pull-quote in the overlay (use the slide background as a flat color block if the quote should breathe; use an image if the speaker is the subject).
- **Stat highlight**: `.content-image-right` where the "image" column is replaced by a giant number block (font-size: 200pt, centered).
- **Two-column text**: two equal columns inside a `.slide` with `.content` padding, useful for compare/contrast.

### Design principles

- **Safe area:** keep all content at least 0.4in from the slide edge. PDF viewers and projectors crop differently; don't put critical text in the bleed.
- **Type scale:** body ≥28pt, headlines 48-72pt, display 96-120pt. Smaller and the slide reads as a document.
- **Max two font families.** Sans-serif throughout is fine for modern decks.
- **Restricted palette:** one accent + two neutrals. Pull from the user's color/mood answer.
- **HTML carries all text. Never** let the image generator render headline copy: even GPT-5 Image is unreliable for typography on slides. The image gen is for backgrounds, illustrations, and subjects only.
- **Image-text contrast:** when overlaying text on photos, always add a scrim (`linear-gradient(transparent, rgba(0,0,0,0.7))`) or a translucent panel. Pure overlay on a busy image is unreadable.
- **One idea per slide.** If a slide needs more than one headline-and-paragraph block, split it into two slides.

## Pitfalls

- **No animation or video.** WeasyPrint renders static PDFs. If the user wants animation, the right answer is "PDFs can't, but I can sequence still frames."
- **1K image quality is enough** for screen viewing. Bumping to 4K bloats the PDF without visible gain unless the deck will be printed at A1 or larger.
- **Generate the anchor first.** Spending anchor-level budget and then realizing the style is wrong is the most expensive failure mode.
- **Don't re-anchor mid-deck** unless you're regenerating all dependent images. Half-anchored decks look worse than non-anchored ones.
- **Font fallbacks always.** Use `font-family: 'Helvetica', 'Arial', sans-serif`. Avoid declaring a single font that may not be present in the sandbox.
- **Outline first, no exceptions.** The Phase 2 approval gate is non-negotiable. Repeat: do not call `generate_image` until the user has approved the outline.
- **`generate_image` error shape:** when the result has an `error` field, treat it as a failure even though the wrapping tuple is `{:ok, ...}`. Surface the error to the user before generating more.

## Tool Sequence Quick Reference

| Phase | Tools used |
|---|---|
| 1. Discovery | None (text only) |
| 2. Outline | None (text only) |
| 3. Anchor + batch | `generate_image` (anchor first, then with `reference_file_ids: [anchor_file_id]`) |
| 4. Render | `sandbox_upload_file` (each image), `sandbox_write_file` (render.py), `run_code`, `sandbox_download_file` |
| Iterate | `sandbox_read_file`, `sandbox_edit_file`, `generate_image` (with anchor), `run_code`, `sandbox_download_file` |
