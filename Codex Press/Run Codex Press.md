# Run Codex Press

Use this note as a launch pad.

## Compile

1. Open the Command Palette.
2. Run **Templater: Open Insert Template modal**.
3. Select one of:

```text
Codex Press/Compile to EPUB
Codex Press/Compile to PDF
```

The compiler will ask whether you want to compile a **Trilogy** or **Book**.

For EPUB, choose one of:

- Review Markdown only
- Review Markdown + EPUB
- EPUB only

For PDF/DOCX, choose Draft/Publish and the export format.

## First-time setup

Obsidian may ask you to enable or trust Community Plugins. Enable them, then run again.

Pandoc must be available to Obsidian. On Linux, run:

```bash
Codex Press/bin/install-codex-press-deps.sh
```

## EPUB troubleshooting

If Markdown appears in `Manuscripts/` but no EPUB appears, open **Developer Tools → Console** in Obsidian and look for `Pandoc EPUB export failed`. The compiler writes the temporary EPUB Markdown first, then calls Pandoc.
