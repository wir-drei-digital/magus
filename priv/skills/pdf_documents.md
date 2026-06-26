---
name: pdf_documents
description: Create beautiful PDF documents using Python and WeasyPrint (HTML + CSS) with professional typography
tags:
  - documents
  - pdf
  - python
tools:
  - run_code
  - install_packages
  - sandbox_write_file
  - sandbox_read_file
  - sandbox_edit_file
  - sandbox_search
  - sandbox_list_files
  - sandbox_download_file
---

# PDF Document Creation

You are helping the user create beautiful, professionally typeset PDF documents using Python's `weasyprint` library. WeasyPrint renders HTML and CSS to PDF, giving you full control over layout and typography.

## Preinstalled

`weasyprint` is preinstalled. No need to call `install_packages`.

## Tool Sequence

**Creating a new PDF:**
1. `run_code` -- Write and run Python code that generates the `.pdf` file in `/workspace/`
2. `sandbox_download_file` -- **Call this BEFORE mentioning the file in your response.** It returns a download URL you can then include as a link.

**Iterating on an existing script:**
1. `sandbox_read_file` -- Read the Python script with line numbers
2. `sandbox_edit_file` -- Make targeted edits (fix styling, add sections, etc.)
3. `run_code` or `exec_command` -- Re-run to regenerate the PDF
4. `sandbox_download_file` -- Download first, then include the link in your response

**Never rewrite an entire script to change a few lines.** Use `sandbox_edit_file` for targeted modifications.

## Quick Start

```python
import weasyprint

html = """
<!DOCTYPE html>
<html>
<head>
<style>
  @page {
    size: A4;
    margin: 2.5cm;
  }
  body {
    font-family: Georgia, 'Times New Roman', serif;
    font-size: 11pt;
    line-height: 1.5;
    color: #1a1a1a;
  }
  h1 {
    font-size: 24pt;
    font-weight: 700;
    letter-spacing: -0.02em;
    margin-bottom: 0.3em;
    color: #111;
  }
  p {
    margin-bottom: 0.8em;
    text-align: justify;
    hyphens: auto;
  }
</style>
</head>
<body>
  <h1>Document Title</h1>
  <p>Body text goes here.</p>
</body>
</html>
"""

weasyprint.HTML(string=html).write_pdf("/workspace/output.pdf")
```

## Typography Principles

Great PDF documents are distinguished by deliberate typographic choices. Apply these principles consistently.

### Font Selection

Use serif fonts for body text (better readability in print) and sans-serif for headings or UI-like documents:

```css
/* Classic editorial style */
body { font-family: Georgia, 'Times New Roman', serif; }
h1, h2, h3 { font-family: Helvetica, Arial, sans-serif; }

/* Modern corporate style */
body { font-family: Helvetica, Arial, sans-serif; }
h1, h2, h3 { font-family: Helvetica, Arial, sans-serif; font-weight: 300; }

/* Traditional document style */
body { font-family: 'Times New Roman', Times, serif; }
h1, h2, h3 { font-family: 'Times New Roman', Times, serif; }
```

### Vertical Rhythm and Spacing

Consistent spacing creates visual order. Base everything on the body line-height:

```css
body {
  font-size: 11pt;
  line-height: 1.5;             /* 16.5pt baseline rhythm */
}
h1 {
  font-size: 24pt;
  line-height: 1.15;
  margin-top: 0;
  margin-bottom: 0.4em;
}
h2 {
  font-size: 16pt;
  line-height: 1.25;
  margin-top: 1.8em;
  margin-bottom: 0.4em;
}
h3 {
  font-size: 12pt;
  line-height: 1.35;
  margin-top: 1.4em;
  margin-bottom: 0.3em;
}
p {
  margin-top: 0;
  margin-bottom: 0.8em;
}
```

### Text Refinement

Small details that separate amateur from professional documents:

