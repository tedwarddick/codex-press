# Troubleshooting EPUB export

If the EPUB compiler creates Markdown but no `.epub`, the content assembly stage has worked and the Pandoc export stage has failed.

## Check the Obsidian console

Open **Developer Tools → Console** and look for:

```text
Pandoc EPUB export failed
```

The compiler logs the full Pandoc command and the stderr output.

## Common causes

### Pandoc is not available to Obsidian

PDF export working usually proves Pandoc is available, but if only the EPUB compiler fails, still check the console for an `ENOENT` error.

### Bad cover image path

Temporarily remove `cover`, `cover_image`, or `epub_cover` from the project YAML and run again.

### Unresolved local images

The compiler warns about missing image embeds in the console. Missing images should not normally stop EPUB generation, but malformed image syntax can.

### Pandoc syntax error in generated Markdown

Open the hidden export Markdown in `Manuscripts/` and search around the line number reported by Pandoc.

## Manual test

From the vault root, run a simplified command against the hidden export file:

```bash
pandoc --from=markdown+fenced_divs+link_attributes-yaml_metadata_block \
  "Manuscripts/.Book 1 - 2026-06-25 (epub).epub-export.md" \
  -o /tmp/codex-test.epub \
  --standalone \
  --epub-title-page=false \
  --toc-depth=2 \
  --split-level=2
```
