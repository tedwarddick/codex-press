# Codex Press

Codex Press is an Obsidian + Pandoc publishing pipeline for compiling structured fiction projects into manuscript Markdown, EPUB, PDF, and DOCX.

It is designed for long-form fiction projects built from folder notes and chapter files.

## What it supports

- Trilogy and standalone book projects
- Folder Notes for trilogy, book, and part metadata
- Chapter-level YAML frontmatter
- Obsidian callouts converted for export
- `chat` code blocks converted for EPUB/PDF styling
- Local image embeds
- Mermaid diagrams, when Mermaid CLI is installed
- KDP-friendly PDF/DOCX export
- EPUB export through Pandoc

## Quick start

1. Open this repository as an Obsidian vault.
2. Enable Community Plugins when prompted.
3. Install or enable **Templater**.
4. Open `Codex Press/Run Codex Press.md`.
5. Run **Templater: Open Insert Template modal**.
6. Select either:

```text
Codex Press/Compile to EPUB
Codex Press/Compile to PDF
```

The runnable compiler templates live in:

```text
Templates/Codex Press/
```

The reference/source copies also live in:

```text
Scripts/
```

## Dependencies

Pandoc is required for EPUB, PDF, and DOCX export. XeLaTeX is required for PDF export.

On Debian/Ubuntu/Zorin, run:

```bash
Codex Press/bin/install-codex-press-deps.sh
```

## Project structure

A trilogy project uses this pattern:

```text
Trilogy Example.md
Trilogy Example/
  Book 1.md
  Book 1/
    Part 1.md
    Part 1/
      Chapter 1.md
  Shared/
    Acknowledgements.md
    Biography.md
```

A standalone book can use the same `Book.md / Book/Part/Chapter` pattern and set the root folder note to `type: book`.

## YAML examples

A trilogy folder note needs:

```yaml
---
type: trilogy
title: Example Trilogy
subtitle: Example subtitle
author: Your Name
version: 1.0
copyright: © Your Name
publisher: Your Publisher
imprint: Your Imprint
---
```

A book folder note needs:

```yaml
---
type: book
book: 1
title: Book Title
subtitle: Book subtitle
author: Your Name
series: Example Trilogy
series_book: Book One
version: 1.0
isbn_epub:
isbn_paper:
isbn_hard:
---
```

A part folder note needs:

```yaml
---
type: part
book: 1
part: 1
chapter: 1.1.0
title: PART TITLE
story_day: 0
story_date: 2000-01-01
---
```

A chapter file needs:

```yaml
---
type: chapter
book: 1
chapter: 1.1.1
title: First Chapter
story_day: 0
story_date: 2000-01-01
location: Somewhere
pov: Character Name
---
```

## EPUB troubleshooting

The EPUB compiler writes intermediate files before running Pandoc:

```text
Manuscripts/.<title> - <date> (epub).epub-export.md
Manuscripts/.<title> - <date> (epub).epub.css
```

If these files appear but the `.epub` does not, the Markdown assembly succeeded and the Pandoc EPUB step failed. In Obsidian, open **Developer Tools → Console** and look for `Pandoc EPUB export failed`.

The refactored EPUB compiler calls Pandoc with argument arrays rather than one long shell string, which is safer for paths with spaces, metadata with punctuation, and cover/image paths.

## Repository hygiene

Generated manuscripts, EPUBs, PDFs, DOCX files, temporary export files, Mermaid render cache files, and Obsidian plugin binaries are ignored by `.gitignore`.