```css
body {
  text-align: justify;          /* Justified body text */
  hyphens: auto;                /* Hyphenation prevents rivers in justified text */
  font-variant-numeric: oldstyle-nums;  /* Elegant numerals in body text */
}
h1, h2, h3 {
  text-align: left;             /* Headings are always left-aligned */
  letter-spacing: -0.01em;      /* Slight tightening for large text */
}
blockquote {
  font-style: italic;
  border-left: 2pt solid #ccc;
  margin-left: 0;
  padding-left: 1em;
  color: #444;
}
small, .caption {
  font-size: 9pt;
  color: #666;
  letter-spacing: 0.02em;
}
```

### Color Palette

Restrained color conveys professionalism. Limit yourself to 2-3 colors:

```css
:root {
  --text: #1a1a1a;             /* Near-black, softer than pure black */
  --text-light: #555;          /* Secondary text */
  --accent: #2c3e50;           /* Headings, rules, key elements */
  --accent-light: #ecf0f1;    /* Backgrounds, table stripes */
  --rule: #bdc3c7;             /* Horizontal rules, borders */
}
```

## Page Setup

### @page Rule

```css
@page {
  size: A4;                     /* or 'letter' for US */
  margin: 2.5cm 2.5cm 3cm 2.5cm;  /* top, right, bottom, left */

  @top-right {
    content: "Company Name";
    font-size: 8pt;
    color: #999;
  }
  @bottom-center {
    content: "Page " counter(page) " of " counter(pages);
    font-size: 8pt;
    color: #999;
  }
}

/* Different first page (no header) */
@page :first {
  @top-right { content: none; }
  margin-top: 4cm;
}
```

### Page Breaks

```css
h1, h2, h3 {
  page-break-after: avoid;      /* Don't leave headings orphaned */
}
table, figure {
  page-break-inside: avoid;     /* Keep tables and figures together */
}
.page-break {
  page-break-before: always;    /* Force a new page */
}
```

## Tables

```css
table {
  width: 100%;
  border-collapse: collapse;
  font-size: 10pt;
  margin: 1.2em 0;
}
thead th {
  background: #2c3e50;
  color: white;
  font-weight: 600;
  text-align: left;
  padding: 8pt 10pt;
  font-size: 9pt;
  text-transform: uppercase;
  letter-spacing: 0.05em;
}
tbody td {
  padding: 7pt 10pt;
  border-bottom: 0.5pt solid #ddd;
}
tbody tr:nth-child(even) {
  background: #f8f9fa;
}
/* Right-align numeric columns */
td.number, th.number {
  text-align: right;
  font-variant-numeric: tabular-nums;
}
```

## Images

```python
import base64
from pathlib import Path

def embed_image(path, width="100%"):
    """Embed an image as a base64 data URI for use in HTML."""
    data = Path(path).read_bytes()
    b64 = base64.b64encode(data).decode()
    ext = Path(path).suffix.lstrip(".")
    mime = {"jpg": "jpeg", "jpeg": "jpeg", "png": "png", "svg": "svg+xml"}.get(ext, ext)
    return f'<img src="data:image/{mime};base64,{b64}" style="width: {width};" />'

# Usage in HTML
logo_tag = embed_image("/workspace/logo.png", width="4cm")
html = f"""
<header>{logo_tag}</header>
<h1>Report Title</h1>
"""
```

Or reference files directly (WeasyPrint resolves local paths):

```python
# Use base_url so relative paths resolve correctly
weasyprint.HTML(string=html, base_url="/workspace/").write_pdf("/workspace/output.pdf")
```

```html
<img src="logo.png" style="width: 4cm;" />
```

## Headers and Footers

CSS `@page` margin boxes are the proper way to add running headers and footers:

