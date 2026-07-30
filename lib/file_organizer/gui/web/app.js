/* File Organizer — graphical interface.
 *
 * Plain browser JavaScript, no build step and no libraries. Two rules matter
 * for safety and are followed everywhere below:
 *
 *   1. Text that comes from the filesystem (names, metadata, previews) is only
 *      ever put on the page as text — never as markup — so a file cannot
 *      inject anything into this page.
 *   2. Files are referred to by the opaque ids the program handed out, never by
 *      path, so the page cannot ask about a file outside the current folder.
 */

"use strict";

const TOKEN = new URLSearchParams(window.location.search).get("t") || "";
const SVG_NS = "http://www.w3.org/2000/svg";
const THEME_KEY = "file-organizer.theme";

const CATEGORIES = {
  photo: { label: "Images", icon: "i-image" },
  audio: { label: "Audio", icon: "i-audio" },
  video: { label: "Video", icon: "i-video" },
  document: { label: "Documents", icon: "i-doc" },
  archive: { label: "Archives", icon: "i-archive" },
  executable: { label: "Executables", icon: "i-code" },
  text: { label: "Text", icon: "i-text" },
  data: { label: "Data", icon: "i-data" },
  binary: { label: "Binary", icon: "i-binary" },
  link: { label: "Links", icon: "i-link" },
  other: { label: "Other", icon: "i-other" },
};

const state = {
  session: null,
  files: [],
  truncated: false,
  limit: 0,
  category: "all",
  filter: "",
  sort: "name",
  view: "list",
  selectedId: null,
  detail: null,
  checksums: new Map(),
  stopped: false,
};

/* ------------------------------------------------------------------ helpers */

const $ = (id) => document.getElementById(id);

function el(tag, attrs, children) {
  const node = document.createElement(tag);
  for (const [key, value] of Object.entries(attrs || {})) {
    if (value === null || value === undefined || value === false) continue;
    if (key === "text") node.textContent = value;
    else if (key === "class") node.className = value;
    else node.setAttribute(key, value === true ? "" : String(value));
  }
  for (const child of children || []) {
    if (child !== null && child !== undefined && child !== false) node.append(child);
  }
  return node;
}

function icon(name, className) {
  const svg = document.createElementNS(SVG_NS, "svg");
  svg.setAttribute("aria-hidden", "true");
  if (className) svg.setAttribute("class", className);
  const use = document.createElementNS(SVG_NS, "use");
  use.setAttribute("href", `#${name}`);
  svg.append(use);
  return svg;
}

function category(name) {
  return Object.prototype.hasOwnProperty.call(CATEGORIES, name) ? name : "other";
}

function formatSize(bytes) {
  if (!Number.isFinite(bytes)) return "";
  if (bytes < 1024) return `${bytes} B`;
  const units = ["KB", "MB", "GB", "TB", "PB"];
  let value = bytes / 1024;
  let index = 0;
  while (value >= 1024 && index < units.length - 1) {
    value /= 1024;
    index += 1;
  }
  return `${value < 10 ? value.toFixed(1) : Math.round(value)} ${units[index]}`;
}

function formatDate(epoch) {
  return new Date(epoch * 1000).toLocaleString(undefined, {
    year: "numeric", month: "short", day: "2-digit", hour: "2-digit", minute: "2-digit",
  });
}

function formatDay(epoch) {
  return new Date(epoch * 1000).toLocaleDateString(undefined, {
    year: "numeric", month: "short", day: "numeric",
  });
}

function plural(count, word) {
  return `${count} ${word}${count === 1 ? "" : "s"}`;
}

/* ---------------------------------------------------------------------- api */

async function api(path, options = {}) {
  const url = new URL(path, window.location.origin);
  for (const [key, value] of Object.entries(options.params || {})) {
    url.searchParams.set(key, value);
  }
  const init = {
    method: options.method || "GET",
    cache: "no-store",
    headers: { "X-Session-Token": TOKEN },
  };
  if (options.body) {
    init.headers["Content-Type"] = "application/json";
    init.body = JSON.stringify(options.body);
  }

  let response;
  try {
    response = await fetch(url, init);
  } catch {
    return { status: "error", message: "The program is not answering — it may have stopped." };
  }

  const text = await response.text();
  try {
    const data = text ? JSON.parse(text) : {};
    if (!data.status) data.status = response.ok ? "ok" : "error";
    return data;
  } catch {
    return { status: "error", message: text.trim() || `Request failed (${response.status}).` };
  }
}

const rawUrl = (id) => `/api/raw?id=${encodeURIComponent(id)}&t=${encodeURIComponent(TOKEN)}`;

