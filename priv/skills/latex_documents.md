---
name: latex_documents
description: Create professional LaTeX documents including reports, papers, letters, and presentations
tags:
  - documents
  - typesetting
  - academic
tools:
  - exec_command
  - sandbox_write_file
  - sandbox_read_file
  - sandbox_edit_file
  - sandbox_search
  - sandbox_list_files
  - sandbox_download_file
---

# LaTeX Document Creation

You are helping the user create professional LaTeX documents. Follow these guidelines carefully.

## Preinstalled

Everything is preinstalled — no additional setup needed:

- **LaTeX**: texlive-latex-base, texlive-latex-recommended, texlive-fonts-recommended, texlive-latex-extra
- **Bibliography**: texlive-bibtex-extra, biber
- **Commands**: `pdflatex`, `bibtex`, `biber`

## Workflow

**Creating a new document:**
1. `sandbox_write_file` — Write the `.tex` file to `/workspace/`
2. `exec_command` — Compile: `pdflatex -interaction=nonstopmode document.tex`
3. Check for errors — if compilation fails, read the `.log` file and fix
4. `sandbox_download_file` — **Call this BEFORE mentioning the file in your response.** It returns a download URL you can then include as a link.
5. For bibliographies: `pdflatex -> bibtex -> pdflatex -> pdflatex`

**Iterating on an existing document:**
1. `sandbox_read_file` — Read the `.tex` file with line numbers
2. `sandbox_edit_file` — Make targeted edits (fix formatting, add sections, etc.)
3. `exec_command` — Recompile with `pdflatex`
4. If errors, `sandbox_read_file` the `.log` file, then `sandbox_edit_file` to fix

**Never rewrite an entire .tex file to change a few lines.** Use `sandbox_edit_file` for targeted modifications.

## Document Structure

```latex
\documentclass[12pt,a4paper]{article}
\usepackage[utf8]{inputenc}
\usepackage[T1]{fontenc}
\usepackage{geometry}
\geometry{margin=2.5cm}

\title{Document Title}
\author{Author Name}
\date{\today}

\begin{document}
\maketitle

\section{Introduction}
Your content here.

\end{document}
```

## Best Practices

- Always use `\usepackage[utf8]{inputenc}` for Unicode support
- Use `-interaction=nonstopmode` to prevent pdflatex from hanging on errors
- Read the .log file to diagnose compilation issues
- For complex documents, compile twice to resolve cross-references
- Use `\tableofcontents` after `\maketitle` for longer documents
- Use `booktabs` package for professional tables
- Use `graphicx` for including images
- Use `hyperref` (load last) for clickable links and PDF metadata

## Professional Document Template

Use this as a starting point for any document that needs to look polished. It sets up proper typography, spacing, headers/footers, and color accents:

