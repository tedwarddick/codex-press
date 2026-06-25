<%*
/* =========================
   CODEX PRESS v1.0.0
   Markdown,PDF and DOCX NOVEL COMPILER
	Optimised for Amazon KDP

/* =========================
   USER INPUTS
========================= */

const projectKind = await tp.system.suggester(
  ["Trilogy", "Book"],
  ["trilogy", "book"]
);

const mode = await tp.system.suggester(
  ["Draft", "Publish"],
  ["draft", "publish"]
);

const exportType = await tp.system.suggester(
  ["None", "PDF", "DOCX", "Both"],
  ["none", "pdf", "docx", "both"]
);

/* =========================
   HELPERS
========================= */

const CODEX_VERSION = "1.4.6";
const compileDate = window.moment().format("YYYY-MM-DD");

// Disable Pandoc YAML metadata blocks because manuscript prose can legitimately
// contain standalone --- scene breaks or copied YAML-like fragments. If Pandoc
// treats those as metadata, exports can fail with:
// "YAML parse exception... mapping values are not allowed in this context".
const PANDOC_FROM_PDF = "markdown+raw_tex+fenced_divs-yaml_metadata_block";
const PANDOC_FROM_DOCX = "markdown-yaml_metadata_block";

// Mermaid diagrams must be rendered before the generic code-block converter runs,
// otherwise Pandoc/LaTeX will print them as code rather than diagrams.
const MERMAID_PDF_IMAGE_FORMAT = "png";
const MERMAID_PDF_ASSET_FOLDER = "Manuscripts/.codex-mermaid-assets";
const MERMAID_CLI_COMMAND = ""; // Optional override, e.g. "mmdc.cmd" or full path to mmdc.
const MERMAID_PUPPETEER_CONFIG_FILE = "~/.config/mermaid/puppeteer-config.json"; // Optional. Set to "" to disable.
const fenceBalanceWarnings = new Set();
const usedBookmarkAnchors = new Map();

function pageBreak() {
  return `\n\n<!-- PAGEBREAK -->\n\n`;
}

function rectoBreak() {
  return `\n\n<!-- RECTOBREAK -->\n\n`;
}

function rawLatex(tex) {
  return `\n\n<!-- LATEX:${tex.replace(/--/g, "- -")} -->\n\n`;
}

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
    // [[Target|Alias]] -> Alias
    .replace(/\[\[([^\]|]+)\|([^\]]+)\]\]/g, "$2")
    // [[Target]] -> Target
    .replace(/\[\[([^\]]+)\]\]/g, "$1");
}

function cleanFrontmatterValue(value) {
  return stripWikiLinks(
    String(value || "")
      .trim()
      .replace(/^["']|["']$/g, "")
  );
}

function normaliseUnicodeSpacing(value) {
  return String(value || "")
    // XeLaTeX's default Latin Modern fonts do not always contain wide Unicode spaces.
    // Normalise them before Pandoc/LaTeX export so they cannot become missing-glyph
    // warnings or disturb table/callout layout.
    .replace(/[\u2000-\u200A\u202F\u205F\u3000]/g, " ")
    .replace(/\u00A0/g, " ");
}

function isImagePath(path) {
  return /\.(png|jpe?g|gif|webp|svg|pdf|tiff?|bmp)$/i.test(String(path || "").split("#")[0].split("?")[0]);
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
  const parts = String(target || "").split("|").map(part => part.trim()).filter(Boolean);
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

const IMAGE_MAX_WIDTH = "33%";

function constrainImageAttributes(existing = "") {
  const existingInner = String(existing || "")
    .replace(/^\{/, "")
    .replace(/\}$/, "")
    .trim();

  const preserved = existingInner
    ? existingInner
        .split(/\s+/)
        .filter(attr => !/^width=/i.test(attr) && !/^height=/i.test(attr))
    : [];

  return `{width=${IMAGE_MAX_WIDTH}${preserved.length ? " " + preserved.join(" ") : ""}}`;
}

function imageAttributes(width, height, existing = "") {
  // v1.1.4: all manuscript images are capped consistently.
  // We intentionally ignore source width/height hints because many embeds contain
  // large Obsidian preview dimensions such as |677x677.
  return constrainImageAttributes(existing);
}

function forEachMarkdownImage(content, replacer) {
  // Handles angle-bracketed Pandoc paths with parentheses in filenames, e.g.
  // ![Alt](</path/Roppo 6 Directions (Aikido).png>)
  return String(content || "").replace(
    /!\[([^\]]*)\]\((<[^>]+>|[^)\n]+)\)(\{[^}]*\})?/g,
    (match, alt, target, attrs = "") => replacer(match, alt, target, attrs)
  );
}

const missingImageEmbeds = new Set();