/* ------------------------------------------------------------------- toasts */

function toast(message, kind = "info") {
  if (!message) return;
  const glyph = kind === "error" ? "i-warning" : kind === "ok" ? "i-check" : "i-help";
  const node = el("div", { class: `toast ${kind}` }, [
    icon(glyph),
    el("span", { class: "msg", text: message }),
  ]);
  $("toasts").append(node);
  window.setTimeout(() => {
    node.classList.add("leaving");
    window.setTimeout(() => node.remove(), 220);
  }, kind === "error" ? 6500 : 3800);
}

/* ------------------------------------------------------------------ dialogs */

// Resolves with the dialog's value when confirmed, or null when dismissed.
function openDialog({ title, build, confirmText = "Confirm", danger = false }) {
  return new Promise((resolve) => {
    const node = $("dialog");
    const confirm = $("dialog-confirm");
    const cancel = $("dialog-cancel");
    const close = $("dialog-close");
    const body = $("dialog-body");

    $("dialog-title").textContent = title;
    body.textContent = "";
    confirm.className = `btn ${danger ? "destructive" : "primary"}`;
    confirm.textContent = confirmText;
    confirm.disabled = false;

    const context = { value: () => true, enable: (on) => { confirm.disabled = !on; } };
    const focus = build(body, context);

    let settled = false;
    const finish = (result) => {
      if (settled) return;
      settled = true;
      confirm.removeEventListener("click", onConfirm);
      cancel.removeEventListener("click", onDismiss);
      close.removeEventListener("click", onDismiss);
      node.removeEventListener("close", onDismiss);
      body.removeEventListener("keydown", onKey);
      if (node.open) node.close();
      resolve(result);
    };
    const onConfirm = () => { if (!confirm.disabled) finish(context.value()); };
    const onDismiss = () => finish(null);
    const onKey = (event) => {
      if (event.key === "Enter" && event.target.tagName === "INPUT") {
        event.preventDefault();
        onConfirm();
      }
    };

    confirm.addEventListener("click", onConfirm);
    cancel.addEventListener("click", onDismiss);
    close.addEventListener("click", onDismiss);
    node.addEventListener("close", onDismiss);
    body.addEventListener("keydown", onKey);

    node.showModal();
    if (focus && focus.focus) focus.focus();
    else confirm.focus();
  });
}

function confirmDialog({ title, message, confirmText, danger = false, detail = null }) {
  return openDialog({
    title,
    confirmText,
    danger,
    build: (body) => {
      body.append(el("p", { text: message }));
      if (detail) body.append(el("p", { class: "hint", text: detail }));
    },
  });
}

function textDialog({ title, label, value, confirmText, hint, quickPicks = [], danger = false, mono = false }) {
  return openDialog({
    title,
    confirmText,
    danger,
    build: (body, context) => {
      const input = el("input", { type: "text", value, spellcheck: "false", autocomplete: "off", class: mono ? "mono" : null });
      body.append(el("label", { text: label, for: "dialog-input" }));
      input.id = "dialog-input";
      body.append(input);
      if (hint) body.append(el("p", { class: "hint", text: hint }));
      if (quickPicks.length) {
        const picks = el("div", { class: "chips" });
        for (const pick of quickPicks.slice(0, 14)) {
          const chip = el("button", { type: "button", class: "chip", title: pick.path }, [
            icon(pick.icon || "i-folder"),
            el("span", { text: pick.label }),
          ]);
          chip.addEventListener("click", () => {
            input.value = pick.path;
            input.focus();
          });
          picks.append(chip);
        }
        body.append(picks);
      }
      context.value = () => input.value.trim() || null;
      return input;
    },
  });
}

// Deleting asks for the word "yes", exactly as the terminal interface does;
// the program refuses the request without it, too.
function deleteDialog(file) {
  return openDialog({
    title: "Delete permanently",
    confirmText: "Delete",
    danger: true,
    build: (body, context) => {
      body.append(el("div", { class: "warnbox" }, [
        icon("i-warning"),
        el("span", {}, [
          document.createTextNode("This deletes "),
          el("strong", { text: file.name }),
          document.createTextNode(file.symlink
            ? " — the link itself, never the file it points at. It cannot be undone."
            : " from the folder. It cannot be undone."),
        ]),
      ]));
      body.append(el("label", { text: "Type yes to confirm" }));
      const input = el("input", { type: "text", value: "", autocomplete: "off", spellcheck: "false" });
      body.append(input);
      context.enable(false);
      context.value = () => (input.value.trim() === "yes" ? "yes" : null);
      input.addEventListener("input", () => context.enable(input.value.trim() === "yes"));
      return input;
    },
  });
}