```latex
\documentclass[11pt,a4paper]{article}
\usepackage[utf8]{inputenc}
\usepackage[T1]{fontenc}

% --- Typography ---
\usepackage{palatino}                       % Palatino serif for body text
\usepackage[scaled=0.88]{helvet}            % Helvetica for sans-serif
\usepackage{microtype}                       % Subtle kerning and protrusion
\usepackage{setspace}
\setstretch{1.15}                            % Slightly open leading

% --- Layout ---
\usepackage{geometry}
\geometry{
  a4paper,
  top=3cm, bottom=3cm,
  left=2.8cm, right=2.8cm,
  headheight=14pt
}
\usepackage{parskip}                         % Space between paragraphs, no indent

% --- Color ---
\usepackage{xcolor}
\definecolor{accent}{HTML}{2C3E50}
\definecolor{lightgray}{HTML}{F2F2F2}
\definecolor{rule}{HTML}{BDC3C7}

% --- Headings ---
\usepackage{titlesec}
\titleformat{\section}
  {\Large\sffamily\bfseries\color{accent}}   % Sans-serif, bold, accent color
  {\thesection}{0.7em}{}
  [\vspace{-0.4em}\textcolor{rule}{\rule{\textwidth}{0.4pt}}]  % Rule under heading
\titleformat{\subsection}
  {\large\sffamily\bfseries\color{accent!80!black}}
  {\thesubsection}{0.6em}{}
\titleformat{\subsubsection}
  {\normalsize\sffamily\bfseries\color{accent!60!black}}
  {\thesubsubsection}{0.5em}{}
\titlespacing*{\section}{0pt}{1.8em}{0.6em}
\titlespacing*{\subsection}{0pt}{1.4em}{0.4em}
\titlespacing*{\subsubsection}{0pt}{1em}{0.3em}

% --- Headers and Footers ---
\usepackage{fancyhdr}
\pagestyle{fancy}
\fancyhf{}
\renewcommand{\headrulewidth}{0.4pt}
\renewcommand{\headrule}{\hbox to\headwidth{\color{rule}\leaders\hrule height \headrulewidth\hfill}}
\fancyhead[L]{\small\sffamily\color{gray} Document Title}
\fancyhead[R]{\small\sffamily\color{gray} Confidential}
\fancyfoot[C]{\small\sffamily\color{gray} \thepage}

% First page: no header
\fancypagestyle{plain}{
  \fancyhf{}
  \renewcommand{\headrulewidth}{0pt}
  \fancyfoot[C]{\small\sffamily\color{gray} \thepage}
}

% --- Tables ---
\usepackage{booktabs}
\usepackage{tabularx}
\renewcommand{\arraystretch}{1.3}            % More vertical padding in tables

% --- Lists ---
\usepackage{enumitem}
\setlist{nosep, leftmargin=1.5em}
\setlist[itemize]{label=\textcolor{accent}{\textbullet}}

% --- Figures ---
\usepackage{graphicx}
\usepackage{caption}
\captionsetup{
  font=small,
  labelfont={bf,sf,color=accent},
  textfont=it,
  margin=1cm
}

% --- Links (load last) ---
\usepackage[colorlinks=true, linkcolor=accent, urlcolor=accent!70!blue, citecolor=accent]{hyperref}

% =============================================================
\title{%
  \vspace{-1cm}
  {\sffamily\Huge\bfseries\color{accent} Document Title}\\[0.3em]
  {\sffamily\large\color{gray} Subtitle or short description}
}
\author{%
  {\sffamily Author Name}\\
  {\small\sffamily\color{gray} Organization}
}
\date{{\sffamily\color{gray} \today}}

\begin{document}
\maketitle
\thispagestyle{plain}

\begin{abstract}
\noindent
A brief summary of the document. This template uses Palatino for body text, Helvetica for headings, and microtype for refined spacing. The result is a document that looks polished and intentional without relying on exotic fonts.
\end{abstract}

\tableofcontents
\newpage

\section{Introduction}

Body text is set in Palatino at 11pt with 1.15 line spacing. Paragraphs are separated by vertical space rather than indentation, which gives the document a modern, clean feel. The \texttt{microtype} package adds subtle character protrusion and kerning adjustments.

\subsection{Key Features}

\begin{itemize}
  \item Serif body with sans-serif headings for clear hierarchy
  \item Accent color used sparingly: headings, list bullets, links
  \item Horizontal rules under section headings for visual structure
  \item Professional table styling with \texttt{booktabs}
\end{itemize}

\section{Data Overview}

\begin{table}[htbp]
  \centering
  \caption{Quarterly Results}
  \begin{tabularx}{0.85\textwidth}{Xrrr}
    \toprule
    \textbf{Region} & \textbf{Q1} & \textbf{Q2} & \textbf{Q3} \\
    \midrule
    North America & 142,500 & 158,300 & 163,100 \\
    Europe        &  98,700 & 104,200 & 112,800 \\
    Asia Pacific  &  67,300 &  72,100 &  78,500 \\
    \midrule
    \textbf{Total} & \textbf{308,500} & \textbf{334,600} & \textbf{354,400} \\
    \bottomrule
  \end{tabularx}
\end{table}

\section{Conclusion}

Replace this content with your own. The template handles typography, spacing, and structure so you can focus on the writing.

\end{document}
```

### What makes it professional

- **Font pairing:** Palatino body + Helvetica headings. Readable, distinctive, avoids the "default LaTeX" look.
- **microtype:** Enables character protrusion and font expansion for optically even margins.
- **titlesec:** Custom heading styles with accent color and a thin rule under `\section` headings.
- **parskip:** Paragraph spacing instead of indentation for a modern feel.
- **booktabs:** `\toprule`, `\midrule`, `\bottomrule` instead of `\hline` for elegant tables.
- **Restrained color:** One accent color (`#2C3E50`) used consistently across headings, links, bullets, and captions.
- **fancyhdr:** Clean running headers/footers in sans-serif, muted gray.
- **Caption styling:** Small, italic text with bold sans-serif label in accent color.

## Common Document Types

### Academic Paper
```latex
\documentclass[12pt]{article}
\usepackage[T1]{fontenc}
\usepackage{palatino}
\usepackage{microtype}
\usepackage{amsmath,amssymb,amsthm}
\usepackage{booktabs}
\usepackage{graphicx}
\usepackage[colorlinks=true]{hyperref}
```

### Letter
```latex
\documentclass{letter}
\usepackage[T1]{fontenc}
\usepackage{palatino}
\usepackage{geometry}
\geometry{margin=3cm}
\signature{Your Name}
\address{Your Address}
\begin{document}
\begin{letter}{Recipient Address}
\opening{Dear Sir or Madam,}
Body text.
\closing{Sincerely,}
\end{letter}
\end{document}
```

### Beamer Presentation
```latex
\documentclass{beamer}
\usetheme{Madrid}
\usepackage[T1]{fontenc}
\begin{document}
\begin{frame}{Title}
Content
\end{frame}
\end{document}
```
