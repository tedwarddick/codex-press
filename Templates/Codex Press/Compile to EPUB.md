<%*
/* =========================
   CODEX REVIEW + EPUB COMPILER v1.0.0
   GENERIC PROJECT REVIEW / EPUB COMPILER

   PURPOSE
   - Creates a single Obsidian-native Markdown review document.
   - Optionally creates an EPUB using Pandoc.
   - Keeps Markdown review output close to the original source Markdown.
   - Replaces =this.field metadata placeholders using YAML frontmatter values.
   - Preserves Obsidian callouts, chat blocks, code blocks, tables, wiki links,
     and image embeds in the Review Markdown output.
   - Converts callouts, chat blocks, wiki links, local images, and Mermaid charts into
     Apple Books-friendly Markdown/fenced divs/images for the EPUB export path.
   - Adds EPUB-specific front matter, copyright/rights information,
     generated book list, optional cover image, richer EPUB metadata,
     and a Codex-generated contents page.
   - Writes outputs into the vault-root Manuscripts folder.

   Supports:
   - type: trilogy
   - type: book
========================= */

/* =========================
   USER INPUTS
========================= */

const projectKind = await tp.system.suggester(
  ["Trilogy", "Book"],
  ["trilogy", "book"]
);

const includeContents = await tp.system.suggester(
  ["Include Contents in Review Markdown", "No Contents in Review Markdown"],
  [true, false]
);

const outputMode = await tp.system.suggester(
  ["Review Markdown only", "Review Markdown + EPUB", "EPUB only"],
  ["md", "md_epub", "epub"]
);

const writeReviewMarkdown = outputMode !== "epub";
const writeEpub = outputMode !== "md";

/* =========================
   HELPERS
========================= */

const CODEX_REVIEW_EPUB_VERSION = "1.2.0";
const compileDate = window.moment().format("YYYY-MM-DD");
const compileDateTime = window.moment().format("YYYY-MM-DD HH:mm");

const ROOT_MANUSCRIPTS_FOLDER = "Manuscripts";
const PANDOC_FROM_EPUB = "markdown+fenced_divs+link_attributes-yaml_metadata_block";
const MERMAID_EPUB_IMAGE_FORMAT = "png";
const MERMAID_EPUB_ASSET_FOLDER = `${ROOT_MANUSCRIPTS_FOLDER}/.codex-mermaid-assets`;
const MERMAID_CLI_COMMAND = ""; // Optional override, e.g. "mmdc.cmd" or full path to mmdc.
const MERMAID_PUPPETEER_CONFIG_FILE = "~/.config/mermaid/puppeteer-config.json"; // Optional. Set to "" to disable.

function clean(value, fallback = "") {
  return value && String(value).trim() ? String(value).trim() : fallback;
}

function firstNonEmpty(...values) {
  for (const value of values) {
    const v = clean(value, "");
    if (v) return v;
  }
  return "";
}

function stripWikiLinks(value) {
  return String(value || "")
    .replace(/\[\[([^\]|]+)\|([^\]]+)\]\]/g, "$2")
    .replace(/\[\[([^\]]+)\]\]/g, "$1");
}