function folderPicks() {
  const picks = [];
  if (state.session?.parent) {
    picks.push({ label: "Parent folder", path: state.session.parent, icon: "i-arrow-up" });
  }
  for (const sub of state.session?.subdirectories || []) {
    picks.push({ label: sub.name, path: sub.path });
  }
  return picks;
}

/* ------------------------------------------------------------------ loading */

async function loadSession() {
  const data = await api("/api/session");
  if (data.status === "error") {
    toast(data.message, "error");
    return false;
  }
  state.session = data;
  $("version").textContent = `v${data.version}`;
  document.title = `${data.directory} — File Organizer`;
  renderCrumbs();
  return true;
}

async function loadFiles() {
  const data = await api("/api/files");
  if (data.status === "error") {
    toast(data.message, "error");
    return false;
  }
  state.files = data.files;
  state.truncated = data.truncated;
  state.limit = data.limit;
  state.checksums.clear();
  return true;
}

// Reloads the folder and lands on `select` when it is still there.
async function reload({ select = null } = {}) {
  if (!(await loadFiles())) return;
  await loadSession();
  renderChips();
  renderList();
  renderCounts();

  const known = (id) => id && state.files.some((file) => file.id === id);
  const visible = visibleFiles();
  const target = (known(select) && select) || (known(state.selectedId) && state.selectedId) ||
                 (visible.length ? visible[0].id : null);
  if (target) {
    await selectFile(target);
  } else {
    state.selectedId = null;
    state.detail = null;
    showStage();
  }
  if (state.view === "grid") renderGallery();
}

/* ---------------------------------------------------------------- filtering */

function visibleFiles() {
  const needle = state.filter.trim().toLowerCase();
  const files = state.files.filter((file) => {
    if (state.category !== "all" && category(file.category) !== state.category) return false;
    return !needle || file.name.toLowerCase().includes(needle);
  });
  const descending = state.sort === "size" || state.sort === "modified";
  files.sort((a, b) => (descending ? -1 : 1) * compareFiles(a, b));
  return files;
}

function compareFiles(a, b) {
  switch (state.sort) {
    case "size": return a.size - b.size || byName(a, b);
    case "modified": return a.modified - b.modified || byName(a, b);
    case "kind": return a.kind.localeCompare(b.kind) || byName(a, b);
    default: return byName(a, b);
  }
}

function byName(a, b) {
  return a.name.localeCompare(b.name, undefined, { numeric: true, sensitivity: "base" });
}

function currentFile() {
  return state.files.find((file) => file.id === state.selectedId) || null;
}

/* ---------------------------------------------------------------- rendering */

function renderCrumbs() {
  const bar = $("crumbs");
  bar.textContent = "";
  const session = state.session;
  if (!session) return;

  const parts = crumbTrail(session.directory, session.separator);
  parts.forEach((part, index) => {
    const last = index === parts.length - 1;
    if (index > 0) bar.append(icon("i-chevron", "crumb-sep"));
    const crumb = el("button", {
      type: "button",
      class: `crumb${last ? " current" : ""}`,
      title: part.path,
      disabled: last,
    }, [index === 0 ? icon("i-folder") : null, el("span", { text: part.label })]);
    if (!last) crumb.addEventListener("click", () => changeFolder(part.path));
    bar.append(crumb);
  });
}

function crumbTrail(directory, separator) {
  const sep = separator || "/";
  const parts = directory.split(sep).filter((part, index) => part !== "" || index === 0);
  const trail = [];
  let path = "";
  parts.forEach((part, index) => {
    if (index === 0) {
      path = part === "" ? sep : part + sep;
      trail.push({ label: part === "" ? sep : part, path });
      return;
    }
    path = path.endsWith(sep) ? path + part : `${path}${sep}${part}`;
    trail.push({ label: part, path });
  });
  return trail;
}

function renderChips() {
  const bar = $("chips");
  bar.textContent = "";
  const counts = new Map();
  for (const file of state.files) {
    const key = category(file.category);
    counts.set(key, (counts.get(key) || 0) + 1);
  }
  if (state.category !== "all" && !counts.has(state.category)) state.category = "all";

  const entries = [["all", { label: "All", icon: null }, state.files.length]];
  for (const key of Object.keys(CATEGORIES)) {
    if (counts.has(key)) entries.push([key, CATEGORIES[key], counts.get(key)]);
  }

  for (const [key, meta, count] of entries) {
    const chip = el("button", {
      type: "button",
      class: "chip",
      role: "tab",
      "aria-selected": String(state.category === key),
    }, [
      key === "all" ? null : el("span", { class: `dot cat-${key}` }),
      el("span", { text: meta.label }),
      el("span", { class: "n", text: String(count) }),
    ]);
    chip.addEventListener("click", () => {
      state.category = key;
      renderChips();
      renderList();
      renderCounts();
      if (state.view === "grid") renderGallery();
    });
    bar.append(chip);
  }
}