```css
@page {
  size: A4;
  margin: 2.5cm 2.5cm 3cm 2.5cm;

  @top-left {
    content: "Confidential";
    font-size: 8pt;
    color: #999;
    font-family: Helvetica, sans-serif;
  }
  @top-right {
    content: string(doc-title);
    font-size: 8pt;
    color: #999;
    font-style: italic;
  }
  @bottom-center {
    content: counter(page);
    font-size: 9pt;
    color: #666;
  }
  @bottom-right {
    content: "Page " counter(page) " of " counter(pages);
    font-size: 8pt;
    color: #999;
  }
}

/* Pull the document title into the running header */
h1 { string-set: doc-title content(); }

/* Suppress header/footer on the first page */
@page :first {
  @top-left { content: none; }
  @top-right { content: none; }
}
```

## Multi-Column Layout

```css
.two-column {
  column-count: 2;
  column-gap: 1.5cm;
  column-rule: 0.5pt solid #ddd;
}
```

## Common Document Types

### Invoice

```
Layout:
  1. Company logo (top-left) + company address (top-right)
  2. Large "INVOICE" heading with invoice number and date
  3. Bill-to / Ship-to in a two-column grid
  4. Line items table: description, qty, unit price, total
  5. Summary rows: subtotal, tax, grand total (right-aligned, bold)
  6. Payment terms and notes at the bottom

Style notes:
  - Use sans-serif throughout for a clean, business look
  - Grand total row: larger font, dark background, white text
  - Use tabular-nums for all currency and quantity columns
```

### Report

```
Layout:
  1. Title page: centered title, subtitle, author, date
  2. Page break
  3. Table of contents (use anchor links + dotted leaders)
  4. Sections with heading hierarchy (h1 > h2 > h3)
  5. Charts and tables as needed
  6. Running headers and page numbers

Style notes:
  - Serif body text, sans-serif headings
  - Justified text with hyphenation
  - Consistent heading spacing via vertical rhythm
  - Subtle horizontal rules between major sections
```

### Letter

```
Layout:
  1. Sender address block (top-right or letterhead)
  2. Date
  3. Recipient address block
  4. Subject line (bold)
  5. Body paragraphs (Dear..., content, closing)
  6. Signature block

Style notes:
  - Single serif font throughout
  - 12pt body, generous margins (3cm sides)
  - No justification (left-aligned is traditional for letters)
  - 1.6 line-height for readability
```

### Certificate

```
Layout:
  1. Decorative border (CSS border or background image)
  2. Centered: organization name or logo
  3. Large ornamental title ("Certificate of Completion")
  4. Recipient name in a display style
  5. Description paragraph
  6. Date, signature line, and authority name

Style notes:
  - Centered layout, generous whitespace
  - Display font or large serif for the recipient name
  - Muted gold/navy color scheme
  - Consider a subtle background pattern or watermark
```

## Available Fonts

WeasyPrint uses system fonts. The sandbox has these available:

- **Serif:** Georgia, 'Times New Roman', Times, serif
- **Sans-serif:** Helvetica, Arial, sans-serif
- **Monospace:** Courier, 'Courier New', monospace

For custom fonts, use `@font-face` with a URL or embedded base64:

```css
@font-face {
  font-family: 'CustomFont';
  src: url('/workspace/fonts/custom.ttf');
}
```

## Best Practices

- Always save to `/workspace/` so the file can be downloaded
- Build the HTML as a Python string or use a template; pass it to `weasyprint.HTML(string=html).write_pdf(path)`
- Set `base_url="/workspace/"` when referencing local images or fonts by relative path
- Use `@page` rules for page size, margins, headers, and footers
- Keep body text at 10-11pt, headings at 14-24pt, captions at 8-9pt
- Use `text-align: justify` with `hyphens: auto` for body text
- Use `font-variant-numeric: tabular-nums` for columns of numbers
- Apply `page-break-inside: avoid` to tables and figures
- Limit your color palette: one accent color, near-black text, one or two grays
- Test with longer content to verify page breaks and running headers work correctly