function resolveLocalImagePath(link, sourceFile) {
  let cleanLink = String(link || "")
    .trim()
    .replace(/^<|>$/g, "")
    .replace(/^['"]|['"]$/g, "");

  if (!cleanLink || /^(https?:|data:|mailto:|#)/i.test(cleanLink)) return null;

  cleanLink = decodeURIComponent(cleanLink);

  // Already absolute file paths are safe for Pandoc.
  if (/^(\/|[A-Za-z]:[\\/])/.test(cleanLink) && isImagePath(cleanLink)) {
    return cleanLink;
  }

  // Obsidian embeds may include a heading/block fragment. Pandoc only needs the file.
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

function convertObsidianImageEmbeds(content, sourceFile) {
  return String(content || "").replace(/!\[\[([^\]]+)\]\]/g, (match, target) => {
    const parsed = parseObsidianImageEmbed(target);
    const absPath = resolveLocalImagePath(parsed.link, sourceFile);

    if (!absPath) return match;

    const attrs = imageAttributes(parsed.width, parsed.height);
    return `![${parsed.alt}](${markdownImagePath(absPath)})${attrs}`;
  });
}

function convertLocalMarkdownImages(content, sourceFile) {
  return forEachMarkdownImage(content, (match, alt, target, attrs = "") => {
    const trimmedTarget = String(target || "").trim();

    if (/^(https?:|data:|mailto:|#)/i.test(trimmedTarget.replace(/^<|>$/g, ""))) {
      // Remote/data images are left alone here; the PDF-side graphicx safety cap
      // will constrain them without doing an additional whole-manuscript pass.
      return match;
    }

    const absPath = resolveLocalImagePath(trimmedTarget, sourceFile);
    if (!absPath) return match;

    return `![${alt}](${markdownImagePath(absPath)})${constrainImageAttributes(attrs)}`;
  });
}

function convertLocalImages(content, sourceFile) {
  return convertLocalMarkdownImages(
    convertObsidianImageEmbeds(content, sourceFile),
    sourceFile
  );
}

/* =========================
   MERMAID HANDLING FOR PDF/DOCX
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
  const absDir = app.vault.adapter.getFullPath(MERMAID_PDF_ASSET_FOLDER);

  return {
    absDir,
    mmdPath: path.join(absDir, `${baseName}.mmd`),
    imagePath: path.join(absDir, `${baseName}.${MERMAID_PDF_IMAGE_FORMAT}`)
  };
}

function renderMermaidDiagram(sourceText, sourceFile) {
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

    // Mermaid charts need to be legible on the printed page, so they are allowed
    // to use the full text width rather than the normal manuscript image cap.
    return `![Mermaid diagram](${markdownImagePath(paths.imagePath)}){width=100%}`;
  } catch (error) {
    const sourceLabel = sourceFile && sourceFile.path ? sourceFile.path : "unknown source";
    mermaidRenderWarnings.add(`${sourceLabel}: ${error && error.message ? error.message : String(error)}`);
    return "";
  }
}

function renderedMermaidImagePath(imageMarkdown) {
  const m = String(imageMarkdown || "").match(/!\[[^\]]*\]\(<([^>]+)>\)\{width=100%\}/);
  return m ? m[1] : "";
}

function mermaidCalloutImageMarker(imagePath) {
  return `[[CODEX_MERMAID_IMAGE:${String(imagePath || "")}]]`;
}

function convertQuotedMermaidBlocks(content, sourceFile) {
  return String(content || "").replace(
    /^>\s*```mermaid[^\n]*\n([\s\S]*?)^>\s*```\s*$/gim,
    (match, body) => {
      const diagram = String(body || "")
        .split(/\r?\n/)
        .map(line => line.replace(/^>\s?/, ""))
        .join("\n")
        .trim();

      const imageMarkdown = renderMermaidDiagram(diagram, sourceFile);
      if (!imageMarkdown) return match;

      const imagePath = renderedMermaidImagePath(imageMarkdown);
      if (!imagePath) return imageMarkdown;

      // Keep quoted Mermaid diagrams inside their parent callout. The marker is
      // converted to raw \includegraphics during callout body formatting, which
      // avoids Pandoc's normal figure caption behaviour.
      return `> ${mermaidCalloutImageMarker(imagePath)}\n`;
    }
  );
}

function convertPlainMermaidBlocks(content, sourceFile) {
  return String(content || "").replace(
    /```mermaid[^\n]*\n([\s\S]*?)```/gim,
    (match, body) => {
      const imageMarkdown = renderMermaidDiagram(body, sourceFile);
      return imageMarkdown || match;
    }
  );
}

function convertMermaidBlocks(content, sourceFile) {
  return convertPlainMermaidBlocks(
    convertQuotedMermaidBlocks(content, sourceFile),
    sourceFile
  );
}

function latexEscape(value) {
  return String(value || "")
    .replace(/\\/g, "\\textbackslash{}")
    .replace(/&/g, "\\&")
    .replace(/%/g, "\\%")
    .replace(/\$/g, "\\$")
    .replace(/#/g, "\\#")
    .replace(/_/g, "\\_")
    .replace(/{/g, "\\{")
    .replace(/}/g, "\\}")
    .replace(/~/g, "\\textasciitilde{}")
    .replace(/\^/g, "\\textasciicircum{}");
}

function bookmarkEscape(value) {
  // Hyperref bookmark titles still pass through TeX, so escape TeX specials.
  // A single unescaped & or $ in a chapter title can damage later outline entries.
  return String(value || "")
    .replace(/[\r\n]+/g, " ")
    .replace(/\\/g, "")
    .replace(/[{}]/g, "")
    .replace(/&/g, "\\&")
    .replace(/%/g, "\\%")
    .replace(/\$/g, "\\$")
    .replace(/#/g, "\\#")
    .replace(/_/g, " ")
    .replace(/~/g, " ")
    .replace(/\^/g, " ")
    .trim();
}

function latexContentsEscape(value) {
  return latexEscape(String(value || "").replace(/[\r\n]+/g, " ").trim());
}

function bookmarkAnchor(text) {
  const base = String(text || "")
    .normalize("NFKD")
    .replace(/[\u0300-\u036f]/g, "")
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, "-")
    .replace(/^-+|-+$/g, "");

  return base || "chapter";
}

function uniqueBookmarkAnchor(text) {
  const base = bookmarkAnchor(text);
  const count = usedBookmarkAnchors.get(base) || 0;
  usedBookmarkAnchors.set(base, count + 1);
  return count ? `${base}-${count + 1}` : base;
}

function closeDanglingFences(content, file) {
  const lines = String(content || "").split(/\r?\n/);
  let inFence = false;
  let fenceMarker = "```";

  for (const line of lines) {
    const m = line.match(/^\s*(```|~~~)/);
    if (!m) continue;

    if (!inFence) {
      inFence = true;
      fenceMarker = m[1];
    } else if (m[1] === fenceMarker) {
      inFence = false;
    }
  }

  if (!inFence) return content;

  const fileName = file && file.path ? file.path : "unknown note";
  fenceBalanceWarnings.add(fileName);
  console.warn(`Codex Press: closed dangling ${fenceMarker} fence at end of ${fileName}`);
  return String(content || "").trimEnd() + `\n${fenceMarker}\n`;
}

function neutraliseHeadingsInsideChapter(content) {
  return content.replace(/^#{1,6}\s+(.+)$/gm, (_, title) => {
    return `**${title.trim()}**`;
  });
}

async function ensureFolder(path) {
  if (!app.vault.getAbstractFileByPath(path)) {
    await app.vault.createFolder(path);
  }
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

function extractFrontmatter(content) {
  const match = content.match(/^---\s*\r?\n([\s\S]*?)\r?\n---/);
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
  return content.replace(/=this\.([A-Za-z0-9_]+)/g, (_, key) => {
    return stripWikiLinks(fm[key] ?? "");
  });
}

function stripLeadingAdminBlock(content) {
  const adminKeys = [
    "book", "title", "subtitle", "author", "status",
    "copyright", "version", "edition", "type", "series",
    "series_book", "rights",
    "publisher", "imprint",
    "isbn", "isbn_epub", "epub_isbn", "isbnEpub",
    "isbn_paper", "isbn_paperback", "paper_isbn", "paperback_isbn", "isbnPaper", "isbnPaperback",
    "isbn_hard", "isbn_hardback", "hard_isbn", "hardback_isbn", "isbnHard", "isbnHardback",
    "identifier", "identifier_epub", "epub_identifier", "identifierEpub",
    "identifier_paper", "identifier_paperback", "paper_identifier", "paperback_identifier", "identifierPaper", "identifierPaperback",
    "identifier_hard", "identifier_hardback", "hard_identifier", "hardback_identifier", "identifierHard", "identifierHardback",
    "compiler", "compiler_version"
  ];

  const normalisedAdminKeys = adminKeys.map(k => k.toLowerCase());

  const lines = content.split(/\r?\n/);
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

function formatEdition(version) {
  const v = clean(version, "");
  if (!v) return "";
  if (/^edition\b/i.test(v)) return v;
  return `Edition ${v}`;
}

function epubIsbnFromFrontmatter(fm) {
  return firstNonEmpty(
    fm.isbn_epub,
    fm.epub_isbn,
    fm.isbnEpub
  );
}

function paperIsbnFromFrontmatter(fm) {
  return firstNonEmpty(
    fm.isbn_paper,
    fm.paper_isbn,
    fm.isbnPaper,
    fm.isbn_paperback,
    fm.paperback_isbn,
    fm.isbnPaperback,
    fm.isbn
  );
}

function hardIsbnFromFrontmatter(fm) {
  return firstNonEmpty(
    fm.isbn_hard,
    fm.hard_isbn,
    fm.isbnHard,
    fm.isbn_hardback,
    fm.hardback_isbn,
    fm.isbnHardback
  );
}

function paperIdentifierFromFrontmatter(fm) {
  return firstNonEmpty(
    fm.identifier_paper,
    fm.paper_identifier,
    fm.identifierPaper,
    fm.identifier_paperback,
    fm.paperback_identifier,
    fm.identifierPaperback,
    fm.isbn_paper,
    fm.paper_isbn,
    fm.isbnPaper,
    fm.isbn_paperback,
    fm.paperback_isbn,
    fm.isbnPaperback,
    fm.identifier,
    fm.isbn
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

function frontMatterLine(label, value) {
  const v = clean(value, "");
  if (!v) return "";
  return `**${label}:** ${stripWikiLinks(v)}\n\n`;
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
const ROOT_MANUSCRIPTS_FOLDER = "Manuscripts";

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
   CALLOUT CONVERSION
========================= */

function calloutDisplayName(type) {
  return String(type || "note")
    .replace(/[-_]+/g, " ")
    .replace(/\b\w/g, ch => ch.toUpperCase());
}

function defaultCalloutTitle(type) {
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

  return titles[type] || calloutDisplayName(type);
}

function calloutEnvironment(type) {
  const envs = {
    "metadata": "metadatabox",
    "state": "statebox",
    "prime-log": "primelogbox",
    "janus": "janusbox",
    "janus-log": "januslogbox",
    "partition-log": "partitionbox",
    "divergent": "partitionbox",
    "annotation": "annotationbox"
  };

  return envs[type] || "metadatabox";
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

function latexEscapeCallout(text) {
  return String(text || "")
    .replace(/\\/g, "\\textbackslash{}")
    .replace(/&/g, "\\&")
    .replace(/%/g, "\\%")
    .replace(/\$/g, "\\$")
    .replace(/#/g, "\\#")
    .replace(/_/g, "\\_")
    .replace(/{/g, "\\{")
    .replace(/}/g, "\\}")
    .replace(/~/g, "\\textasciitilde{}")
    .replace(/\^/g, "\\textasciicircum{}")
    .replace(/\|/g, "\\textbar{}");
}

function addIdentifierBreaksForLatex(text) {
  return String(text || "")
    // lowerUpper: CommercialCorrection -> Commercial\allowbreak{}Correction
    .replace(/([a-z])([A-Z])/g, "$1\\allowbreak{}$2")
    // acronym + word: HTTPRequest -> HTTP\allowbreak{}Request
    .replace(/([A-Z])([A-Z][a-z])/g, "$1\\allowbreak{}$2")
    // letter/digit boundaries: PA01, Model2, etc.
    .replace(/([A-Za-z])(\d)/g, "$1\\allowbreak{}$2")
    .replace(/(\d)([A-Za-z])/g, "$1\\allowbreak{}$2");
}

function latexBreakableCalloutText(text) {
  const escaped = latexEscapeCallout(text)
    .replace(/\\_/g, "\\_\\allowbreak{}")
    .replace(/\//g, "/\\allowbreak{}")
    .replace(/-/g, "-\\allowbreak{}")
    .replace(/\./g, ".\\allowbreak{}")
    .replace(/:/g, ":\\allowbreak{}")
    .replace(/=/g, "=\\allowbreak{}")
    .replace(/,/g, ",\\allowbreak{}");

  return addIdentifierBreaksForLatex(escaped);
}

function calloutInlineMarkdown(text) {
  const source = stripWikiLinks(normaliseUnicodeSpacing(String(text || ""))).trimEnd();
  const tokens = [];

  function hold(value) {
    const key = `@@CODEX_CALLOUT_TOKEN_${tokens.length}@@`;
    tokens.push({ key, value });
    return key;
  }

  let working = source;

  // Preserve code spans before other inline markup.
  working = working.replace(/`([^`]+)`/g, (_, inner) =>
    hold(`\\texttt{${latexBreakableCalloutText(inner)}}`)
  );

  // Preserve common emphasis. Avoid underscore emphasis so snake_case tokens remain safe.
  working = working.replace(/\*\*([^*]+)\*\*/g, (_, inner) =>
    hold(`\\textbf{${calloutInlineMarkdown(inner)}}`)
  );

  working = working.replace(/(^|[^*])\*([^*\n]+)\*(?!\*)/g, (_, prefix, inner) =>
    `${prefix}${hold(`\\emph{${calloutInlineMarkdown(inner)}}`)}`
  );

  let escaped = latexBreakableCalloutText(working);

  for (const token of tokens) {
    const escapedKey = latexBreakableCalloutText(token.key);
    escaped = escaped.split(escapedKey).join(token.value);
  }

  return escaped;
}

function formatCalloutMarkdownLine(line) {
  const text = String(line || "").trim();

  const heading = text.match(/^(#{1,6})\s+(.+)$/);
  if (heading) {
    return `{\\bfseries ${calloutInlineMarkdown(heading[2])}}`;
  }

  const bullet = text.match(/^[-*]\s+(.+)$/);
  if (bullet) {
    return `\\hangindent=1.2em\\noindent\\textbullet{}\\hspace{0.45em}${calloutInlineMarkdown(bullet[1])}`;
  }

  const numbered = text.match(/^(\d+)[.)]\s+(.+)$/);
  if (numbered) {
    return `\\hangindent=1.6em\\noindent${latexEscapeCallout(numbered[1])}.\\hspace{0.45em}${calloutInlineMarkdown(numbered[2])}`;
  }

  return calloutInlineMarkdown(text);
}

function isMarkdownTableLine(line) {
  return /^\s*\|.*\|\s*$/.test(line);
}

function isMarkdownTableSeparator(line) {
  return /^\s*\|?\s*:?-{3,}:?\s*(\|\s*:?-{3,}:?\s*)+\|?\s*$/.test(line);
}

function normaliseTableRows(rows, colCount) {
  return rows.map(row => {
    const normal = row.slice(0, colCount);
    while (normal.length < colCount) normal.push("");
    return normal;
  });
}

function fixedWidthColumnSpec(colCount) {
  // Fixed p columns are less fragile than tabularx inside non-breakable tcolorboxes.
  // Widths intentionally total below \linewidth to leave room for inter-column glue.
  if (colCount === 1) {
    return ">{\\raggedright\\arraybackslash}p{0.94\\linewidth}";
  }

  if (colCount === 2) {
    return ">{\\raggedright\\arraybackslash}p{0.34\\linewidth}>{\\raggedright\\arraybackslash}p{0.56\\linewidth}";
  }

  if (colCount === 3) {
    return ">{\\raggedright\\arraybackslash}p{0.34\\linewidth}>{\\raggedright\\arraybackslash}p{0.24\\linewidth}>{\\raggedright\\arraybackslash}p{0.34\\linewidth}";
  }

  const width = Math.max(0.14, 0.88 / colCount).toFixed(3);
  return Array(colCount)
    .fill(`>{\\raggedright\\arraybackslash}p{${width}\\linewidth}`)
    .join("");
}

function latexSafeTableCell(cell) {
  // Allow LaTeX to break long underscore/hyphen/slash/dot-heavy ontology tokens,
  // while preserving common inline Markdown such as **bold** and `code`.
  return calloutInlineMarkdown(normaliseUnicodeSpacing(cell).trim());
}

function markdownTableToLatex(lines) {
  let rows = lines
    .filter(line => !isMarkdownTableSeparator(line))
    .map(line =>
      line
        .trim()
        .replace(/^\|/, "")
        .replace(/\|$/, "")
        .split("|")
        .map(cell => latexSafeTableCell(cell))
    );

  if (!rows.length) return "";

  const colCount = Math.max(...rows.map(row => row.length));
  rows = normaliseTableRows(rows, colCount);

  const spec = fixedWidthColumnSpec(colCount);

  let out = "{\\footnotesize\n";
  out += "\\RaggedRight\\sloppy\\emergencystretch=2em\n";
  out += "\\setlength{\\tabcolsep}{2pt}\n";
  out += "\\renewcommand{\\arraystretch}{1.16}\n";
  out += `\\begin{tabular}{@{}${spec}@{}}\n`;

  rows.forEach((row, index) => {
    out += row.join(" & ") + " \\\\\n";
    if (index === 0 && rows.length > 1) out += "\\hline\n";
  });

  out += "\\end{tabular}\n";
  out += "}";
  return out;
}

function formatPlainCalloutLines(lines) {
  const rendered = [];
  const paragraphBreak = "\\par\\smallskip";

  for (const line of lines) {
    const text = String(line || "").trim();

    if (!text) {
      if (rendered.length && rendered[rendered.length - 1] !== paragraphBreak) {
        rendered.push(paragraphBreak);
      }
      continue;
    }

    rendered.push(formatCalloutMarkdownLine(text));
  }

  while (rendered.length && rendered[0] === paragraphBreak) rendered.shift();
  while (rendered.length && rendered[rendered.length - 1] === paragraphBreak) rendered.pop();

  return rendered
    .map((line, index) => {
      if (line === paragraphBreak) return line;
      const next = rendered[index + 1];
      return next && next !== paragraphBreak ? `${line}\\\\` : line;
    })
    .join("\n");
}

function latexIndentForCode(line) {
  const expanded = String(line || "").replace(/\t/g, "  ");
  const m = expanded.match(/^(\s*)(.*)$/);
  const spaces = m ? m[1].length : 0;
  const rest = m ? m[2] : expanded;

  // LaTeX collapses ordinary leading spaces, so convert source indentation
  // into a small fixed horizontal skip. This keeps YAML hierarchy legible
  // without relying on fragile verbatim inside tcolorbox.
  const indent = spaces > 0 ? `\\hspace*{${(spaces * 0.45).toFixed(2)}em}` : "";
  const escaped = latexBreakableCalloutText(normaliseUnicodeSpacing(rest));

  return `${indent}${escaped || "\\strut"}`;
}

function formatCalloutFencedCode(lines, lang = "") {
  const cleaned = Array.from(lines || []);

  while (cleaned.length && cleaned[0].trim() === "") cleaned.shift();
  while (cleaned.length && cleaned[cleaned.length - 1].trim() === "") cleaned.pop();

  if (!cleaned.length) return "";

  const rendered = cleaned.map(line => latexIndentForCode(line)).join("\\\\\n");

  return `{\\ttfamily\\small\n${rendered}\n}`;
}

function isFenceLine(line) {
  return /^\s*(```|~~~)\s*([A-Za-z0-9_-]*)?\s*$/.test(String(line || ""));
}

function fenceLanguage(line) {
  const m = String(line || "").match(/^\s*(```|~~~)\s*([A-Za-z0-9_-]*)?\s*$/);
  return m && m[2] ? m[2] : "";
}

function isCalloutImageMarker(line) {
  return /^\s*\[\[CODEX_MERMAID_IMAGE:(.*)\]\]\s*$/.test(String(line || ""));
}

function calloutImageMarkerToLatex(line) {
  const m = String(line || "").match(/^\s*\[\[CODEX_MERMAID_IMAGE:(.*)\]\]\s*$/);
  const imagePath = m ? String(m[1] || "").replace(/\\/g, "/").replace(/}/g, "") : "";
  if (!imagePath) return "";

  return `\\begin{center}\n\\includegraphics[width=0.96\\linewidth,keepaspectratio]{\\detokenize{${imagePath}}}\n\\end{center}`;
}


function isCalloutMarkdownImageLine(line) {
  return /^\s*!\[([^\]]*)\]\((<[^>]+>|[^)\n]+)\)(\{[^}]*\})?\s*$/.test(String(line || ""));
}

function calloutMarkdownImageToLatex(line) {
  const m = String(line || "").match(/^\s*!\[([^\]]*)\]\((<[^>]+>|[^)\n]+)\)(\{[^}]*\})?\s*$/);
  if (!m) return "";

  const imagePath = String(m[2] || "")
    .replace(/^<|>$/g, "")
    .replace(/\\/g, "/")
    .replace(/}/g, "");

  if (!imagePath) return "";

  // Callout-contained Markdown images are usually diagrams/log artefacts.
  // Render them like quoted Mermaid images so they stay inside the callout
  // instead of being escaped as literal Markdown text.
  return `\\begin{center}\n\\includegraphics[width=0.96\\linewidth,keepaspectratio]{\\detokenize{${imagePath}}}\n\\end{center}`;
}

function formatCalloutBody(body) {
  const rawLines = body
    .split(/\r?\n/)
    .map(line => line.replace(/^>\s?/, ""))
    .map(line => line.trimEnd());

  const blocks = [];
  let current = [];
  let table = [];
  let code = [];
  let inFence = false;
  let currentFenceLang = "";

  function flushCurrent() {
    if (current.length) {
      blocks.push(formatPlainCalloutLines(current));
      current = [];
    }
  }

  function flushTable() {
    if (table.length) {
      blocks.push(markdownTableToLatex(table));
      table = [];
    }
  }

  function flushCode() {
    if (code.length) {
      blocks.push(formatCalloutFencedCode(code, currentFenceLang));
      code = [];
    }
    currentFenceLang = "";
  }

  for (const line of rawLines) {
    if (inFence) {
      if (isFenceLine(line)) {
        flushCode();
        inFence = false;
        continue;
      }

      code.push(line);
      continue;
    }

    if (isCalloutImageMarker(line)) {
      flushCurrent();
      flushTable();
      flushCode();
      blocks.push(calloutImageMarkerToLatex(line));
      continue;
    }

    if (isCalloutMarkdownImageLine(line)) {
      flushCurrent();
      flushTable();
      flushCode();
      blocks.push(calloutMarkdownImageToLatex(line));
      continue;
    }

    if (isFenceLine(line)) {
      flushCurrent();
      flushTable();
      inFence = true;
      currentFenceLang = fenceLanguage(line);
      code = [];
      continue;
    }

    if (isMarkdownTableLine(line)) {
      flushCurrent();
      table.push(line);
    } else {
      flushTable();
      current.push(line);
    }
  }

  flushCurrent();
  flushTable();
  flushCode();

  return blocks.filter(Boolean).join("\n\n");
}

function convertCallouts(content) {
  return content.replace(
    /^> \[!([A-Za-z0-9_-]+)\]\s*([^\n]*)\n((?:>.*(?:\n|$))*)/gim,
    (match, rawType, title, body) => {
      const type = String(rawType || "note").toLowerCase();
      const cleanTitle =
        title && title.trim()
          ? stripMarkdownInline(title)
          : defaultCalloutTitle(type);

      const cleanBody = formatCalloutBody(body);
      const env = calloutEnvironment(type);

      return `\n\n::: {=latex}\n\\begin{${env}}{${latexEscape(cleanTitle)}}\n${cleanBody}\n\\end{${env}}\n:::\n\n`;
    }
  );
}

/* =========================
   CHAT BLOCK CONVERSION
========================= */

function chatSide(line) {
  if (line.trim().startsWith(">")) return "rightchatbox";
  if (line.trim().startsWith("<")) return "leftchatbox";
  return "leftchatbox";
}

function cleanChatLine(line) {
  return String(line || "")
    .replace(/^\s*[><]\s*/, "")
    .replace(/\*\*(.*?)\*\*/g, "\\textbf{$1}")
    .replace(/`([^`]*)`/g, "\\texttt{$1}")
    .trim();
}

function latexEscapeChat(text) {
  return String(text || "")
    .replace(/\\textbf\{([^}]*)\}/g, "§§BOLD§§$1§§ENDBOLD§§")
    .replace(/\\texttt\{([^}]*)\}/g, "§§TT§§$1§§ENDTT§§")
    .replace(/\\/g, "\\textbackslash{}")
    .replace(/&/g, "\\&")
    .replace(/%/g, "\\%")
    .replace(/\$/g, "\\$")
    .replace(/#/g, "\\#")
    .replace(/_/g, "\\_")
    .replace(/{/g, "\\{")
    .replace(/}/g, "\\}")
    .replace(/~/g, "\\textasciitilde{}")
    .replace(/\^/g, "\\textasciicircum{}")
    .replace(/§§BOLD§§/g, "\\textbf{")
    .replace(/§§ENDBOLD§§/g, "}")
    .replace(/§§TT§§/g, "\\texttt{")
    .replace(/§§ENDTT§§/g, "}");
}

function convertChatBlocks(content) {
  return content.replace(/```chat\s*\n([\s\S]*?)```/gim, (match, body) => {
    const lines = body
      .split(/\r?\n/)
      .map(line => line.trim())
      .filter(Boolean);

    return lines.map(line => {
      const env = chatSide(line);
      const cleaned = cleanChatLine(line);

      return `\n\n::: {=latex}\n\\begin{${env}}\n${latexEscapeChat(cleaned)}\n\\end{${env}}\n:::\n\n`;
    }).join("");
  });
}

/* =========================
   CODE / TABLE CONVERSION
========================= */

function latexEscapeCode(text) {
  return String(text || "")
    .replace(/\\/g, "\\textbackslash{}")
    .replace(/&/g, "\\&")
    .replace(/%/g, "\\%")
    .replace(/\$/g, "\\$")
    .replace(/#/g, "\\#")
    .replace(/_/g, "\\_")
    .replace(/{/g, "\\{")
    .replace(/}/g, "\\}")
    .replace(/~/g, "\\textasciitilde{}")
    .replace(/\^/g, "\\textasciicircum{}");
}

function convertCodeBlocks(content) {
  return content.replace(/```(?!chat\b)([A-Za-z0-9_-]*)\s*\n([\s\S]*?)```/gim, (match, lang, body) => {
    const escaped = latexEscapeCode(body.trimEnd()).replace(/\n/g, "\\\\\n");

    return `\n\n::: {=latex}\n\\begin{codebox}\n${escaped}\n\\end{codebox}\n:::\n\n`;
  });
}

function convertWideMarkdownTables(content) {
  return content.replace(/((?:^\|.*\|\s*\n)+)/gm, (match) => {
    const lines = match.trim().split(/\r?\n/);
    if (lines.length < 2) return match;
    if (!isMarkdownTableSeparator(lines[1])) return match;

    let rows = lines
      .filter(line => !isMarkdownTableSeparator(line))
      .map(line =>
        line
          .trim()
          .replace(/^\|/, "")
          .replace(/\|$/, "")
          .split("|")
          .map(cell => latexSafeTableCell(cell))
      );

    const colCount = Math.max(...rows.map(row => row.length));
    if (colCount < 4) return match;

    rows = normaliseTableRows(rows, colCount);
    const spec = fixedWidthColumnSpec(colCount);

    let out = "\n\n::: {=latex}\n";
    out += "\\begin{center}\n";
    out += "{\\scriptsize\n";
    out += "\\setlength{\\tabcolsep}{2pt}\n";
    out += "\\renewcommand{\\arraystretch}{1.12}\n";
    out += `\\begin{tabular}{@{}${spec}@{}}\n`;

    rows.forEach((row, index) => {
      out += row.join(" & ") + " \\\\\n";
      if (index === 0) out += "\\hline\n";
    });

    out += "\\end{tabular}\n";
    out += "}\n";
    out += "\\end{center}\n";
    out += ":::\n\n";

    return out;
  });
}

/* =========================
   NOTE READING
========================= */

async function readNote(file) {
  if (!file) return { content: "", fm: {} };

  let raw = await app.vault.read(file);
  raw = normaliseUnicodeSpacing(raw)
    .replace(/^\uFEFF/, "")
    .replace(/\u200B/g, "");

  const fm = extractFrontmatter(raw);

  let content = raw.replace(/^---\s*\r?\n[\s\S]*?\r?\n---\s*\r?\n?/, "");
  content = closeDanglingFences(content, file);

  if (["trilogy", "book", "part"].includes((fm.type || "").toLowerCase())) {
    content = stripLeadingAdminBlock(content);
  }

  content = replaceMetadata(content, fm);
  content = convertLocalImages(content, file);
  content = convertMermaidBlocks(content, file);
  content = convertCallouts(content);
  content = convertChatBlocks(content);
  content = convertCodeBlocks(content);
  content = convertWideMarkdownTables(content);

  return { content, fm };
}

/* =========================
   STRUCTURE
========================= */

function titleFromMetadata(fm, fallback, level = "chapter") {
  if (level === "chapter") {
    if (fm.chapter && fm.title) return `${fm.chapter} — ${fm.title}`;
    if (fm.title) return fm.title;
    return fallback;
  }

  if (fm.title) return fm.title;
  return fallback;
}

async function folderTitle(folder) {
  const note = getFolderNote(folder);
  const { fm } = await readNote(note);
  return titleFromMetadata(fm, folder.name, "folder");
}

async function fileTitle(file) {
  const { fm } = await readNote(file);
  return titleFromMetadata(fm, file.basename, "chapter");
}

async function folderType(folder) {
  const note = getFolderNote(folder);
  const { fm } = await readNote(note);
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

async function logCompileTree(books) {
  const lines = [];

  for (const book of books) {
    lines.push(`BOOK: ${book.path} -> ${await folderTitle(book)}`);

    for (const part of await getPartFolders(book)) {
      lines.push(`  PART: ${part.path} -> ${await folderTitle(part)}`);

      for (const chapter of getChapterFiles(part)) {
        lines.push(`    CHAPTER: ${chapter.path} -> ${await fileTitle(chapter)}`);
      }
    }
  }

  console.log("Codex Press compile tree:\n" + lines.join("\n"));
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

/* =========================
   TITLE / COPYRIGHT
========================= */

function latexTextLine(value, command = "normalsize") {
  const v = clean(value, "");
  if (!v) return "";
  return `{\\${command} ${latexEscape(stripWikiLinks(v))}\\par}`;
}

function latexFrontMatterLine(label, value) {
  const v = clean(value, "");
  if (!v) return "";
  return `\\noindent\\textbf{${latexEscape(label)}:} ${latexEscape(stripWikiLinks(v))}\\par\n\\vspace{0.35em}\n`;
}

function buildTitlePage(fm) {
  const title = clean(fm.title, selectedProject.label);
  const subtitle = clean(fm.subtitle, "");
  const author = clean(fm.author, "");
  const version = clean(fm.version, "");
  const date = clean(fm.date, compileDate);
  const status = clean(fm.status, "");
  const publisher = publisherFromFrontmatter(fm);
  const imprint = imprintFromFrontmatter(fm);

  const lines = [];

  lines.push("\\thispagestyle{empty}");
  lines.push("\\vspace*{0.18\\textheight}");
  lines.push("\\begin{center}");
  lines.push(latexTextLine(title, "Huge\\bfseries"));
  if (subtitle) {
    lines.push("\\vspace{1.1em}");
    lines.push(latexTextLine(subtitle, "Large"));
  }
  if (author) {
    lines.push("\\vspace{2.2em}");
    lines.push(latexTextLine(author, "large\\bfseries"));
  }

  lines.push("\\vfill");

  if (mode === "publish") {
    if (version) lines.push(latexTextLine(formatEdition(version), "normalsize"));
    if (date) lines.push(latexTextLine(date, "normalsize"));
    if (publisher) lines.push(latexTextLine(`Published by ${stripWikiLinks(publisher)}`, "normalsize"));
    if (imprint && imprint !== publisher) lines.push(latexTextLine(`Imprint: ${stripWikiLinks(imprint)}`, "normalsize"));
  } else {
    lines.push(latexTextLine("Working Draft", "normalsize"));
    if (date) lines.push(latexTextLine(date, "normalsize"));
    if (status) lines.push(latexTextLine(`Status: ${stripWikiLinks(status)}`, "normalsize"));
    if (publisher) lines.push(latexTextLine(`Publisher: ${stripWikiLinks(publisher)}`, "normalsize"));
    if (imprint && imprint !== publisher) lines.push(latexTextLine(`Imprint: ${stripWikiLinks(imprint)}`, "normalsize"));
  }

  lines.push("\\end{center}");

  // Do not use Markdown headings on title pages: Pandoc turns them into
  // PDF outline entries, which pollutes the navigation sidebar.
  return rawLatex(lines.filter(Boolean).join("\n"));
}

function buildCopyrightPage(fm) {
  const author = clean(fm.author, "");
  const copyright = clean(fm.copyright, "");
  const rights = clean(fm.rights, "All rights reserved.");
  const year = clean(fm.year, window.moment().format("YYYY"));
  const version = clean(fm.version, "");
  const publisher = publisherFromFrontmatter(fm);
  const imprint = imprintFromFrontmatter(fm);
  const isbnEpub = epubIsbnFromFrontmatter(fm);
  const isbnPaper = paperIsbnFromFrontmatter(fm);
  const isbnHard = hardIsbnFromFrontmatter(fm);

  const lines = [];

  lines.push("\\thispagestyle{empty}");
  lines.push("{\\Large\\bfseries Copyright\\par}");
  lines.push("\\vspace{1em}");

  if (copyright) {
    lines.push(`\\noindent ${latexEscape(stripWikiLinks(copyright))}\\par`);
  } else if (author) {
    lines.push(`\\noindent Copyright © ${latexEscape(year)} ${latexEscape(stripWikiLinks(author))}.\\par`);
  }

  lines.push("\\vspace{0.8em}");
  lines.push(`\\noindent ${latexEscape(stripWikiLinks(rights))}\\par`);
  lines.push("\\vspace{0.8em}");

  if (publisher) lines.push(`\\noindent Published by ${latexEscape(stripWikiLinks(publisher))}.\\par`);
  if (imprint && imprint !== publisher) lines.push(`\\noindent Imprint: ${latexEscape(stripWikiLinks(imprint))}.\\par`);

  if (version) lines.push(latexFrontMatterLine("Version", formatEdition(version)));
  lines.push(latexFrontMatterLine("EPUB ISBN", isbnEpub));
  lines.push(latexFrontMatterLine("Paperback ISBN", isbnPaper));
  lines.push(latexFrontMatterLine("Hardback ISBN", isbnHard));

  // Do not use Markdown headings here: Copyright should be visible in the book
  // but should not become the parent of the whole PDF outline.
  return rawLatex(lines.filter(Boolean).join("\n"));
}

/* =========================
   LATEX HEADER
========================= */

function buildPandocHeader(fm) {
  const title = latexEscape(clean(fm.title, selectedProject.label));
  const author = latexEscape(clean(fm.author, ""));
  const subject = latexEscape(clean(fm.subtitle, ""));
  const publisher = latexEscape(publisherFromFrontmatter(fm));
  const imprint = latexEscape(imprintFromFrontmatter(fm));
  const epubIsbn = latexEscape(epubIsbnFromFrontmatter(fm));
  const paperIdentifier = latexEscape(paperIdentifierFromFrontmatter(fm));
  const hardIsbn = latexEscape(hardIsbnFromFrontmatter(fm));

  return `
\\usepackage{microtype}
\\usepackage{tcolorbox}
\\usepackage{graphicx}
\\tcbuselibrary{breakable,skins}
\\usepackage[normalem]{ulem}
\\usepackage{enumitem}
\\usepackage{amssymb}
\\usepackage{fancyhdr}
\\usepackage{hyperref}
\\usepackage{xcolor}
\\usepackage{array}
\\usepackage{tabularx}
\\usepackage{ragged2e}

\\hypersetup{
  pdftitle={${title}},
  pdfauthor={${author}},
  pdfsubject={${subject}},
  pdfkeywords={${paperIdentifier}},
  pdfinfo={
    Publisher={${publisher}},
    Imprint={${imprint}},
    ISBNEPUB={${epubIsbn}},
    ISBNPaperback={${paperIdentifier}},
    ISBNHardback={${hardIsbn}}
  }
}

\\setlength{\\parindent}{0pt}
\\setlength{\\parskip}{0.52em}
\\raggedbottom
\\renewcommand{\\arraystretch}{1.15}

\\clubpenalty=10000
\\widowpenalty=10000
\\displaywidowpenalty=10000

\\pagestyle{fancy}
\\fancyhf{}
\\fancyhead[LE]{\\small\\leftmark}
\\fancyhead[RO]{}
\\fancyfoot[LE,RO]{\\thepage}
\\renewcommand{\\headrulewidth}{0.3pt}

\\fancypagestyle{plain}{
  \\fancyhf{}
  \\fancyfoot[LE,RO]{\\thepage}
  \\renewcommand{\\headrulewidth}{0pt}
}

\\newcommand{\\bookmarktitle}[1]{\\markboth{#1}{#1}}

% ---------------------------------------------------------------------------
% v1.1.8 CALLOUT BOXES
% ---------------------------------------------------------------------------
% These manuscript callouts are intentionally NOT breakable.
% LaTeX should move the entire callout to the next page rather than splitting it.
% Keep \tcbuselibrary{breakable,skins} loaded because chat/code boxes below
% still use the breakable key.
% If one callout is taller than a page, split it in the source manuscript.
% ---------------------------------------------------------------------------

\\newtcolorbox{metadatabox}[1]{
  enhanced,
  colback=gray!2,
  colframe=gray!30,
  coltitle=black,
  fonttitle=\\bfseries\\small,
  fontupper=\\small,
  before upper={\\RaggedRight},
  title={#1},
  boxrule=0.4pt,
  arc=2mm,
  left=2mm,
  right=2mm,
  top=1mm,
  bottom=1mm,
  before skip=0.55em,
  after skip=0.55em
}

\\newtcolorbox{statebox}[1]{
  enhanced,
  colback=gray!4,
  colframe=gray!45,
  coltitle=black,
  fonttitle=\\bfseries\\small\\sffamily,
  fontupper=\\small\\sffamily,
  before upper={\\RaggedRight},
  title={#1},
  boxrule=0.45pt,
  arc=2mm,
  left=2mm,
  right=2mm,
  top=1mm,
  bottom=1mm,
  before skip=0.55em,
  after skip=0.55em
}

\\newtcolorbox{primelogbox}[1]{
  enhanced,
  colback=gray!3,
  colframe=black!70,
  coltitle=black,
  colupper=black,
  fonttitle=\\bfseries\\small\\ttfamily,
  fontupper=\\small\\ttfamily,
  before upper={\\RaggedRight\\sloppy\\emergencystretch=3em},
  title={#1},
  boxrule=0.5pt,
  arc=1mm,
  left=2mm,
  right=2mm,
  top=1mm,
  bottom=1mm,
  before skip=0.55em,
  after skip=0.55em
}

\\newtcolorbox{janusbox}[1]{
  enhanced,
  colback=gray!8,
  colframe=gray!60,
  coltitle=black,
  fonttitle=\\bfseries\\small\\sffamily,
  fontupper=\\small\\sffamily,
  before upper={\\sloppy\\emergencystretch=2em},
  title={#1},
  boxrule=0.5pt,
  arc=1mm,
  left=2mm,
  right=2mm,
  top=1mm,
  bottom=1mm,
  before skip=0.55em,
  after skip=0.55em
}

\\newtcolorbox{januslogbox}[1]{
  enhanced,
  colback=gray!8,
  colframe=black!65,
  coltitle=black,
  fonttitle=\\bfseries\\small\\ttfamily,
  fontupper=\\small\\ttfamily,
  before upper={\\RaggedRight\\sloppy\\emergencystretch=3em},
  title={#1},
  boxrule=0.5pt,
  arc=1mm,
  left=2mm,
  right=2mm,
  top=1mm,
  bottom=1mm,
  before skip=0.55em,
  after skip=0.55em
}

\\newtcolorbox{partitionbox}[1]{
  enhanced,
  colback=green!5,
  colframe=green!35!black,
  coltitle=black,
  fonttitle=\\bfseries\\small,
  fontupper=\\small,
  before upper={\\RaggedRight\\sloppy\\emergencystretch=3em},
  title={#1},
  boxrule=0.5pt,
  arc=2mm,
  left=2mm,
  right=2mm,
  top=1mm,
  bottom=1mm,
  before skip=0.55em,
  after skip=0.55em
}

\\newtcolorbox{annotationbox}[1]{
  enhanced,
  colback=white,
  colframe=gray!35,
  coltitle=black,
  fonttitle=\\bfseries\\small,
  fontupper=\\normalsize,
  before upper={\\RaggedRight},
  title={#1},
  boxrule=0.4pt,
  arc=1mm,
  left=3mm,
  right=3mm,
  top=1.5mm,
  bottom=1.5mm,
  before skip=0.55em,
  after skip=0.55em
}

\\newtcolorbox{leftchatbox}{
  enhanced,
  breakable,
  colback=gray!6,
  colframe=gray!35,
  boxrule=0.4pt,
  arc=3mm,
  width=0.82\\textwidth,
  left=2mm,
  right=2mm,
  top=1mm,
  bottom=1mm,
  boxsep=0.8mm,
  before skip=0.25em,
  after skip=0.25em,
  halign=left
}

\\newtcolorbox{rightchatbox}{
  enhanced,
  breakable,
  colback=gray!12,
  colframe=gray!45,
  boxrule=0.4pt,
  arc=3mm,
  width=0.82\\textwidth,
  left=2mm,
  right=2mm,
  top=1mm,
  bottom=1mm,
  boxsep=0.8mm,
  before skip=0.25em,
  after skip=0.25em,
  flush right
}

\\newtcolorbox{codebox}{
  enhanced,
  breakable,
  colback=gray!4,
  colframe=gray!25,
  boxrule=0.3pt,
  arc=1mm,
  left=2mm,
  right=2mm,
  top=1mm,
  bottom=1mm,
  fontupper=\\small\\ttfamily,
  before skip=0.7em,
  after skip=0.7em
}
`;
}

/* =========================
   BUILD OUTPUT
========================= */

const projectNote = getFolderNote(PROJECT_ROOT);
const { content: projectContent, fm: projectFm } = await readNote(projectNote);

const books = await getBookFolders(PROJECT_ROOT);
await logCompileTree(books);
const singleBookEdition = books.length === 1;
const sharedFiles = getSharedFiles();

let output = "";

output += buildTitlePage(projectFm);
output += rawLatex(`\\thispagestyle{empty}`);
output += pageBreak();

if (mode === "publish") {
  output += buildCopyrightPage(projectFm);
  output += rawLatex(`\\thispagestyle{empty}`);
  output += pageBreak();
}

if (projectContent.trim() && projectKind === "trilogy") {
  output += projectContent.trim() + "\n\n";
  output += pageBreak();
}

/* ===== CONTENTS ===== */

output += rawLatex(`\\phantomsection`);
output += rawLatex(`\\pdfbookmark[0]{Contents}{contents}`);
output += rawLatex(`\\begin{center}\\Large\\textbf{Contents}\\end{center}`);
output += "\n\n";

if (singleBookEdition) {
  const book = books[0];

  for (const part of await getPartFolders(book)) {
    output += `- ${await folderTitle(part)}
`;

    for (const chapter of getChapterFiles(part)) {
      output += `  - ${await fileTitle(chapter)}
`;
    }
  }

  if (sharedFiles.length) {
    for (const sharedFile of sharedFiles) {
      output += `- ${await fileTitle(sharedFile)}
`;
    }
  }

  output += `
`;
} else {
  for (const book of books) {
    output += `**${await folderTitle(book)}**

`;

    for (const part of await getPartFolders(book)) {
      output += `- ${await folderTitle(part)}
`;

      for (const chapter of getChapterFiles(part)) {
        output += `  - ${await fileTitle(chapter)}
`;
      }
    }

    output += `
`;
  }

  if (sharedFiles.length) {
    output += `**Back matter**

`;

    for (const sharedFile of sharedFiles) {
      output += `- ${await fileTitle(sharedFile)}
`;
    }

    output += `
`;
  }
}

output += pageBreak();

/* ===== CONTENT ===== */

for (const book of books) {
  const { content: bookContent, fm: bookFm } = await readNote(getFolderNote(book));
  const bookTitle = titleFromMetadata(bookFm, book.name, "folder");

  if (projectKind === "trilogy" && !singleBookEdition) {
    if (mode === "publish") output += rectoBreak();

    output += rawLatex(`\\bookmarktitle{${latexEscape(bookTitle)}}`);
    output += `# ${bookTitle}\n\n`;

    if (bookContent.trim()) {
      output += bookContent.trim() + "\n\n";
      output += pageBreak();
    }
  } else {
    output += rawLatex(`\\bookmarktitle{${latexEscape(bookTitle)}}`);

    if (bookContent.trim()) {
      if (mode === "publish") output += rectoBreak();

      const introAnchor = uniqueBookmarkAnchor(`${bookTitle} Introduction`);
      output += rawLatex(`\\phantomsection`);
      output += rawLatex(`\\bookmarktitle{Introduction}`);
      output += rawLatex(`\\pdfbookmark[0]{Introduction}{${introAnchor}}`);
      output += rawLatex(`\\thispagestyle{plain}`);
      output += rawLatex(`\\vspace*{0.18\\textheight}`);
      output += rawLatex(`\\begin{center}\\Large\\textbf{\\textsc{Introduction}}\\end{center}`);
      output += rawLatex(`\\vspace{1em}`);

      output += bookContent.trim() + "\n\n";
      output += pageBreak();
    }
  }

  for (const part of await getPartFolders(book)) {
    const { content: partContent, fm: partFm } = await readNote(getFolderNote(part));
    const partTitle = titleFromMetadata(partFm, part.name, "folder");

    if (mode === "publish") output += rectoBreak();

    const partAnchor = uniqueBookmarkAnchor(partTitle);
    const partBookmarkTitle = bookmarkEscape(partTitle);
    const partLatexTitle = latexContentsEscape(partTitle);
    const partBookmarkLevel = projectKind === "trilogy" && !singleBookEdition ? 1 : 0;

    output += rawLatex(`\\phantomsection`);
    output += rawLatex(`\\bookmarktitle{${partLatexTitle}}`);
    output += rawLatex(`\\pdfbookmark[${partBookmarkLevel}]{${partBookmarkTitle}}{${partAnchor}}`);
    output += rawLatex(`\\thispagestyle{plain}`);
    output += rawLatex(`\\vspace*{0.18\\textheight}`);
    output += rawLatex(`\\begin{center}\\Large\\textbf{\\textsc{${partLatexTitle}}}\\end{center}`);
    output += rawLatex(`\\vspace{1em}`);

    if (partContent.trim()) {
      output += partContent.trim() + "\n\n";
      output += pageBreak();
    }

    for (const chapter of getChapterFiles(part)) {
      const { content, fm } = await readNote(chapter);
      const chapterTitle = titleFromMetadata(fm, chapter.basename, "chapter");

      if (mode === "publish") output += rectoBreak();

      const anchor = uniqueBookmarkAnchor(chapterTitle);
      const chapterBookmarkTitle = bookmarkEscape(chapterTitle);
      const chapterLatexTitle = latexContentsEscape(chapterTitle);
      const chapterBookmarkLevel = projectKind === "trilogy" && !singleBookEdition ? 2 : 1;

      output += rawLatex(`\\phantomsection`);
      output += rawLatex(`\\bookmarktitle{${chapterLatexTitle}}`);
      output += rawLatex(`\\pdfbookmark[${chapterBookmarkLevel}]{${chapterBookmarkTitle}}{${anchor}}`);
      output += rawLatex(`\\thispagestyle{plain}`);
      output += rawLatex(`\\vspace*{0.22\\textheight}`);
      output += rawLatex(`\\begin{center}\\Large\\textbf{\\textsc{${chapterLatexTitle}}}\\end{center}`);
      output += rawLatex(`\\vspace{1em}`);

      if (content.trim()) {
        output += neutraliseHeadingsInsideChapter(content.trim()) + "\n\n";
      }

      if (mode === "publish") {
        output += pageBreak();
      }
    }
  }
}

if (sharedFiles.length) {
  if (mode === "publish") output += rectoBreak();

  const backMatterAnchor = uniqueBookmarkAnchor("Back matter");
  output += rawLatex(`\\phantomsection`);
  output += rawLatex(`\\bookmarktitle{Back matter}`);
  output += rawLatex(`\\pdfbookmark[0]{Back matter}{${backMatterAnchor}}`);
  output += rawLatex(`\\thispagestyle{plain}`);
  output += rawLatex(`\\vspace*{0.18\\textheight}`);
  output += rawLatex(`\\begin{center}\\Large\\textbf{\\textsc{Back matter}}\\end{center}`);
  output += rawLatex(`\\vspace{1em}`);
  output += pageBreak();

  for (const sharedFile of sharedFiles) {
    const { content, fm } = await readNote(sharedFile);
    const sharedTitle = titleFromMetadata(fm, sharedFile.basename, "chapter");

    if (mode === "publish") output += rectoBreak();

    const sharedAnchor = uniqueBookmarkAnchor(sharedTitle);
    const sharedBookmarkTitle = bookmarkEscape(sharedTitle);
    const sharedLatexTitle = latexContentsEscape(sharedTitle);

    output += rawLatex(`\\phantomsection`);
    output += rawLatex(`\\bookmarktitle{${sharedLatexTitle}}`);
    output += rawLatex(`\\pdfbookmark[1]{${sharedBookmarkTitle}}{${sharedAnchor}}`);
    output += rawLatex(`\\thispagestyle{plain}`);
    output += rawLatex(`\\vspace*{0.18\\textheight}`);
    output += rawLatex(`\\begin{center}\\Large\\textbf{\\textsc{${sharedLatexTitle}}}\\end{center}`);
    output += rawLatex(`\\vspace{1em}`);

    if (content.trim()) {
      output += neutraliseHeadingsInsideChapter(content.trim()) + "\n\n";
    }

    if (mode === "publish") {
      output += pageBreak();
    }
  }
}

/* =========================
   WRITE OUTPUT
========================= */

const manuscriptsFolder = ROOT_MANUSCRIPTS_FOLDER;
await ensureFolder(manuscriptsFolder);

const titleSafe = clean(projectFm.title, selectedProject.label)
  .replace(/[\\/:*?"<>|]/g, "")
  .trim();
const modeLabel = mode === "publish" ? "Publish" : "Draft";
const fileName = `${titleSafe} - ${compileDate} (${modeLabel})`;

const tempPath = `${manuscriptsFolder}/${fileName}.md`;

await writeOrReplace(tempPath, output);

/* =========================
   EXPORT
========================= */

if (exportType !== "none") {
  const outputBase = `${manuscriptsFolder}/${fileName}`;

  let pdfMd = output
    .replace(/<!-- RECTOBREAK -->/g, "\\cleardoublepage")
    .replace(/<!-- PAGEBREAK -->/g, "\\newpage")
    .replace(/<!-- LATEX:([\s\S]*?) -->/g, "$1")
    .replace(/::: \{=latex\}\n([\s\S]*?)\n:::/g, "$1")
    .replace(/↔/g, "\\ensuremath{\\leftrightarrow}")
    .replace(/→/g, "\\ensuremath{\\rightarrow}")
    .replace(/←/g, "\\ensuremath{\\leftarrow}")
    .replace(/^\s*\*\*\*\s*$/gm, "\\begin{center}\\vspace{0.8em}• • •\\vspace{0.8em}\\end{center}");

  let docxMd = output
    .replace(/<!-- RECTOBREAK -->/g, "<div style='page-break-after: always;'></div>")
    .replace(/<!-- PAGEBREAK -->/g, "<div style='page-break-after: always;'></div>")
    .replace(/<!-- LATEX:[\s\S]*? -->/g, "")
    .replace(/::: \{=latex\}\n[\s\S]*?\n:::/g, "")
    .replace(/^\s*\*\*\*\s*$/gm, "<div style='text-align:center;'>• • •</div>");

  const pdfTempPath = `${manuscriptsFolder}/.${fileName}.pdf-export.md`;
  const docxTempPath = `${manuscriptsFolder}/.${fileName}.docx-export.md`;
  const headerPath = `${manuscriptsFolder}/.${fileName}.pdf-header.tex`;

  await writeOrReplace(pdfTempPath, pdfMd);
  await writeOrReplace(docxTempPath, docxMd);
  await writeOrReplace(headerPath, buildPandocHeader(projectFm));

  const absPdfMdPath = app.vault.adapter.getFullPath(pdfTempPath);
  const absDocxMdPath = app.vault.adapter.getFullPath(docxTempPath);
  const absHeaderPath = app.vault.adapter.getFullPath(headerPath);
  const absOutputBase = app.vault.adapter.getFullPath(outputBase);

  if (missingImageEmbeds.size) {
    console.warn("Codex Press could not resolve these image embeds:", Array.from(missingImageEmbeds));
    new Notice(`Codex Press: ${missingImageEmbeds.size} image embed(s) could not be resolved. See console.`);
  }

  if (mermaidRenderWarnings.size) {
    console.warn(
      "Codex Press could not render these Mermaid diagram(s):",
      Array.from(mermaidRenderWarnings)
    );

    if (mermaidCliUnavailable) {
      new Notice("Codex Press: Mermaid CLI/mmdc unavailable or failed. Mermaid blocks left as code. See console.");
    } else {
      new Notice(`Codex Press: ${mermaidRenderWarnings.size} Mermaid diagram(s) could not be rendered. See console.`);
    }
  }

  let cmd = "";

  if (exportType === "pdf" || exportType === "both") {
    cmd += `pandoc --from=${PANDOC_FROM_PDF} "${absPdfMdPath}" -o "${absOutputBase}.pdf" --standalone --pdf-engine=xelatex --pdf-engine-opt=-halt-on-error --pdf-engine-opt=-interaction=nonstopmode --wrap=preserve -V documentclass=scrbook -V classoption=twoside,openright -V fontsize=10pt -V geometry:paperwidth=5.5in,paperheight=8.5in,inner=0.9in,outer=0.7in,top=0.78in,bottom=0.82in -V secnumdepth=0 -V hyphenpenalty=5000 -V exhyphenpenalty=5000 --top-level-division=chapter --include-in-header "${absHeaderPath}"\n`;
  }

  if (exportType === "docx" || exportType === "both") {
    cmd += `pandoc --from=${PANDOC_FROM_DOCX} "${absDocxMdPath}" -o "${absOutputBase}.docx"\n`;
  }

  if (fenceBalanceWarnings.size) {
    console.warn("Codex Press closed dangling code fence(s) in:", Array.from(fenceBalanceWarnings));
    new Notice(`Codex Press: closed ${fenceBalanceWarnings.size} dangling code fence(s). Check console.`);
  }

  console.log("Running export command:");
  console.log(cmd);

  new Notice("Running Pandoc export...");

  require("child_process").exec(cmd, (error, stdout, stderr) => {
    if (error) {
      console.error("Pandoc export failed:", error);
      console.error(stderr);
      new Notice("Pandoc export failed. Check console.");
      return;
    }

    if (stdout) console.log(stdout);
    if (stderr) console.warn(stderr);

    new Notice("Codex Press export complete.");
  });
}

new Notice("Codex Press compile complete");
-%>
