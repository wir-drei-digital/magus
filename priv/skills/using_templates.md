---
name: using_templates
description: Render a new document from an existing workspace template by reading it, drafting content for the variable parts, and using the sandbox to produce the output file.
tags:
  - documents
  - automation
---

# Using Templates

When the user wants a new document, deck, sheet, flyer, or designed PDF that follows the structure of an existing template, follow this workflow. Templates are regular workspace files marked `is_template: true`. Supported formats: `.docx`, `.pptx`, `.xlsx`, `.pdf`, and images (`.png`, `.jpg`, `.svg`). Different formats need different approaches; see the format-specific sections below.

## 1. Find the right template

If the user named a template, use `file_search` (or `file_list` with a templates-only filter) to locate it. If the user described the kind of doc, propose the matching templates and let the user confirm.

If no suitable template exists, fall back to drafting from scratch. Do not invent a template.

## 2. Read the template

Use `file_download` to fetch the file into the sandbox. The right reading approach depends on the format:

### Office formats (text + structure are first-class)

- **`.docx`**: `from docx import Document; doc = Document(path)`. Walk `doc.paragraphs`, `doc.tables`, headers, footers.
- **`.pptx`**: `from pptx import Presentation; prs = Presentation(path)`. Walk `prs.slides[*].shapes[*].text_frame`.
- **`.xlsx`**: `import openpyxl; wb = openpyxl.load_workbook(path)`. Walk worksheets and named ranges.

### PDFs (visual structure is first-class)

PDFs are typically not directly editable as text-with-runs. There are three strategies, pick the one that fits:

1. **Form-style PDFs** (with AcroForm fields): use `pikepdf` to fill the named form fields directly. Cleanest path when available.
2. **Text-extractable PDFs** (born digital, no flattening): use `pdfplumber` to extract text + bounding boxes. Recreate with `reportlab` using your understanding of the layout. Good for reports, briefs, contracts.
3. **Visually-designed PDFs** (flyers, certificates, branded layouts): render the first 1-2 pages as PNG with `pdf2image`, save the PNGs as Files via `file_upload`, then attach those screenshots in your reply so the user can confirm the visual layout. Use `pdfplumber` to read text. Recreate with `reportlab` (positioned text + images) or by overlaying text onto the original PDF using `PyPDF2`/`pikepdf`. If the model running you supports vision, you can also include the screenshots in your own working memory by uploading and re-attaching them in a follow-up.

For the visual analysis path: `pdf2image.convert_from_path('template.pdf', dpi=150)` returns a list of `PIL.Image` objects. Save each as PNG, inspect dimensions, dominant colors, and text positions. The screenshot is the source of truth for layout when the PDF text alone is not enough.

### Image templates (the visual IS the template)

For `.png`/`.jpg`/`.svg`: the file is the design itself, with placeholders that may be visual (a blank rectangle for a photo) or textual (a heading area, body area). Two strategies:

1. **Overlay**: open the image with `PIL.Image.open(path)`, draw new text/images on top with `PIL.ImageDraw`, save. Best when the image is a backdrop and you only need to add new content.
2. **Recreate**: read the image to understand layout (use `pytesseract` for OCR on existing text, inspect dimensions and colors with PIL), then redraw from scratch with PIL or with a higher-level library (e.g., generate HTML/CSS and render via `weasyprint` for crisp text).

For SVG: parse the XML directly, replace text node contents, save as new SVG. Convert to PNG/PDF if needed via `cairosvg`.

## 3. Identify the variable parts

Read the template content carefully. Variable parts are typically:

- Names (people, companies, products)
- Dates and date ranges
- Currency amounts and quantities
- Subject-specific paragraphs ("In Q3 we shipped X...")
- Lists/tables of items that change every time

Constants (section headings, boilerplate clauses, brand language) should NOT change between renderings.

If the template uses explicit markers (`{{name}}`, `[CLIENT]`, `<<DATE>>`), use them. If not, identify the variable spans by content.

## 4. Ask the user (or use conversation context) for the new values

For each variable part, either pull the value from the conversation context (if the user has already provided it) or ask the user concisely. Group related questions.

## 5. Render the new document in the sandbox

Use the appropriate Python library to produce the output:

```python
# .docx example: preserves formatting because we mutate runs in place
from docx import Document

doc = Document('template.docx')

REPLACEMENTS = {
    '{{client_name}}': 'Acme Corporation',
    '{{quarter}}': 'Q4 2026',
    # …
}

def replace_in_runs(runs):
    for run in runs:
        for find, repl in REPLACEMENTS.items():
            if find in run.text:
                run.text = run.text.replace(find, repl)

for p in doc.paragraphs:
    replace_in_runs(p.runs)

for table in doc.tables:
    for row in table.rows:
        for cell in row.cells:
            for p in cell.paragraphs:
                replace_in_runs(p.runs)

doc.save('output.docx')
```

For `.pptx`, walk shapes and text frames similarly. For `.xlsx`, mutate cells directly. For larger structural changes (adding new bullets, growing a table), use the library's higher-level APIs rather than raw text replacement.

If the template does NOT use explicit markers, do the substitution by exact-string match against the original variable spans you identified in step 3.

## 6. Deliver the output

Upload the rendered file via `file_upload` (so it ends up in the user's Files), then mention it inline so the user can download it.

## Tips

- For Office formats, if a `find_text` doesn't appear in the runs (Word frequently splits text across runs by formatting), fall back to: walk the paragraph text, do the replacement on the joined text, then rebuild the paragraph by clearing and re-adding a single run. The `python-docx` recipe for this is well-documented.
- Always XML-escape values that might contain `<` or `&` if you're manipulating XML directly. python-docx/python-pptx handle escaping correctly when you set `run.text`.
- If the user wants PDF output from a `.docx` source, render the `.docx` first, then convert with `libreoffice --headless --convert-to pdf` inside the sandbox.
- For visually-designed templates (PDFs, images), always show the user a preview of the rendered output before declaring done. They are the judge of visual fidelity.
- If you cannot reproduce the template visually with confidence, say so. Offer to either (a) overlay text onto the original as a less-flexible but visually-identical option, or (b) recreate from scratch with the user accepting some visual drift.

## When to skip this skill

- The user is not working from an existing template.
- The output is freeform text (chat reply, draft, email body); use the Draft tool instead.
- The user asks for a brand-new document with no shared structure.
