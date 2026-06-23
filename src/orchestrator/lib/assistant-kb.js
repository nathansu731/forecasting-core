const fs = require("fs");
const path = require("path");

const KB_ROOT = path.join(__dirname, "..", "copilot-kb");

let cachedDocs = null;

const tokenize = (value) =>
  String(value || "")
    .toLowerCase()
    .split(/[^a-z0-9]+/)
    .map((token) => token.trim())
    .filter((token) => token.length >= 2);

const unique = (values) => Array.from(new Set(values));

const safeReadDir = (dirPath) => {
  try {
    return fs.readdirSync(dirPath, { withFileTypes: true });
  } catch {
    return [];
  }
};

const walkMarkdownFiles = (dirPath) => {
  const entries = safeReadDir(dirPath);
  const files = [];
  entries.forEach((entry) => {
    const fullPath = path.join(dirPath, entry.name);
    if (entry.isDirectory()) {
      files.push(...walkMarkdownFiles(fullPath));
      return;
    }
    if (entry.isFile() && entry.name.endsWith(".md")) {
      files.push(fullPath);
    }
  });
  return files;
};

const normalizeWhitespace = (value) => String(value || "").replace(/\s+/g, " ").trim();

const chunkMarkdown = (rawText, relativePath) => {
  const text = String(rawText || "").replace(/\r/g, "");
  const lines = text.split("\n");
  const sections = [];
  let documentTitle = path.basename(relativePath, ".md");
  let currentTitle = "";
  let currentLines = [];
  let currentHeadingLevel = 2;

  const flush = () => {
    const body = normalizeWhitespace(currentLines.join(" "));
    if (!body) return;
    const heading = currentTitle || documentTitle;
    sections.push({
      id: `${relativePath}#${sections.length + 1}`,
      title: heading,
      level: currentHeadingLevel,
      source: relativePath,
      text: body,
      terms: unique(tokenize(`${relativePath} ${heading} ${body}`)),
    });
  };

  lines.forEach((line) => {
    const headingMatch = line.match(/^(#{1,3})\s+(.*)$/);
    if (headingMatch) {
      const level = headingMatch[1].length;
      const headingText = normalizeWhitespace(headingMatch[2]);
      if (level === 1 && headingText) {
        documentTitle = headingText;
      }
      if (level >= 2) {
        flush();
        currentTitle = headingText || documentTitle;
        currentHeadingLevel = level;
        currentLines = [];
        return;
      }
    }
    currentLines.push(line);
  });

  flush();

  if (!sections.length) {
    const body = normalizeWhitespace(text);
    if (body) {
      sections.push({
        id: `${relativePath}#1`,
        title: documentTitle,
        level: 1,
        source: relativePath,
        text: body,
        terms: unique(tokenize(`${relativePath} ${documentTitle} ${body}`)),
      });
    }
  }

  return sections;
};

const loadKnowledgeBase = () => {
  if (cachedDocs) return cachedDocs;
  const markdownFiles = walkMarkdownFiles(KB_ROOT);
  const docs = markdownFiles.flatMap((filePath) => {
    try {
      const raw = fs.readFileSync(filePath, "utf8");
      const relativePath = path.relative(KB_ROOT, filePath).replace(/\\/g, "/");
      return chunkMarkdown(raw, relativePath);
    } catch {
      return [];
    }
  });
  cachedDocs = docs;
  return docs;
};

const buildRouteHints = (pageId, route) =>
  unique(
    [
      pageId,
      route,
      ...(route ? route.split("/").filter(Boolean) : []),
      pageId === "forecasting-summary" ? "summary" : null,
      pageId === "forecast-navigator" ? "navigator" : null,
      pageId === "forecast-editor" ? "editor" : null,
    ].filter(Boolean)
  );

const scoreDoc = (doc, queryTerms) => {
  let score = 0;
  const termSet = new Set(doc.terms);
  queryTerms.forEach((term) => {
    if (termSet.has(term)) score += 3;
    else if (doc.text.includes(term)) score += 1;
  });
  if (doc.source.includes("pages/")) score += 0.3;
  if (doc.level <= 2) score += 0.2;
  return score;
};

const searchKnowledgeBase = ({ command, pageId, route, limit = 4 }) => {
  const docs = loadKnowledgeBase();
  const queryTerms = unique([...tokenize(command), ...buildRouteHints(pageId, route)]);
  return docs
    .map((doc) => ({ doc, score: scoreDoc(doc, queryTerms) }))
    .filter((entry) => entry.score > 0)
    .sort((left, right) => right.score - left.score)
    .slice(0, limit)
    .map(({ doc, score }) => ({
      id: doc.id,
      title: doc.title,
      source: doc.source,
      text: doc.text,
      score,
    }));
};

module.exports = {
  searchKnowledgeBase,
};