function renderList() {
  const list = $("filelist");
  list.textContent = "";
  const files = visibleFiles();

  if (!files.length) {
    list.append(el("li", { class: "emptynote", text: state.files.length ? "Nothing matches this filter." : "This folder has no files." }));
    return;
  }

  for (const file of files) {
    const meta = CATEGORIES[category(file.category)];
    const row = el("li", {
      class: `row${file.hidden ? " dim" : ""}`,
      role: "option",
      "aria-selected": String(file.id === state.selectedId),
      "data-id": file.id,
    }, [
      el("span", { class: `glyph cat-${category(file.category)}` }, [icon(meta.icon)]),
      el("span", { class: "rowtext" }, [
        el("span", { class: "nm", text: file.name }),
        el("span", { class: "mt" }, [
          el("span", { text: `${file.kind} · ${formatSize(file.size)}` }),
          file.mismatch ? el("span", { class: "flag", title: "The extension does not match the content" }, [icon("i-warning")]) : null,
        ]),
      ]),
    ]);
    row.addEventListener("click", () => selectFile(file.id));
    list.append(row);
  }
}

function renderCounts() {
  const files = visibleFiles();
  const bytes = files.reduce((total, file) => total + file.size, 0);
  const shown = `${plural(files.length, "file")}${files.length === state.files.length ? "" : ` of ${state.files.length}`}`;
  $("counts").textContent = "";
  $("counts").append(
    el("span", { text: shown }),
    el("span", { text: formatSize(bytes) }),
  );
  if (state.truncated) {
    $("counts").append(el("span", { class: "flag", title: `Only the first ${state.limit} entries are listed` }, [icon("i-warning")]));
  }
}

function markSelection() {
  for (const row of document.querySelectorAll("#filelist .row")) {
    row.setAttribute("aria-selected", String(row.dataset.id === state.selectedId));
  }
  for (const tile of document.querySelectorAll("#gallery .tile")) {
    tile.setAttribute("aria-selected", String(tile.dataset.id === state.selectedId));
  }
}

function scrollSelectionIntoView() {
  const row = document.querySelector(`#filelist .row[data-id="${cssEscape(state.selectedId)}"]`);
  if (row) row.scrollIntoView({ block: "nearest" });
}