function cleanFrontmatterValue(value) {
  return stripWikiLinks(
    String(value || "")
      .trim()
      .replace(/^["']|["']$/g, "")
  );
}

function isFolder(item) {
  return item && item.children !== undefined;
}

function isMarkdown(file) {
  return file && file.extension === "md";
}

function sortItems(items) {
  return items.sort((a, b) =>
    a.name.localeCompare(b.name, undefined, { numeric: true })
  );
}

async function ensureFolder(path) {
  if (!app.vault.getAbstractFileByPath(path)) {
    await app.vault.createFolder(path);
  }
}

async function writeOrReplace(path, content) {
  const existing = app.vault.getAbstractFileByPath(path);

  if (existing) {
    await app.vault.modify(existing, content);
    return;
  }

  if (await app.vault.adapter.exists(path)) {
    await app.vault.adapter.write(path, content);
    return;
  }

  await app.vault.create(path, content);
}

function extractFrontmatter(content) {
  const match = String(content || "").match(/^---\s*\r?\n([\s\S]*?)\r?\n---/);
  if (!match) return {};

  const obj = {};
  const lines = match[1].split(/\r?\n/);

  for (const line of lines) {
    const m = line.match(/^([^:#]+):\s*(.*)$/);
    if (m) {
      obj[m[1].trim()] = cleanFrontmatterValue(m[2]);
    }
  }

  return obj;
}

function replaceMetadata(content, fm) {
  return String(content || "").replace(/=this\.([A-Za-z0-9_]+)/g, (_, key) => {
    return stripWikiLinks(fm[key] ?? "");
  });
}

function stripLeadingAdminBlock(content) {
  const adminKeys = [
    "book", "title", "subtitle", "author", "status",
    "copyright", "version", "edition", "type", "series",
    "series_book", "rights",
    "isbn", "isbn_epub", "epub_isbn", "isbnEpub",
    "isbn_paper", "isbn_paperback", "paper_isbn", "paperback_isbn", "isbnPaper", "isbnPaperback",
    "isbn_hard", "isbn_hardback", "hard_isbn", "hardback_isbn", "isbnHard", "isbnHardback",
    "identifier", "identifier_epub", "epub_identifier", "identifierEpub",
    "identifier_paper", "identifier_paperback", "paper_identifier", "paperback_identifier",
    "identifier_hard", "identifier_hardback", "hard_identifier", "hardback_identifier",
    "publisher", "imprint",
    "description", "subject", "keywords", "language",
    "cover", "cover_image", "epub_cover", "coverImage",
    "compiler", "compiler_version"
  ];

  const normalisedAdminKeys = adminKeys.map(k => k.toLowerCase());

  const lines = String(content || "").split(/\r?\n/);
  let i = 0;

  while (i < lines.length) {
    const line = lines[i].trim();

    if (!line) {
      i++;
      continue;
    }

    const m = line.match(/^([A-Za-z_ -]+):\s+.+$/);
    if (!m) break;

    const key = m[1].trim().toLowerCase().replace(/\s+/g, "_");
    if (!normalisedAdminKeys.includes(key)) break;

    i++;
  }

  return lines.slice(i).join("\n").replace(/^\s+/, "");
}

function titleFromMetadata(fm, fallback, level = "chapter") {
  if (level === "chapter") {
    if (fm.chapter && fm.title) return `${fm.chapter} — ${fm.title}`;
    if (fm.title) return fm.title;
    return fallback;
  }

  if (fm.title) return fm.title;
  return fallback;
}

function safeFileName(value) {
  return clean(value, "Review Compile")
    .replace(/[\\/:*?"<>|]/g, "")
    .trim();
}

function compactBlankLines(content) {
  return String(content || "").replace(/\n{4,}/g, "\n\n\n");
}

function mdHeading(level, text) {
  const safeLevel = Math.max(1, Math.min(6, Number(level) || 1));
  return `${"#".repeat(safeLevel)} ${clean(text, "Untitled")}`;
}

function shellQuote(value) {
  return `"${String(value || "").replace(/(["\\$`])/g, "\\$1")}"`;
}

function formatEdition(version) {
  const v = clean(version, "");
  if (!v) return "";
  if (/^edition\b/i.test(v)) return v;
  return `Edition ${v}`;
}

function frontMatterLine(label, value) {
  const v = clean(value, "");
  if (!v) return "";
  return `**${label}:** ${stripWikiLinks(v)}\n\n`;
}

function metadataList(value) {
  return clean(value, "")
    .split(/[;,]/)
    .map(v => v.trim())
    .filter(Boolean);
}

function epubIsbnFromFrontmatter(fm) {
  return firstNonEmpty(
    fm.isbn_epub,
    fm.epub_isbn,
    fm.isbnEpub,
    fm.isbn
  );
}

function epubIdentifierFromFrontmatter(fm) {
  return firstNonEmpty(
    fm.identifier_epub,
    fm.epub_identifier,
    fm.identifierEpub,
    fm.isbn_epub,
    fm.epub_isbn,
    fm.isbnEpub,
    fm.identifier,
    fm.isbn
  );
}

function paperIsbnFromFrontmatter(fm) {
  return firstNonEmpty(
    fm.isbn_paper,
    fm.isbn_paperback,
    fm.paper_isbn,
    fm.paperback_isbn,
    fm.isbnPaper,
    fm.isbnPaperback
  );
}

function hardIsbnFromFrontmatter(fm) {
  return firstNonEmpty(
    fm.isbn_hard,
    fm.isbn_hardback,
    fm.hard_isbn,
    fm.hardback_isbn,
    fm.isbnHard,
    fm.isbnHardback
  );
}

function publisherFromFrontmatter(fm) {
  return firstNonEmpty(
    fm.publisher,
    fm.imprint
  );
}

function imprintFromFrontmatter(fm) {
  return firstNonEmpty(
    fm.imprint,
    fm.publisher
  );
}

function frontMatterIsbnLine(label, value) {
  const v = clean(value, "");
  if (!v) return "";
  return frontMatterLine(label, v);
}

/* =========================
   MARKDOWN / EPUB HELPERS
========================= */

function neutraliseHeadingsInsideBody(content) {
  const lines = String(content || "").split(/\r?\n/);
  let inFence = false;

  return lines.map(line => {
    if (/^\s*(```|~~~)/.test(line)) {
      inFence = !inFence;
      return line;
    }

    if (!inFence) {
      const heading = line.match(/^\s{0,3}(#{1,6})\s+(.+?)\s*#*\s*$/);
      if (heading) {
        return `**${heading[2].trim()}**`;
      }
    }

    return line;
  }).join("\n");
}

function epubPageBreak() {
  return `\n\n`;
}

function stripMarkdownInline(text) {
  return stripWikiLinks(
    String(text || "")
      .replace(/^>\s?/, "")
      .replace(/\*\*(.*?)\*\*/g, "$1")
      .replace(/`([^`]*)`/g, "$1")
      .replace(/[‘’]/g, "'")
      .replace(/[“”]/g, '"')
  ).trimEnd();
}

/* =========================
   IMAGE HANDLING FOR EPUB
========================= */

function isImagePath(path) {
  return /\.(png|jpe?g|gif|webp|svg|pdf|tiff?|bmp)$/i.test(
    String(path || "").split("#")[0].split("?")[0]
  );
}

function normalisePathForPandoc(path) {
  return String(path || "").replace(/\\/g, "/").replace(/>/g, "%3E");
}

function markdownImagePath(path) {
  return `<${normalisePathForPandoc(path)}>`;
}

function imageAltFromPath(path) {
  return String(path || "")
    .split("/")
    .pop()
    .replace(/\.[^.]+$/, "")
    .replace(/[-_]+/g, " ")
    .trim();
}

function parseObsidianImageEmbed(target) {
  const parts = String(target || "")
    .split("|")
    .map(part => part.trim())
    .filter(Boolean);

  const link = parts.shift() || "";

  let alt = imageAltFromPath(link);
  let width = "";
  let height = "";

  for (const part of parts) {
    const dim = part.match(/^(\d+)\s*x\s*(\d+)$/i);
    if (dim) {
      width = dim[1];
      height = dim[2];
      continue;
    }

    const singleWidth = part.match(/^(\d+)$/);
    if (singleWidth) {
      width = singleWidth[1];
      continue;
    }

    alt = part;
  }

  return { link, alt, width, height };
}

function epubImageAttributes(width, height, existing = "") {
  const existingInner = String(existing || "")
    .replace(/^\{/, "")
    .replace(/\}$/, "")
    .trim();

  if (existingInner) return `{${existingInner}}`;

  if (width && height) return `{width=${width}px height=${height}px}`;
  if (width) return `{width=${width}px}`;

  return "";
}

function forEachMarkdownImage(content, replacer) {
  return String(content || "").replace(
    /!\[([^\]]*)\]\((<[^>]+>|[^)\n]+)\)(\{[^}]*\})?/g,
    (match, alt, target, attrs = "") => replacer(match, alt, target, attrs)
  );
}

const missingImageEmbeds = new Set();
const coverImageWarnings = new Set();

function resolveLocalImagePath(link, sourceFile) {
  let cleanLink = String(link || "")
    .trim()
    .replace(/^<|>$/g, "")
    .replace(/^['"]|['"]$/g, "");

  if (!cleanLink || /^(https?:|data:|mailto:|#)/i.test(cleanLink)) return null;

  cleanLink = decodeURIComponent(cleanLink);

  if (/^(\/|[A-Za-z]:[\\/])/.test(cleanLink) && isImagePath(cleanLink)) {
    return cleanLink;
  }

  const linkWithoutFragment = cleanLink.split("#")[0];

  let resolved = null;

  if (sourceFile && app.metadataCache && app.metadataCache.getFirstLinkpathDest) {
    resolved = app.metadataCache.getFirstLinkpathDest(linkWithoutFragment, sourceFile.path);
  }

  if (!resolved) {
    const direct = app.vault.getAbstractFileByPath(linkWithoutFragment);
    if (direct) resolved = direct;
  }

  if (!resolved || !resolved.path || !isImagePath(resolved.path)) {
    if (isImagePath(linkWithoutFragment)) {
      const source = sourceFile ? sourceFile.path : "unknown source";
      missingImageEmbeds.add(`${linkWithoutFragment} ← ${source}`);
    }
    return null;
  }

  return app.vault.adapter.getFullPath(resolved.path);
}

function convertObsidianImageEmbedsForEpub(content, sourceFile) {
  return String(content || "").replace(/!\[\[([^\]]+)\]\]/g, (match, target) => {
    const parsed = parseObsidianImageEmbed(target);
    const absPath = resolveLocalImagePath(parsed.link, sourceFile);

    if (!absPath) return match;

    const attrs = epubImageAttributes(parsed.width, parsed.height);
    return `![${parsed.alt}](${markdownImagePath(absPath)})${attrs}`;
  });
}

function convertLocalMarkdownImagesForEpub(content, sourceFile) {
  return forEachMarkdownImage(content, (match, alt, target, attrs = "") => {
    const trimmedTarget = String(target || "").trim();

    if (/^(https?:|data:|mailto:|#)/i.test(trimmedTarget.replace(/^<|>$/g, ""))) {
      return match;
    }

    const absPath = resolveLocalImagePath(trimmedTarget, sourceFile);
    if (!absPath) return match;

    return `![${alt}](${markdownImagePath(absPath)})${epubImageAttributes("", "", attrs)}`;
  });
}

function convertLocalImagesForEpub(content, sourceFile) {
  return convertLocalMarkdownImagesForEpub(
    convertObsidianImageEmbedsForEpub(content, sourceFile),
    sourceFile
  );
}

/* =========================
   EPUB COVER IMAGE HANDLING
========================= */

function cleanCoverTarget(value) {
  let v = String(value || "").trim();

  if (!v) return "";

  const obsidianEmbed = v.match(/^!\[\[([^\]]+)\]\]$/);
  if (obsidianEmbed) {
    return parseObsidianImageEmbed(obsidianEmbed[1]).link;
  }

  const obsidianLink = v.match(/^\[\[([^\]]+)\]\]$/);
  if (obsidianLink) {
    return parseObsidianImageEmbed(obsidianLink[1]).link;
  }

  const markdownImage = v.match(/^!\[[^\]]*\]\((<[^>]+>|[^)]+)\)/);
  if (markdownImage) {
    return markdownImage[1].replace(/^<|>$/g, "");
  }

  return parseObsidianImageEmbed(v).link;
}

function resolveCoverImageFromFrontmatter(fm, sourceFile) {
  const coverValue = firstNonEmpty(
    fm.cover_image,
    fm.cover,
    fm.epub_cover,
    fm.coverImage
  );

  if (!coverValue) return "";

  const target = cleanCoverTarget(coverValue);

  if (!target) return "";

  const absPath = resolveLocalImagePath(target, sourceFile);

  if (!absPath) {
    coverImageWarnings.add(`${target} ← ${sourceFile ? sourceFile.path : "unknown source"}`);
    return "";
  }

  return absPath;
}

/* =========================
   EPUB CALLOUT CONVERSION
========================= */

function normaliseCalloutType(type) {
  return clean(type, "note")
    .toLowerCase()
    .replace(/[^a-z0-9_-]/g, "-")
    .replace(/-+/g, "-")
    .replace(/^-|-$/g, "") || "note";
}

function humaniseCalloutType(type) {
  const normal = normaliseCalloutType(type);
  return normal
    .split(/[-_]+/)
    .filter(Boolean)
    .map(part => part ? part.charAt(0).toUpperCase() + part.slice(1) : part)
    .join(" ") || "Note";
}

function defaultCalloutTitle(type) {
  const normal = normaliseCalloutType(type);

  const titles = {
    "metadata": "Metadata",
    "state": "State",
    "prime-log": "PRIME Log",
    "janus": "JANUS",
    "janus-log": "JANUS Internal Log",
    "partition-log": "Partition Log",
    "divergent": "Partition Log",
    "annotation": "Annotation"
  };

  return titles[normal] || humaniseCalloutType(normal);
}

function calloutClass(type) {
  const normal = normaliseCalloutType(type);

  const map = {
    "metadata": "metadata",
    "state": "state",
    "prime-log": "prime-log",
    "janus": "janus",
    "janus-log": "janus-log",
    "partition-log": "partition-log",
    "divergent": "partition-log",
    "annotation": "annotation"
  };

  return map[normal] || `custom-${normal}`;
}


function htmlEscape(value) {
  return String(value || "")
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;");
}

function machineBlockHtml(lines) {
  const text = Array.from(lines || []).join("\n").replace(/^\n+|\n+$/g, "");
  return `<pre class="codex-machine-block"><code>${htmlEscape(text)}</code></pre>`;
}

function splitMarkdownTableRow(line) {
  return String(line || "")
    .trim()
    .replace(/^\|/, "")
    .replace(/\|$/, "")
    .split("|")
    .map(cell => htmlEscape(stripMarkdownInline(cell.trim())));
}

function isMarkdownTableSeparatorRow(line) {
  return /^\s*\|?\s*:?-{3,}:?\s*(\|\s*:?-{3,}:?\s*)+\|?\s*$/.test(String(line || ""));
}

function machineTableHtml(tableLines) {
  const rows = Array.from(tableLines || [])
    .filter(line => !isMarkdownTableSeparatorRow(line))
    .map(splitMarkdownTableRow)
    .filter(row => row.length);

  if (!rows.length) return "";

  const headers = rows[0];
  const bodyRows = rows.slice(1);

  let out = `<table class="codex-machine-table"><thead><tr>`;
  out += headers.map(cell => `<th>${cell}</th>`).join("");
  out += `</tr></thead>`;

  if (bodyRows.length) {
    out += `<tbody>`;
    for (const row of bodyRows) {
      out += `<tr>`;
      for (let i = 0; i < headers.length; i++) {
        out += `<td>${row[i] || ""}</td>`;
      }
      out += `</tr>`;
    }
    out += `</tbody>`;
  }

  out += `</table>`;
  return out;
}

function formatCalloutBodyMarkdown(markdown) {
  const lines = String(markdown || "").split(/\r?\n/);
  const out = [];

  function isPipeTableLine(line) {
    return /^\s*\|.*\|\s*$/.test(line);
  }

  function isTableSeparatorLine(line) {
    return /^\s*\|?\s*:?-{3,}:?\s*(\|\s*:?-{3,}:?\s*)+\|?\s*$/.test(line);
  }

  function isTableStart(index) {
    return (
      isPipeTableLine(lines[index] || "") &&
      isTableSeparatorLine(lines[index + 1] || "")
    );
  }

  function pushSeparated(block) {
    if (!block) return;
    if (out.length && out[out.length - 1].trim() !== "") out.push("");
    out.push(block);
    out.push("");
  }

  let i = 0;
  let inFence = false;
  let fenceMarker = "```";
  let fenceLines = [];

  while (i < lines.length) {
    const line = lines[i];
    const fence = line.match(/^\s*(```|~~~)/);

    if (fence) {
      if (!inFence) {
        inFence = true;
        fenceMarker = fence[1];
        fenceLines = [];
      } else if (fence[1] === fenceMarker) {
        pushSeparated(machineBlockHtml(fenceLines));
        inFence = false;
        fenceLines = [];
      } else {
        fenceLines.push(line);
      }

      i++;
      continue;
    }

    if (inFence) {
      fenceLines.push(line);
      i++;
      continue;
    }

    if (isTableStart(i)) {
      const tableLines = [];

      while (i < lines.length && isPipeTableLine(lines[i])) {
        tableLines.push(lines[i]);
        i++;
      }

      pushSeparated(machineTableHtml(tableLines));
      continue;
    }

    if (line.trim() === "") {
      out.push("");
      i++;
      continue;
    }

    out.push(`${line}  `);
    i++;
  }

  if (inFence && fenceLines.length) {
    pushSeparated(machineBlockHtml(fenceLines));
  }

  return out.join("\n");
}

function convertCalloutsForEpub(content) {
  return String(content || "").replace(
    /^> \[!([A-Za-z0-9_-]+)\]\s*([^\n]*)\n((?:>.*(?:\n|$))*)/gim,
    (match, type, title, body) => {
      const cls = calloutClass(type);
      const cleanTitle =
        title && title.trim()
          ? stripMarkdownInline(title)
          : defaultCalloutTitle(type);

      const lines = body
        .split(/\r?\n/)
        .map(line => {
          if (/^>\s*$/.test(line)) return "";
          return stripWikiLinks(line.replace(/^>\s?/, "").trimEnd());
        });

      while (lines.length && lines[0].trim() === "") lines.shift();
      while (lines.length && lines[lines.length - 1].trim() === "") lines.pop();

      const bodyMarkdown = formatCalloutBodyMarkdown(lines.join("\n"));

      let out = `\n\n::: {.codex-callout .${cls}}\n\n`;
      out += `**${cleanTitle}**\n\n`;

      if (bodyMarkdown.trim()) {
        out += `${bodyMarkdown}\n\n`;
      }

      out += `:::\n\n`;

      return out;
    }
  );
}

/* =========================
   EPUB CHAT CONVERSION
========================= */

function chatClass(line) {
  if (line.trim().startsWith(">")) return "chat-right";
  if (line.trim().startsWith("<")) return "chat-left";
  return "chat-left";
}

function cleanChatLineForEpub(line) {
  return String(line || "")
    .replace(/^\s*[><]\s*/, "")
    .trim();
}

function convertChatBlocksForEpub(content) {
  return String(content || "").replace(/```chat[^\n]*\n([\s\S]*?)```/gim, (match, body) => {
    const lines = body
      .split(/\r?\n/)
      .map(line => line.trim())
      .filter(Boolean);

    let out = "\n\n";

    for (const line of lines) {
      const cls = chatClass(line);
      const cleaned = stripWikiLinks(cleanChatLineForEpub(line));

      out += `::: {.codex-chat .${cls}}\n`;
      out += `${cleaned}\n`;
      out += `:::\n\n`;
    }

    return out;
  });
}

function convertSceneBreaksForEpub(content) {
  return String(content || "")
    .replace(/^\s*\*\*\*\s*$/gm, "\n\n* * *\n\n");
}


/* =========================
   EPUB MERMAID HANDLING
========================= */

const mermaidRenderWarnings = new Set();
let mermaidCliUnavailable = false;

function mermaidCliCandidates() {
  const configured = clean(MERMAID_CLI_COMMAND, "");
  if (configured) return [configured];

  return process.platform === "win32"
    ? ["mmdc.cmd", "mmdc"]
    : ["mmdc"];
}

function expandHomePathForNode(pathValue) {
  const value = clean(pathValue, "");
  if (!value) return "";

  if (value === "~") {
    return process.env.HOME || process.env.USERPROFILE || value;
  }

  if (value.startsWith("~/") || value.startsWith("~\\")) {
    const home = process.env.HOME || process.env.USERPROFILE || "";
    if (!home) return value;
    return require("path").join(home, value.slice(2));
  }

  return value;
}

function mermaidPuppeteerConfigArgs() {
  const fs = require("fs");
  const configured = clean(MERMAID_PUPPETEER_CONFIG_FILE, "");

  if (!configured) return [];

  const expanded = expandHomePathForNode(configured);

  if (expanded && fs.existsSync(expanded)) {
    return ["-p", expanded];
  }

  return [];
}

function mermaidAssetPaths(sourceText, sourceFile) {
  const crypto = require("crypto");
  const path = require("path");

  const sourceKey = sourceFile && sourceFile.path ? sourceFile.path : "unknown";
  const hash = crypto
    .createHash("sha256")
    .update(`${sourceKey}\n${sourceText}`)
    .digest("hex")
    .slice(0, 16);

  const baseName = `mermaid-${hash}`;
  const absDir = app.vault.adapter.getFullPath(MERMAID_EPUB_ASSET_FOLDER);

  return {
    absDir,
    mmdPath: path.join(absDir, `${baseName}.mmd`),
    imagePath: path.join(absDir, `${baseName}.${MERMAID_EPUB_IMAGE_FORMAT}`)
  };
}

function renderMermaidDiagramForEpub(sourceText, sourceFile) {
  const fs = require("fs");
  const childProcess = require("child_process");

  const diagram = String(sourceText || "").trim();
  if (!diagram) return "";

  const paths = mermaidAssetPaths(diagram, sourceFile);

  try {
    fs.mkdirSync(paths.absDir, { recursive: true });
    fs.writeFileSync(paths.mmdPath, diagram, "utf8");

    if (!fs.existsSync(paths.imagePath)) {
      let rendered = false;
      let lastError = null;

      for (const candidate of mermaidCliCandidates()) {
        try {
          childProcess.execFileSync(
            candidate,
            [
              "-i", paths.mmdPath,
              "-o", paths.imagePath,
              "-b", "white",
              ...mermaidPuppeteerConfigArgs()
            ],
            {
              stdio: "pipe",
              shell: process.platform === "win32"
            }
          );
          rendered = true;
          break;
        } catch (error) {
          lastError = error;
        }
      }

      if (!rendered) {
        mermaidCliUnavailable = true;
        throw lastError || new Error("Mermaid CLI render failed.");
      }
    }

    return `![Mermaid diagram](${markdownImagePath(paths.imagePath)}){width=100%}`;
  } catch (error) {
    const sourceLabel = sourceFile && sourceFile.path ? sourceFile.path : "unknown source";
    mermaidRenderWarnings.add(`${sourceLabel}: ${error && error.message ? error.message : String(error)}`);
    return "";
  }
}

function convertQuotedMermaidBlocksForEpub(content, sourceFile) {
  return String(content || "").replace(
    /^>\s*```mermaid[^\n]*\n([\s\S]*?)^>\s*```\s*$/gim,
    (match, body) => {
      const diagram = String(body || "")
        .split(/\r?\n/)
        .map(line => line.replace(/^>\s?/, ""))
        .join("\n")
        .trim();

      const imageMarkdown = renderMermaidDiagramForEpub(diagram, sourceFile);
      if (!imageMarkdown) return match;

      return `> ${imageMarkdown}`;
    }
  );
}

function convertPlainMermaidBlocksForEpub(content, sourceFile) {
  return String(content || "").replace(
    /```mermaid[^\n]*\n([\s\S]*?)```/gim,
    (match, body) => {
      const imageMarkdown = renderMermaidDiagramForEpub(body, sourceFile);
      return imageMarkdown || match;
    }
  );
}

function convertMermaidBlocksForEpub(content, sourceFile) {
  return convertPlainMermaidBlocksForEpub(
    convertQuotedMermaidBlocksForEpub(content, sourceFile),
    sourceFile
  );
}

function prepareContentForEpub(content, sourceFile) {
  let out = String(content || "");

  out = convertMermaidBlocksForEpub(out, sourceFile);
  out = convertLocalImagesForEpub(out, sourceFile);
  out = convertCalloutsForEpub(out);
  out = convertChatBlocksForEpub(out);
  out = convertSceneBreaksForEpub(out);

  out = stripWikiLinks(out);

  return out;
}

/* =========================
   EPUB CSS
========================= */

function buildEpubCss() {
  return `
body {
  font-family: serif;
  line-height: 1.45;
  margin: 0;
  padding: 0;
}

h1, h2, h3, h4 {
  text-align: center;
  line-height: 1.25;
}

h1 {
  margin-top: 2em;
}

h2, h3, h4 {
  margin-top: 1.5em;
  page-break-before: always;
  break-before: page;
}

p {
  margin: 0.65em 0;
}

img {
  max-width: 100%;
  height: auto;
}

table {
  border-collapse: collapse;
  width: 100%;
  font-size: 0.9em;
}

td, th {
  border: 1px solid #999;
  padding: 0.3em;
  vertical-align: top;
}

blockquote {
  border-left: 0.25em solid #999;
  margin: 1em 0;
  padding: 0.2em 0 0.2em 0.8em;
  font-size: 0.95em;
}

blockquote p {
  margin: 0.25em 0;
}

.codex-callout {
  border: 1px solid #999;
  border-radius: 0.4em;
  padding: 0.75em;
  margin: 1em 0;
  font-size: 0.95em;
}

.codex-callout p {
  margin: 0.35em 0;
}

.codex-callout table {
  margin: 0.75em 0;
  width: 100%;
}

.codex-callout th,
.codex-callout td {
  vertical-align: top;
}

.codex-callout.metadata {
  background: #f7f7f7;
}

.codex-callout.state {
  border-left: 0.25em solid #999;
  background: #f7f7f7;
}

.codex-callout[class*="custom-"] {
  background: #fff;
}

.codex-callout.annotation {
  font-style: italic;
  background: #fff;
}

.codex-callout.prime-log {
  background: #111;
  color: #eee;
  font-family: monospace;
  white-space: normal;
}

.codex-callout.prime-log p {
  font-family: monospace;
}

.codex-callout.janus,
.codex-callout.janus-log {
  background: #eee;
  font-family: sans-serif;
}

.codex-callout.partition-log {
  background: #eef7ee;
}


.codex-machine-block {
  white-space: pre-wrap !important;
  font-family: monospace;
  font-size: 0.9em;
  line-height: 1.25;
  overflow-wrap: normal;
  word-wrap: normal;
  word-break: normal;
  tab-size: 2;
  border: 1px solid #aaa;
  border-radius: 0.35em;
  padding: 0.75em;
  margin: 0.75em 0;
  background: #f5f5f5;
}

.codex-machine-block code {
  white-space: pre-wrap !important;
  font-family: monospace;
  overflow-wrap: normal;
  word-wrap: normal;
  word-break: normal;
}

.codex-callout.prime-log .codex-machine-block {
  background: #1a1a1a;
  color: #eee;
  border-color: #555;
}

.codex-callout.janus .codex-machine-block,
.codex-callout.janus-log .codex-machine-block,
.codex-callout.partition-log .codex-machine-block {
  background: #f9f9f9;
}


.codex-machine-table {
  width: 100%;
  border-collapse: collapse;
  table-layout: fixed;
  font-family: monospace;
  font-size: 0.84em;
  line-height: 1.25;
  margin: 0.75em 0;
}

.codex-machine-table th,
.codex-machine-table td {
  border: 1px solid #888;
  padding: 0.35em 0.45em;
  text-align: left;
  vertical-align: top;
  overflow-wrap: anywhere;
  word-wrap: break-word;
  word-break: break-word;
}

.codex-machine-table th {
  background: #e6e6e6;
  font-weight: bold;
}

.codex-callout.prime-log .codex-machine-table th,
.codex-callout.prime-log .codex-machine-table td {
  border-color: #555;
}

.codex-callout.prime-log .codex-machine-table th {
  background: #222;
  color: #eee;
}

.codex-chat {
  border: 1px solid #aaa;
  border-radius: 0.5em;
  padding: 0.5em 0.75em;
  margin: 0.55em 0;
  font-size: 0.95em;
}

.codex-chat.chat-left {
  margin-right: 15%;
  background: #f4f4f4;
}

.codex-chat.chat-right {
  margin-left: 15%;
  background: #e8e8e8;
}

pre,
pre.sourceCode {
  white-space: pre-wrap !important;
  overflow-wrap: anywhere;
  word-wrap: break-word;
  word-break: break-word;
  max-width: 100%;
  overflow-x: visible;
  border: 1px solid #aaa;
  border-radius: 0.35em;
  padding: 0.75em;
  background: #f5f5f5;
}

pre code,
pre code.sourceCode,
pre.sourceCode code,
pre.sourceCode code.sourceCode {
  white-space: pre-wrap !important;
  overflow-wrap: anywhere;
  word-wrap: break-word;
  word-break: break-word;
}

pre code span,
pre.sourceCode span {
  white-space: pre-wrap !important;
  overflow-wrap: anywhere;
  word-wrap: break-word;
  word-break: break-word;
}

code {
  font-family: monospace;
  overflow-wrap: anywhere;
  word-wrap: break-word;
  word-break: break-word;
}

hr {
  border: 0;
  text-align: center;
  margin: 1.5em 0;
}

hr:after {
  content: "• • •";
  letter-spacing: 0.25em;
}
`;
}

/* =========================
   PROJECT DISCOVERY
========================= */

function getFolderForFolderNoteFile(file) {
  const parent = file.parent;
  if (!parent) return null;

  if (parent.name === file.basename) {
    return parent;
  }

  const siblingFolderPath =
    parent.path === "/"
      ? file.basename
      : `${parent.path}/${file.basename}`;

  const sibling = app.vault.getAbstractFileByPath(siblingFolderPath);
  if (sibling && isFolder(sibling)) {
    return sibling;
  }

  return null;
}

async function discoverProjects(projectType) {
  const files = app.vault.getMarkdownFiles();
  const projects = [];

  for (const file of files) {
    const raw = await app.vault.read(file);
    const fm = extractFrontmatter(raw);

    if ((fm.type || "").toLowerCase() !== projectType) continue;

    const folder = getFolderForFolderNoteFile(file);
    if (!folder) continue;

    projects.push({
      label: clean(fm.title, folder.name),
      folder,
      file,
      fm
    });
  }

  return projects.sort((a, b) =>
    a.label.localeCompare(b.label, undefined, { numeric: true })
  );
}

const projects = await discoverProjects(projectKind);

if (!projects.length) {
  new Notice(`No projects found with type: ${projectKind}`);
  throw new Error(`No projects found with type: ${projectKind}`);
}

const selectedProject = await tp.system.suggester(
  projects.map(p => `${p.label} — ${p.folder.path}`),
  projects
);

const PROJECT_ROOT = selectedProject.folder;

/* =========================
   FOLDER NOTE HANDLING
========================= */

function getFolderNote(folder) {
  const candidates = [
    `${folder.path}/${folder.name}.md`,
    `${folder.path}.md`
  ];

  for (const path of candidates) {
    const file = app.vault.getAbstractFileByPath(path);
    if (file) return file;
  }

  return null;
}

function isInsideNamedFolder(path, folderName) {
  const normal = String(path || "").replace(/\\/g, "/");
  return (
    normal === folderName ||
    normal.startsWith(`${folderName}/`) ||
    normal.includes(`/${folderName}/`)
  );
}

function shouldIgnoreFile(file) {
  return (
    file.name === "Index.md" ||
    isInsideNamedFolder(file.path, "Manuscripts") ||
    isInsideNamedFolder(file.path, "Templates")
  );
}

/* =========================
   NOTE READING
========================= */

async function readCompiledNote(file, options = {}) {
  if (!file) return { content: "", fm: {} };

  const outputFormat = options.outputFormat || "review";

  let raw = await app.vault.read(file);
  raw = raw
    .replace(/^\uFEFF/, "")
    .replace(/\u200B/g, "");

  const fm = extractFrontmatter(raw);

  let content = raw.replace(/^---\s*\r?\n[\s\S]*?\r?\n---\s*\r?\n?/, "");

  if (["trilogy", "book", "part"].includes((fm.type || "").toLowerCase())) {
    content = stripLeadingAdminBlock(content);
  }

  content = replaceMetadata(content, fm);

  if (options.neutraliseInternalHeadings) {
    content = neutraliseHeadingsInsideBody(content);
  }

  if (outputFormat === "epub") {
    content = prepareContentForEpub(content, file);
  }

  return { content: compactBlankLines(content.trim()), fm };
}

/* =========================
   STRUCTURE
========================= */

async function folderTitle(folder) {
  const note = getFolderNote(folder);
  const { fm } = await readCompiledNote(note);
  return titleFromMetadata(fm, folder.name, "folder");
}

async function fileTitle(file) {
  const { fm } = await readCompiledNote(file);
  return titleFromMetadata(fm, file.basename, "chapter");
}

async function folderType(folder) {
  const note = getFolderNote(folder);
  const { fm } = await readCompiledNote(note);
  return (fm.type || "").toLowerCase();
}

async function getBookFolders(root) {
  if (projectKind === "book") return [root];

  const candidates = sortItems(
    root.children.filter(item =>
      isFolder(item) &&
      item.name !== "Manuscripts" &&
      item.name !== "Templates"
    )
  );

  const books = [];

  for (const folder of candidates) {
    if (await folderType(folder) === "book") books.push(folder);
  }

  return books;
}

async function getPartFolders(bookFolder) {
  const candidates = sortItems(
    bookFolder.children.filter(item =>
      isFolder(item) &&
      item.name !== "Manuscripts" &&
      item.name !== "Templates"
    )
  );

  const parts = [];

  for (const folder of candidates) {
    const type = await folderType(folder);
    if (!type || type === "part") parts.push(folder);
  }

  return parts;
}

function getChapterFiles(partFolder) {
  const partNote = getFolderNote(partFolder);

  return sortItems(
    partFolder.children.filter(file =>
      isMarkdown(file) &&
      !shouldIgnoreFile(file) &&
      (!partNote || file.path !== partNote.path)
    )
  );
}

function getSharedFolder() {
  const direct = app.vault.getAbstractFileByPath(`${PROJECT_ROOT.path}/Shared`);
  if (isFolder(direct)) return direct;

  const parentPath = PROJECT_ROOT.parent && PROJECT_ROOT.parent.path ? PROJECT_ROOT.parent.path : "";
  if (parentPath) {
    const sibling = app.vault.getAbstractFileByPath(`${parentPath}/Shared`);
    if (isFolder(sibling)) return sibling;
  }

  return null;
}

function getSharedFiles() {
  const sharedFolder = getSharedFolder();
  if (!sharedFolder) return [];

  const sharedNote = getFolderNote(sharedFolder);

  return sortItems(
    sharedFolder.children.filter(file =>
      isMarkdown(file) &&
      !shouldIgnoreFile(file) &&
      (!sharedNote || file.path !== sharedNote.path)
    )
  );
}

/* =========================
   EPUB FRONT MATTER
========================= */

async function buildEpubFrontMatter(projectFm, books, projectTitle) {
  const author = clean(projectFm.author, "");
  const subtitle = clean(projectFm.subtitle, "");
  const version = clean(projectFm.version, "");
  const date = clean(projectFm.date, compileDate);
  const rights = clean(projectFm.rights, "All rights reserved.");
  const copyright = clean(projectFm.copyright, "");
  const year = clean(projectFm.year, window.moment().format("YYYY"));
  const publisher = publisherFromFrontmatter(projectFm);
  const imprint = imprintFromFrontmatter(projectFm);
  const isbn = epubIsbnFromFrontmatter(projectFm);
  const isbnPaper = paperIsbnFromFrontmatter(projectFm);
  const isbnHard = hardIsbnFromFrontmatter(projectFm);
  const identifier = epubIdentifierFromFrontmatter(projectFm);
  const subject = clean(projectFm.subject, "");
  const keywords = clean(projectFm.keywords, "");
  const series = clean(projectFm.series, "");

  let out = "";

  out += `# ${stripWikiLinks(projectTitle)}\n\n`;

  if (subtitle) out += `_${stripWikiLinks(subtitle)}_\n\n`;
  if (author) out += `**${stripWikiLinks(author)}**\n\n`;
  if (series) out += `${stripWikiLinks(series)}\n\n`;
  if (version) out += `${formatEdition(version)}\n\n`;
  if (date) out += `${stripWikiLinks(date)}\n\n`;

  out += frontMatterLine("Publisher", publisher);
  if (imprint && imprint !== publisher) {
    out += frontMatterLine("Imprint", imprint);
  }
  out += frontMatterIsbnLine("EPUB ISBN", isbn);
  out += frontMatterIsbnLine("Paperback ISBN", isbnPaper);
  out += frontMatterIsbnLine("Hardback ISBN", isbnHard);
  if (identifier && identifier !== isbn) {
    out += frontMatterLine("Identifier", identifier);
  }
  out += frontMatterLine("Subject", subject);
  out += frontMatterLine("Keywords", keywords);

  out += `# Copyright\n\n`;

  if (copyright) {
    out += `${stripWikiLinks(copyright)}\n\n`;
  } else if (author) {
    out += `Copyright © ${year} ${stripWikiLinks(author)}.\n\n`;
  }

  out += `${stripWikiLinks(rights)}\n\n`;

  if (publisher) {
    out += `Published by ${stripWikiLinks(publisher)}.\n\n`;
  }
  if (imprint && imprint !== publisher) {
    out += `Imprint: ${stripWikiLinks(imprint)}.\n\n`;
  }

  if (version) out += `Version: ${formatEdition(version)}\n\n`;
  out += frontMatterIsbnLine("EPUB ISBN", isbn);
  out += frontMatterIsbnLine("Paperback ISBN", isbnPaper);
  out += frontMatterIsbnLine("Hardback ISBN", isbnHard);

  if (books.length > 1) {
    out += `# Books in this edition\n\n`;

    for (const book of books) {
      const { fm: bookFm } = await readCompiledNote(
        getFolderNote(book),
        { outputFormat: "review" }
      );

      const bookTitle = titleFromMetadata(bookFm, book.name, "folder");

      out += `**${stripWikiLinks(bookTitle)}**\n\n`;

      if (bookFm.subtitle) {
        out += `_${stripWikiLinks(bookFm.subtitle)}_\n\n`;
      }

      if (bookFm.series_book) {
        out += frontMatterLine("Series position", bookFm.series_book);
      } else if (bookFm.book) {
        out += frontMatterLine("Book", bookFm.book);
      }

      out += frontMatterLine("Series", bookFm.series);
      out += frontMatterLine("Version", bookFm.version);
      out += frontMatterLine("Status", bookFm.status);
      out += frontMatterLine("Publisher", publisherFromFrontmatter(bookFm));
      const bookImprint = imprintFromFrontmatter(bookFm);
      const bookPublisher = publisherFromFrontmatter(bookFm);
      if (bookImprint && bookImprint !== bookPublisher) {
        out += frontMatterLine("Imprint", bookImprint);
      }
      out += frontMatterIsbnLine("EPUB ISBN", epubIsbnFromFrontmatter(bookFm));
      out += frontMatterIsbnLine("Paperback ISBN", paperIsbnFromFrontmatter(bookFm));
      out += frontMatterIsbnLine("Hardback ISBN", hardIsbnFromFrontmatter(bookFm));
    }

  }

  return out;
}

/* =========================
   BUILD OUTPUT
========================= */

async function buildCompiledMarkdown(options = {}) {
  const outputFormat = options.outputFormat || "review";
  const includeManualContents = !!options.includeManualContents;

  const projectNote = getFolderNote(PROJECT_ROOT);
  const { content: projectContent, fm: projectFm } = await readCompiledNote(
    projectNote,
    {
      neutraliseInternalHeadings: true,
      outputFormat
    }
  );

  const books = await getBookFolders(PROJECT_ROOT);
  const projectTitle = clean(projectFm.title, selectedProject.label);
  const singleBookEdition = outputFormat === "epub" && books.length === 1;
  const sharedFiles = outputFormat === "epub" ? getSharedFiles() : [];

  let bookHeadingLevel = projectKind === "trilogy" && !singleBookEdition ? 2 : 1;
  let partHeadingLevel = projectKind === "trilogy" && !singleBookEdition ? 3 : 2;
  let chapterHeadingLevel = projectKind === "trilogy" && !singleBookEdition ? 4 : 3;

  // KDP/Kindle navigation is safest at two levels.
  // For single-book EPUBs, make parts/front matter top-level and chapters second-level:
  //   DETECTION
  //     1.1.1 — The Router
  // rather than Contents -> DETECTION -> Chapter.
  if (singleBookEdition) {
    bookHeadingLevel = 1;
    partHeadingLevel = 1;
    chapterHeadingLevel = 2;
  }

  let output = "";

  if (outputFormat === "review") {
    output += `<!-- Compiled by Codex Review + EPUB Compiler v${CODEX_REVIEW_EPUB_VERSION} on ${compileDateTime} -->\n\n`;
    output += `${mdHeading(1, projectTitle)}\n\n`;

    if (projectContent.trim() && projectKind === "trilogy") {
      output += `${projectContent.trim()}\n\n`;
    }
  }

  if (outputFormat === "epub") {
    output += await buildEpubFrontMatter(projectFm, books, projectTitle);

    if (projectContent.trim() && projectKind === "trilogy") {
      output += `${projectContent.trim()}\n\n`;
    }
  }

  if (includeManualContents) {
    const contentsHeadingLevel = singleBookEdition ? 1 : 2;
    output += `${mdHeading(contentsHeadingLevel, "Contents")}\n\n`;

    if (singleBookEdition) {
      const book = books[0];

      for (const part of await getPartFolders(book)) {
        output += `- ${await folderTitle(part)}\n`;

        for (const chapter of getChapterFiles(part)) {
          output += `  - ${await fileTitle(chapter)}\n`;
        }
      }

      output += `\n`;
    } else {
      for (const book of books) {
        output += `- **${await folderTitle(book)}**\n`;

        for (const part of await getPartFolders(book)) {
          output += `  - ${await folderTitle(part)}\n`;

          for (const chapter of getChapterFiles(part)) {
            output += `    - ${await fileTitle(chapter)}\n`;
          }
        }

        output += `\n`;
      }
    }

    if (sharedFiles.length) {
      if (singleBookEdition) {
        for (const sharedFile of sharedFiles) {
          output += `- ${await fileTitle(sharedFile)}\n`;
        }
      } else {
        output += `- **Back matter**\n`;

        for (const sharedFile of sharedFiles) {
          output += `  - ${await fileTitle(sharedFile)}\n`;
        }
      }

      output += `\n`;
    }
  }

  for (const book of books) {
    const { content: bookContent, fm: bookFm } = await readCompiledNote(
      getFolderNote(book),
      {
        neutraliseInternalHeadings: true,
        outputFormat
      }
    );
    const bookTitle = titleFromMetadata(bookFm, book.name, "folder");

    if (outputFormat === "epub") {
      output += epubPageBreak();
    }

    if (projectKind === "trilogy" && !singleBookEdition) {
      output += `
${mdHeading(bookHeadingLevel, bookTitle)}

`;

      if (bookContent.trim()) {
        output += `${bookContent.trim()}

`;
      }
    } else if (bookContent.trim()) {
      if (outputFormat === "epub") {
        output += `
${mdHeading(partHeadingLevel, "Introduction")}

`;
      }

      output += `
${bookContent.trim()}

`;
    }

    for (const part of await getPartFolders(book)) {
      const { content: partContent, fm: partFm } = await readCompiledNote(
        getFolderNote(part),
        {
          neutraliseInternalHeadings: true,
          outputFormat
        }
      );
      const partTitle = titleFromMetadata(partFm, part.name, "folder");

      if (outputFormat === "epub") {
        output += epubPageBreak();
      }

      output += `\n${mdHeading(partHeadingLevel, partTitle)}\n\n`;

      if (partContent.trim()) {
        output += `${partContent.trim()}\n\n`;
      }

      for (const chapter of getChapterFiles(part)) {
        const { content, fm } = await readCompiledNote(
          chapter,
          {
            neutraliseInternalHeadings: true,
            outputFormat
          }
        );
        const chapterTitle = titleFromMetadata(fm, chapter.basename, "chapter");

        if (outputFormat === "epub") {
          output += epubPageBreak();
        }

        output += `\n${mdHeading(chapterHeadingLevel, chapterTitle)}\n\n`;

        if (content.trim()) {
          output += `${content.trim()}\n\n`;
        }
      }
    }
  }

  if (outputFormat === "epub" && sharedFiles.length) {
    for (const sharedFile of sharedFiles) {
      const { content, fm } = await readCompiledNote(
        sharedFile,
        {
          neutraliseInternalHeadings: true,
          outputFormat
        }
      );
      const sharedTitle = titleFromMetadata(fm, sharedFile.basename, "chapter");

      output += epubPageBreak();
      output += `\n${mdHeading(partHeadingLevel, sharedTitle)}\n\n`;

      if (content.trim()) {
        output += `${content.trim()}\n\n`;
      }
    }
  }

  return {
    output: compactBlankLines(output.trim()) + "\n",
    projectFm,
    projectTitle
  };
}

/* =========================
   WRITE OUTPUTS
========================= */

const manuscriptsFolder = ROOT_MANUSCRIPTS_FOLDER;
await ensureFolder(manuscriptsFolder);

const reviewBuild = await buildCompiledMarkdown({
  outputFormat: "review",
  includeManualContents: includeContents
});

const titleSafe = safeFileName(reviewBuild.projectTitle);
const fileName = `${titleSafe} - ${compileDate} (epub)`;

if (writeReviewMarkdown) {
  const reviewOutputPath = `${manuscriptsFolder}/${fileName}.md`;
  await writeOrReplace(reviewOutputPath, reviewBuild.output);
}

/* =========================
   EPUB EXPORT
========================= */

if (writeEpub) {
  const epubBuild = await buildCompiledMarkdown({
    outputFormat: "epub",
    includeManualContents: true
  });

  const epubTempPath = `${manuscriptsFolder}/.${fileName}.epub-export.md`;
  const epubCssPath = `${manuscriptsFolder}/.${fileName}.epub.css`;
  const outputBase = `${manuscriptsFolder}/${fileName}`;

  await writeOrReplace(epubTempPath, epubBuild.output);
  await writeOrReplace(epubCssPath, buildEpubCss());

  const absEpubMdPath = app.vault.adapter.getFullPath(epubTempPath);
  const absEpubCssPath = app.vault.adapter.getFullPath(epubCssPath);
  const absOutputBase = app.vault.adapter.getFullPath(outputBase);

  const coverSourceFile = getFolderNote(PROJECT_ROOT) || selectedProject.file;
  const coverImagePath = resolveCoverImageFromFrontmatter(
    epubBuild.projectFm,
    coverSourceFile
  );

  if (missingImageEmbeds.size) {
    console.warn(
      "Codex Review + EPUB could not resolve these image embeds:",
      Array.from(missingImageEmbeds)
    );
    new Notice(`Codex EPUB: ${missingImageEmbeds.size} image embed(s) could not be resolved. See console.`);
  }

  if (coverImageWarnings.size) {
    console.warn(
      "Codex Review + EPUB could not resolve the configured cover image:",
      Array.from(coverImageWarnings)
    );
    new Notice("Codex EPUB: configured cover image could not be resolved. See console.");
  }
  if (mermaidRenderWarnings.size) {
    console.warn(
      "Codex Review + EPUB could not render these Mermaid diagram(s):",
      Array.from(mermaidRenderWarnings)
    );

    if (mermaidCliUnavailable) {
      new Notice("Codex EPUB: Mermaid CLI/mmdc unavailable or failed. Mermaid blocks left as code. See console.");
    } else {
      new Notice(`Codex EPUB: ${mermaidRenderWarnings.size} Mermaid diagram(s) could not be rendered. See console.`);
    }
  }


  const author = clean(epubBuild.projectFm.author, "");
  const subtitle = clean(epubBuild.projectFm.subtitle, "");
  const language = clean(epubBuild.projectFm.language, "en-GB");
  const rights = clean(epubBuild.projectFm.rights, "");
  const description = clean(epubBuild.projectFm.description, subtitle);
  const publisher = publisherFromFrontmatter(epubBuild.projectFm);
  const imprint = imprintFromFrontmatter(epubBuild.projectFm);
  const isbn = epubIsbnFromFrontmatter(epubBuild.projectFm);
  const isbnPaper = paperIsbnFromFrontmatter(epubBuild.projectFm);
  const isbnHard = hardIsbnFromFrontmatter(epubBuild.projectFm);
  const identifier = epubIdentifierFromFrontmatter(epubBuild.projectFm);
  const subject = clean(epubBuild.projectFm.subject, "");
  const keywords = clean(epubBuild.projectFm.keywords, "");
  const series = clean(epubBuild.projectFm.series, "");
  const version = clean(epubBuild.projectFm.version, "");

  const path = require("path");

  function addMetadata(args, key, value) {
    const v = clean(value, "");
    if (v) args.push("--metadata", `${key}=${v}`);
  }

  function uniqueNonEmpty(values) {
    return Array.from(new Set(values.map(v => clean(v, "")).filter(Boolean)));
  }

  function safeFullPath(vaultPath) {
    try {
      return app.vault.adapter.getFullPath(vaultPath || "");
    } catch (e) {
      return "";
    }
  }

  const resourcePaths = uniqueNonEmpty([
    app.vault.adapter.getBasePath ? app.vault.adapter.getBasePath() : "",
    safeFullPath(""),
    safeFullPath(ROOT_MANUSCRIPTS_FOLDER),
    PROJECT_ROOT ? safeFullPath(PROJECT_ROOT.path) : ""
  ]).join(path.delimiter);

  const pandocArgs = [
    `--from=${PANDOC_FROM_EPUB}`,
    absEpubMdPath,
    "-o", `${absOutputBase}.epub`,
    "--standalone",
    "--epub-title-page=false",
    "--toc-depth=2",
    "--split-level=2",
    "--wrap=preserve",
    "--css", absEpubCssPath
  ];

  if (resourcePaths) {
    pandocArgs.push("--resource-path", resourcePaths);
  }

  addMetadata(pandocArgs, "title", epubBuild.projectTitle);
  addMetadata(pandocArgs, "lang", language);
  addMetadata(pandocArgs, "date", compileDate);

  if (coverImagePath) {
    pandocArgs.push("--epub-cover-image", coverImagePath);
  }

  addMetadata(pandocArgs, "author", author);
  addMetadata(pandocArgs, "subtitle", subtitle);
  addMetadata(pandocArgs, "description", description);
  addMetadata(pandocArgs, "publisher", publisher);
  addMetadata(pandocArgs, "imprint", imprint);
  addMetadata(pandocArgs, "rights", rights);
  addMetadata(pandocArgs, "identifier", identifier);

  if (isbn) {
    addMetadata(pandocArgs, "isbn", isbn);
    addMetadata(pandocArgs, "isbn_epub", isbn);
  }

  addMetadata(pandocArgs, "isbn_paper", isbnPaper);
  addMetadata(pandocArgs, "isbn_hard", isbnHard);
  addMetadata(pandocArgs, "series", series);
  addMetadata(pandocArgs, "version", version);
  addMetadata(pandocArgs, "subject", subject);

  for (const keyword of metadataList(keywords)) {
    addMetadata(pandocArgs, "subject", keyword);
  }

  const commandForLog = ["pandoc", ...pandocArgs.map(shellQuote)].join(" ");

  console.log("Running EPUB export command:");
  console.log(commandForLog);

  new Notice("Running Pandoc EPUB export...");

  require("child_process").execFile("pandoc", pandocArgs, { maxBuffer: 20 * 1024 * 1024 }, (error, stdout, stderr) => {
    if (error) {
      console.error("Pandoc EPUB export failed:", error);
      if (stderr) console.error(stderr);

      if (error.code === "ENOENT") {
        new Notice("Pandoc EPUB export failed: pandoc was not found in Obsidian's PATH.");
      } else {
        new Notice("Pandoc EPUB export failed. Check console.");
      }
      return;
    }

    if (stdout) console.log(stdout);
    if (stderr) console.warn(stderr);

    if (coverImagePath) {
      new Notice(`Codex EPUB export complete with cover: ${fileName}.epub`);
    } else {
      new Notice(`Codex EPUB export complete: ${fileName}.epub`);
    }
  });
}

/* =========================
   FINAL NOTICE
========================= */

if (writeReviewMarkdown && writeEpub) {
  new Notice(`Codex Review + EPUB compile started: ${fileName}.md / .epub`);
} else if (writeReviewMarkdown) {
  new Notice(`Codex Review compile complete: ${fileName}.md`);
} else {
  new Notice(`Codex EPUB compile started: ${fileName}.epub`);
}
-%>
