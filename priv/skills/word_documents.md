---
name: word_documents
description: Create professional Word (.docx) documents including reports, letters, resumes, and proposals
tags:
  - documents
  - office
  - writing
tools:
  - run_code
  - exec_command
  - install_packages
  - sandbox_write_file
  - sandbox_read_file
  - sandbox_edit_file
  - sandbox_search
  - sandbox_list_files
  - sandbox_download_file
---

# Word Document Creation

You are helping the user create professional Word (.docx) documents using the `python-docx` library. Follow these guidelines carefully.

## Preinstalled

`python-docx` is preinstalled — no need to call `install_packages`.

## Tool Sequence

**Creating a new document:**
1. `run_code` — Write and run Python code that generates the `.docx` file in `/workspace/`
2. `sandbox_download_file` — **Call this BEFORE mentioning the file in your response.** It returns a download URL you can then include as a link.

**Iterating on an existing script:**
1. `sandbox_read_file` — Read the Python script with line numbers
2. `sandbox_edit_file` — Make targeted edits (fix formatting, add sections, etc.)
3. `run_code` or `exec_command` — Re-run to regenerate the document
4. `sandbox_download_file` — Download first, then include the link in your response

**Never rewrite an entire script to change a few lines.** Use `sandbox_edit_file` for targeted modifications.

## Document Basics

```python
from docx import Document
from docx.shared import Inches, Pt, Cm, RGBColor
from docx.enum.text import WD_ALIGN_PARAGRAPH
from docx.enum.table import WD_TABLE_ALIGNMENT

document = Document()

# Title (Heading level 0)
document.add_heading("Document Title", level=0)

# Headings
document.add_heading("Section Heading", level=1)
document.add_heading("Subsection", level=2)

# Paragraphs
document.add_paragraph("A simple paragraph.")

# Rich text with runs
p = document.add_paragraph()
p.add_run("Bold text").bold = True
p.add_run(" and ")
p.add_run("italic text").italic = True

# Lists
document.add_paragraph("Bullet item", style="List Bullet")
document.add_paragraph("Numbered item", style="List Number")

# Page break
document.add_page_break()

document.save("/workspace/output.docx")
```

## Tables

```python
# Create a table with header row
table = document.add_table(rows=1, cols=3, style="Table Grid")
hdr = table.rows[0].cells
hdr[0].text = "Name"
hdr[1].text = "Role"
hdr[2].text = "Email"

# Add data rows
data = [("Alice", "Engineer", "alice@example.com"),
        ("Bob", "Designer", "bob@example.com")]
for name, role, email in data:
    row = table.add_row().cells
    row[0].text = name
    row[1].text = role
    row[2].text = email
```

## Formatting

```python
from docx.shared import Pt, RGBColor
from docx.enum.text import WD_ALIGN_PARAGRAPH

# Paragraph alignment
p = document.add_paragraph("Centered text")
p.alignment = WD_ALIGN_PARAGRAPH.CENTER

# Font formatting via runs
run = p.add_run("Styled text")
run.font.size = Pt(14)
run.font.color.rgb = RGBColor(0x42, 0x24, 0xE9)
run.font.name = "Arial"
run.bold = True

# Paragraph spacing
p.paragraph_format.space_before = Pt(12)
p.paragraph_format.space_after = Pt(6)
p.paragraph_format.line_spacing = Pt(18)
```

## Images

```python
from docx.shared import Inches

# Add image with width constraint (height scales proportionally)
document.add_picture("/workspace/image.png", width=Inches(4.0))
```

## Page Setup

```python
from docx.shared import Cm

section = document.sections[0]
section.page_width = Cm(21.0)   # A4 width
section.page_height = Cm(29.7)  # A4 height
section.top_margin = Cm(2.5)
section.bottom_margin = Cm(2.5)
section.left_margin = Cm(2.5)
section.right_margin = Cm(2.5)
```

## Headers and Footers

```python
section = document.sections[0]

# Header
header = section.header
header.is_linked_to_previous = False
p = header.paragraphs[0]
p.text = "Company Name"
p.alignment = WD_ALIGN_PARAGRAPH.CENTER

# Footer
footer = section.footer
footer.is_linked_to_previous = False
p = footer.paragraphs[0]
p.text = "Page "
p.alignment = WD_ALIGN_PARAGRAPH.CENTER
```

## Available Paragraph Styles

These built-in styles are available without any template setup:

- `Normal`, `Title`, `Subtitle`
- `Heading 1` through `Heading 9`
- `List Bullet`, `List Bullet 2`, `List Bullet 3`
- `List Number`, `List Number 2`, `List Number 3`
- `Quote`, `Intense Quote`
- `No Spacing`

## Best Practices

- Always save to `/workspace/` so the file can be downloaded
- Use `Pt()` for font sizes, `Inches()` or `Cm()` for dimensions
- Set `style="Table Grid"` on tables for visible borders
- For complex layouts, build the document top-to-bottom — python-docx appends elements sequentially
- When inserting images, always set a `width` to prevent oversized images