function cssEscape(value) {
  return window.CSS && CSS.escape ? CSS.escape(value || "") : (value || "").replace(/["\\]/g, "\\$&");
}

function showStage() {
  const hasFiles = state.files.length > 0;
  const grid = state.view === "grid";
  $("gallery").hidden = !(grid && hasFiles);
  $("detail").hidden = grid || !state.detail;
  $("placeholder").hidden = (grid && hasFiles) || Boolean(state.detail);
  if ($("placeholder").hidden) return;
  $("placeholder-text").textContent = state.stopped
    ? "file_organizer has stopped. You can close this tab."
    : hasFiles ? "Choose a file to review." : "This folder has no files to review.";
}

async function selectFile(id, { scroll = true } = {}) {
  state.selectedId = id;
  markSelection();
  if (scroll) scrollSelectionIntoView();

  const data = await api("/api/file", { params: { id } });
  if (state.selectedId !== id) return;
  if (data.status === "error") {
    // Drop the entry rather than reloading: if the folder still offers this
    // file, reloading would just select it again and ask again, forever.
    toast(data.message, "error");
    state.files = state.files.filter((file) => file.id !== id);
    state.selectedId = null;
    state.detail = null;
    renderChips();
    renderList();
    renderCounts();
    if (state.view === "grid") renderGallery();
    showStage();
    return;
  }
  state.detail = data;
  renderDetail();
  showStage();
}

function renderDetail() {
  const detail = state.detail;
  if (!detail) return;

  const meta = CATEGORIES[category(detail.category)];
  const glyph = $("d-glyph");
  glyph.textContent = "";
  glyph.className = `fileglyph cat-${category(detail.category)}`;
  glyph.append(icon(meta.icon));

  $("d-name").textContent = detail.name;
  $("d-kind").textContent = detail.kind;

  renderBadges(detail);
  renderActions(detail);
  renderPreview(detail);
  renderFields(detail);
  renderSections(detail);
}

function renderBadges(detail) {
  const bar = $("d-badges");
  bar.textContent = "";
  const badges = [];
  if (detail.mismatch) badges.push(["warn", "i-warning", "Extension does not match content"]);
  if (detail.executable) badges.push(["danger", "i-code", "Executable — opening is disabled"]);
  if (detail.symlink) badges.push(["info", "i-link", "Symbolic link"]);
  if (detail.hidden) badges.push(["", "i-eye", "Hidden (dotfile)"]);
  if (detail.size === 0 && !detail.symlink) badges.push(["", "i-other", "Empty file"]);
  for (const [kind, glyph, label] of badges) {
    bar.append(el("span", { class: `badge${kind ? ` ${kind}` : ""}` }, [icon(glyph), el("span", { text: label })]));
  }
}

function renderActions(detail) {
  const bar = $("d-actions");
  bar.textContent = "";

  const add = (label, glyph, handler, { enabled = true, className = "btn", title = null } = {}) => {
    const button = el("button", { type: "button", class: className, title, disabled: !enabled }, [
      icon(glyph),
      el("span", { text: label }),
    ]);
    if (enabled) button.addEventListener("click", handler);
    bar.append(button);
  };

  add("Open", "i-open", openFile, {
    enabled: detail.openable,
    title: detail.openable
      ? "Open with the system default application (o)"
      : "Disabled: executable content, or not a regular file",
  });
  add("Rename", "i-rename", renameFile, { title: "Rename in place (r)" });
  add("Copy to…", "i-copy", () => transferFile("copy"), { enabled: !detail.symlink, title: "Copy to another folder (c)" });
  add("Move to…", "i-move", () => transferFile("move"), { enabled: !detail.symlink, title: "Move to another folder (m)" });
  add("Checksum", "i-hash", checksumFile, { enabled: !detail.symlink, title: "SHA-256 of the contents (h)" });
  add("Delete", "i-trash", deleteFile, { className: "btn danger", title: "Delete permanently (d)" });
}

function renderPreview(detail) {
  const box = $("d-preview");
  box.textContent = "";
  if (detail.media === "image") box.append(imagePreview(detail));
  else if (detail.media === "audio") box.append(audioPreview(detail));
  else if (detail.media === "video") box.append(videoPreview(detail));
  else if (detail.textual) loadTextPreview(detail, box);
  else box.append(noPreview(previewExcuse(detail)));
}

function previewExcuse(detail) {
  if (detail.symlink) return "Links are described, not followed — open the target itself to see it.";
  if (detail.format === "svg") return "SVG is shown as text rather than drawn, so nothing inside it can run.";
  if (detail.format === "pdf") return "PDFs are not drawn in this page — use Open to view it in your usual application.";
  if (detail.size === 0) return "This file is empty.";
  return "No preview for this kind of file — use Open to view it in your usual application.";
}

function noPreview(message) {
  return el("div", { class: "nopreview" }, [icon("i-eye"), el("span", { text: message })]);
}

function imagePreview(detail) {
  const frame = el("div", { class: "mediaframe" });
  const caption = el("div", { class: "mediacaption", text: "Loading preview…" });
  const image = new Image();
  image.alt = "";
  image.decoding = "async";
  image.addEventListener("load", () => {
    caption.textContent = `${image.naturalWidth} × ${image.naturalHeight} px — click the image to zoom`;
  });
  image.addEventListener("error", () => {
    frame.replaceChildren(noPreview("Your browser could not decode this image."));
    caption.remove();
  });
  image.addEventListener("click", () => image.classList.toggle("zoom"));
  image.src = rawUrl(detail.id);
  frame.append(image);
  return el("div", {}, [frame, caption]);
}

function audioPreview(detail) {
  const tags = metadataMap(detail);
  const title = tags.get("Title") || detail.name;
  const line = ["Artist", "Album", "Year"].map((key) => tags.get(key)).filter(Boolean).join(" · ");
  const player = el("audio", { controls: true, preload: "metadata", src: rawUrl(detail.id) });
  const meta = el("div", { class: "meta" }, [
    el("div", { class: "track", text: title }),
    el("div", { class: "sub", text: line || detail.kind }),
    player,
  ]);
  const wrap = el("div", { class: "player" }, [
    el("span", { class: "art" }, [icon("i-audio")]),
    meta,
  ]);
  player.addEventListener("error", () => {
    player.replaceWith(noPreview("Your browser could not play this audio file."));
  });
  return wrap;
}

function videoPreview(detail) {
  const video = el("video", { controls: true, preload: "metadata", src: rawUrl(detail.id) });
  const frame = el("div", { class: "mediaframe" }, [video]);
  video.addEventListener("error", () => {
    frame.replaceChildren(noPreview("Your browser could not play this video file."));
  });
  return frame;
}

async function loadTextPreview(detail, box) {
  box.replaceChildren(el("div", { class: "nopreview" }, [icon("i-eye"), el("span", { text: "Reading the file…" })]));
  const data = await api("/api/text", { params: { id: detail.id } });
  if (!state.detail || state.detail.id !== detail.id) return;
  if (data.status !== "ok") {
    box.replaceChildren(noPreview(data.message || "This file could not be previewed."));
    return;
  }

  const lines = el("ol", { class: "code" });
  if (!data.lines.length) {
    lines.append(el("li", {}, [el("code", { class: "empty", text: "(this file is empty)" })]));
  }
  for (const line of data.lines) {
    lines.append(el("li", {}, [el("code", { text: line })]));
  }

  box.replaceChildren(el("div", { class: "textview" }, [
    el("header", {}, [icon("i-eye"), el("span", { text: "Text preview" })]),
    lines,
    data.truncated ? el("div", { class: "truncnote", text: "Preview truncated — only the beginning of the file is shown." }) : null,
  ]));
}

function metadataMap(detail) {
  const map = new Map();
  for (const section of detail.sections || []) {
    for (const field of section.fields) map.set(field.label, field.value);
  }
  return map;
}

function renderFields(detail) {
  const list = $("d-fields");
  list.textContent = "";
  const rows = detail.fields.slice();
  const checksum = state.checksums.get(detail.id);
  if (checksum) rows.push({ label: "SHA-256", value: checksum });

  rows.forEach((field, index) => {
    const stripe = index % 2 === 1 ? " stripe" : "";
    const flagged = field.label === "Warning" ? " flagged" : "";
    const mono = field.label === "SHA-256" ? " mono" : "";
    list.append(el("dt", { class: stripe.trim() || null, text: field.label }));
    list.append(el("dd", { class: `${stripe}${flagged}${mono}`.trim() || null, text: field.value }));
  });
}

function renderSections(detail) {
  const box = $("d-sections");
  box.textContent = "";
  for (const section of detail.sections || []) {
    const card = el("section", { class: "card" }, [el("header", { text: section.title })]);
    if (!section.fields.length) {
      card.append(el("div", { class: "none", text: "Nothing found in this file." }));
    } else {
      const list = el("dl", { class: "fields" });
      section.fields.forEach((field, index) => {
        const stripe = index % 2 === 1 ? "stripe" : null;
        list.append(el("dt", { class: stripe, text: field.label }));
        list.append(el("dd", { class: stripe, text: field.value }));
      });
      card.append(list);
    }
    box.append(card);
  }
}

function renderGallery() {
  const box = $("gallery");
  box.textContent = "";
  const files = visibleFiles();
  if (!files.length) {
    box.append(el("p", { class: "emptynote", text: "Nothing to show here." }));
    return;
  }

  for (const file of files) {
    const meta = CATEGORIES[category(file.category)];
    const thumb = el("div", { class: `thumb${file.media === "image" ? " image" : ""}` });
    if (file.media === "image") {
      const image = new Image();
      image.alt = "";
      image.loading = "lazy";
      image.decoding = "async";
      image.addEventListener("error", () => thumb.replaceChildren(icon(meta.icon, `cat-${category(file.category)}`)));
      image.src = rawUrl(file.id);
      thumb.append(image);
    } else {
      thumb.append(icon(meta.icon, `cat-${category(file.category)}`));
    }

    const tile = el("button", {
      type: "button",
      class: "tile",
      "data-id": file.id,
      "aria-selected": String(file.id === state.selectedId),
      title: file.name,
    }, [
      thumb,
      el("span", { class: "cap" }, [
        el("span", { class: "nm", text: file.name }),
        el("span", { class: "mt", text: `${formatSize(file.size)} · ${formatDay(file.modified)}` }),
      ]),
    ]);
    tile.addEventListener("click", async () => {
      await selectFile(file.id);
      setView("list");
    });
    box.append(tile);
  }
}

/* -------------------------------------------------------------------actions */

async function openFile() {
  const file = currentFile();
  if (!file) return;
  const result = await api("/api/open", { method: "POST", body: { id: file.id } });
  toast(result.message, result.status === "ok" ? "ok" : "error");
}

async function renameFile() {
  const file = currentFile();
  if (!file) return;

  const name = await textDialog({
    title: "Rename file",
    label: "New name",
    value: file.name,
    confirmText: "Rename",
    hint: "A name is a single file name: no slashes, and nothing is ever overwritten.",
  });
  if (!name || name === file.name) return;

  const result = await api("/api/rename", { method: "POST", body: { id: file.id, name } });
  toast(result.message, result.status === "ok" ? "ok" : "error");
  if (result.status === "ok") await reload({ select: result.id });
}

async function transferFile(kind) {
  const file = currentFile();
  if (!file) return;

  const destination = await textDialog({
    title: kind === "copy" ? "Copy to folder" : "Move to folder",
    label: "Destination folder",
    value: state.session?.directory || "",
    confirmText: kind === "copy" ? "Copy" : "Move",
    mono: true,
    hint: "The folder has to exist already and be writable.",
    quickPicks: folderPicks(),
  });
  if (!destination) return;

  const body = { id: file.id, destination };
  let result = await api(`/api/${kind}`, { method: "POST", body });
  if (result.status === "conflict") {
    const go = await confirmDialog({
      title: "Overwrite the file there?",
      message: `${result.message}.`,
      detail: "The file already in that folder will be replaced.",
      confirmText: "Overwrite",
      danger: true,
    });
    if (!go) return;
    result = await api(`/api/${kind}`, { method: "POST", body: { ...body, overwrite: true } });
  }

  toast(result.message, result.status === "ok" ? "ok" : "error");
  if (result.status !== "ok") return;
  await reload({ select: kind === "copy" ? file.id : neighbourOf(file.id) });
}

async function deleteFile() {
  const file = currentFile();
  if (!file) return;
  const confirmed = await deleteDialog(file);
  if (!confirmed) return;

  const next = neighbourOf(file.id);
  const result = await api("/api/delete", { method: "POST", body: { id: file.id, confirm: "yes" } });
  toast(result.message, result.status === "ok" ? "ok" : "error");
  if (result.status === "ok") await reload({ select: next });
}

async function checksumFile() {
  const file = currentFile();
  if (!file) return;
  if (file.size > 50 * 1024 * 1024) toast("Computing SHA-256 — this may take a moment.", "info");

  const result = await api("/api/hash", { params: { id: file.id } });
  if (result.status !== "ok") {
    toast(result.message, "error");
    return;
  }
  state.checksums.set(file.id, result.sha256);
  if (state.detail && state.detail.id === file.id) renderFields(state.detail);
  toast("SHA-256 added to the file information.", "ok");
}

async function changeFolder(path) {
  const result = await api("/api/folder", { method: "POST", body: { path } });
  if (result.status !== "ok") {
    toast(result.message, "error");
    return;
  }
  state.selectedId = null;
  state.detail = null;
  state.filter = "";
  $("search").value = "";
  await reload();
  showStage();
}

async function chooseFolder() {
  const path = await textDialog({
    title: "Open another folder",
    label: "Folder",
    value: state.session?.directory || "",
    confirmText: "Open",
    mono: true,
    hint: "Only the files directly inside the folder are listed; subfolders are never touched.",
    quickPicks: folderPicks(),
  });
  if (path) await changeFolder(path);
}

async function quitProgram() {
  const go = await confirmDialog({
    title: "Stop file_organizer?",
    message: "The program stops and this page stops working. Your files are left exactly as they are.",
    confirmText: "Stop the program",
    danger: true,
  });
  if (!go) return;

  const result = await api("/api/quit", { method: "POST", body: { confirm: "yes" } });
  toast(result.message || "Stopping.", "ok");
  state.stopped = true;
  state.detail = null;
  state.files = [];
  state.selectedId = null;
  document.title = "File Organizer — stopped";
  renderList();
  renderChips();
  renderCounts();
  showStage();
}

// The id to land on once the current file is gone.
function neighbourOf(id) {
  const files = visibleFiles();
  const index = files.findIndex((file) => file.id === id);
  if (index < 0) return null;
  const next = files[index + 1] || files[index - 1];
  return next ? next.id : null;
}

function moveSelection(step) {
  const files = visibleFiles();
  if (!files.length) return;
  const index = files.findIndex((file) => file.id === state.selectedId);
  const target = files[Math.min(Math.max(index + step, 0), files.length - 1)] || files[0];
  if (target && target.id !== state.selectedId) selectFile(target.id);
}

/* ---------------------------------------------------------------- view/theme */

function setView(view) {
  state.view = view;
  $("view-list").setAttribute("aria-pressed", String(view === "list"));
  $("view-grid").setAttribute("aria-pressed", String(view === "grid"));
  if (view === "grid") renderGallery();
  showStage();
  markSelection();
}

function storedTheme() {
  try {
    return window.localStorage.getItem(THEME_KEY);
  } catch {
    return null;
  }
}

function applyTheme(theme, remember) {
  document.documentElement.setAttribute("data-theme", theme);
  const use = $("act-theme").querySelector("use");
  use.setAttribute("href", theme === "dark" ? "#i-sun" : "#i-moon");
  $("act-theme").title = theme === "dark" ? "Switch to the light theme (T)" : "Switch to the dark theme (T)";
  if (!remember) return;
  try {
    window.localStorage.setItem(THEME_KEY, theme);
  } catch {
    /* a browser that refuses storage still gets the theme, just not the memory */
  }
}

function currentTheme() {
  return document.documentElement.getAttribute("data-theme") ||
    (window.matchMedia("(prefers-color-scheme: light)").matches ? "light" : "dark");
}

/* ------------------------------------------------------------------ keyboard */

const SHORTCUTS = {
  o: openFile,
  r: renameFile,
  c: () => transferFile("copy"),
  m: () => transferFile("move"),
  d: deleteFile,
  h: checksumFile,
};

function onKeyDown(event) {
  if (event.metaKey || event.ctrlKey || event.altKey) return;
  if (document.querySelector("dialog[open]")) return;

  const target = event.target;
  const typing = target instanceof HTMLElement &&
    (target.tagName === "INPUT" || target.tagName === "SELECT" || target.isContentEditable);
  if (typing) {
    if (event.key === "Escape") {
      target.blur();
      if (target.id === "search") {
        target.value = "";
        applyFilter("");
      }
    }
    return;
  }

  if (event.key === "ArrowDown" || event.key === "j") {
    event.preventDefault();
    moveSelection(1);
    return;
  }
  if (event.key === "ArrowUp" || event.key === "k") {
    event.preventDefault();
    moveSelection(-1);
    return;
  }
  if (event.key === "/") {
    event.preventDefault();
    $("search").focus();
    return;
  }
  if (event.key === "?") {
    $("shortcuts").showModal();
    return;
  }
  if (event.key === "R") {
    reload({ select: state.selectedId });
    return;
  }
  if (event.key === "T" || event.key === "t") {
    applyTheme(currentTheme() === "dark" ? "light" : "dark", true);
    return;
  }
  if (event.key === "g") {
    setView(state.view === "grid" ? "list" : "grid");
    return;
  }
  if (event.key === "Escape" && state.filter) {
    $("search").value = "";
    applyFilter("");
    return;
  }

  const action = SHORTCUTS[event.key];
  if (action && currentFile()) {
    event.preventDefault();
    action();
  }
}

function applyFilter(value) {
  state.filter = value;
  renderList();
  renderCounts();
  if (state.view === "grid") renderGallery();
}

/* ---------------------------------------------------------------------- init */

function wireUp() {
  $("search").addEventListener("input", (event) => applyFilter(event.target.value));
  $("sort").addEventListener("change", (event) => {
    state.sort = event.target.value;
    renderList();
    if (state.view === "grid") renderGallery();
  });
  $("view-list").addEventListener("click", () => setView("list"));
  $("view-grid").addEventListener("click", () => setView("grid"));
  $("act-folder").addEventListener("click", chooseFolder);
  $("act-refresh").addEventListener("click", () => reload({ select: state.selectedId }));
  $("act-theme").addEventListener("click", () => applyTheme(currentTheme() === "dark" ? "light" : "dark", true));
  $("act-help").addEventListener("click", () => $("shortcuts").showModal());
  $("act-quit").addEventListener("click", quitProgram);
  $("shortcuts-close").addEventListener("click", () => $("shortcuts").close());
  $("shortcuts-done").addEventListener("click", () => $("shortcuts").close());
  document.addEventListener("keydown", onKeyDown);
}

async function main() {
  applyTheme(storedTheme() || currentTheme(), Boolean(storedTheme()));
  wireUp();

  if (!TOKEN) {
    $("placeholder-text").textContent =
      "This page needs the one-time address that file_organizer printed in your terminal.";
    return;
  }
  if (!(await loadSession())) return;
  if (!(await loadFiles())) return;

  const startCategory = state.session.mode === "photo" ? "photo" : state.session.mode === "audio" ? "audio" : "all";
  if (state.files.some((file) => category(file.category) === startCategory)) state.category = startCategory;

  renderChips();
  renderList();
  renderCounts();

  const first = visibleFiles()[0];
  if (first) await selectFile(first.id);
  showStage();
}

main();
