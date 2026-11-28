const MAX = { title: 200, text: 4000, lines: 20000, items: 200, points: 50, lang: 12, who: 40 };

class Invalid extends Error {}

function str(v, max, optional = false) {
  if (v == null && optional) return null;
  if (typeof v !== "string" || v.length > max) throw new Invalid();
  return v;
}

function num(v, optional = false) {
  if (v == null && optional) return null;
  if (typeof v !== "number" || !Number.isFinite(v) || v < 0 || v > 1e7) throw new Invalid();
  return Math.round(v * 10) / 10;
}

function list(v, max, each) {
  if (v == null) return [];
  if (!Array.isArray(v) || v.length > max) throw new Invalid();
  return v.map(each);
}

export function clean(input) {
  try {
    if (!input || input.v !== 1) throw new Invalid();
    const doc = {
      v: 1,
      title: str(input.title, MAX.title).trim() || "—",
      startedAt: str(input.startedAt, 40),
      duration: Math.round(num(input.duration)),
      langs: list(input.langs, 2, (l) => str(l, MAX.lang)),
      notes: null,
      lines: list(input.lines, MAX.lines, (l) => ({
        t: num(l?.t), who: str(l?.who, MAX.who), src: str(l?.src, MAX.text), dst: str(l?.dst, MAX.text, true),
      })),
      hidden: Math.round(num(input.hidden ?? 0)),
    };
    if (isNaN(Date.parse(doc.startedAt))) throw new Invalid();
    const n = input.notes;
    if (n != null) {
      if (typeof n !== "object") throw new Invalid();
      doc.notes = {
        summary: str(n.summary ?? "", MAX.text),
        topics: list(n.topics, MAX.items, (t) => ({
          start: num(t?.start), title: str(t?.title, MAX.title), summary: str(t?.summary ?? "", MAX.text),
          points: list(t?.points, MAX.points, (p) => str(p, MAX.text)),
        })),
        conclusions: list(n.conclusions, MAX.items, (c) => ({ text: str(c?.text, MAX.text), t: num(c?.t, true) })),
        todos: list(n.todos, MAX.items, (c) => ({ text: str(c?.text, MAX.text), owner: str(c?.owner, MAX.who, true), t: num(c?.t, true) })),
        terms: list(n.terms, MAX.items, (c) => ({ name: str(c?.name, MAX.title), note: str(c?.note ?? "", MAX.text) })),
      };
    }
    if (!doc.notes && doc.lines.length === 0) throw new Invalid();
    return doc;
  } catch (e) {
    if (e instanceof Invalid) return null;
    throw e;
  }
}

export function notesText(notes) {
  if (!notes) return "";
  const out = [notes.summary];
  for (const t of notes.topics) out.push(t.title, t.summary, ...t.points);
  for (const c of notes.conclusions) out.push(c.text);
  for (const c of notes.todos) out.push((c.owner ? c.owner + ": " : "") + c.text);
  for (const c of notes.terms) out.push(c.name + " " + c.note);
  return out.filter(Boolean).join("\n");
}

const LINES_PER_CHUNK = 40;
export const PIECE_CHARS = 1500;
const OVERLAP = 200;

function cut(text, size = PIECE_CHARS) {
  if (text.length <= size) return [text];
  const out = [];
  for (let at = 0; at < text.length; at += size - OVERLAP) {
    out.push(text.slice(at, at + size));
    if (at + size >= text.length) break;
  }
  return out;
}

export function chunks(doc) {
  const out = [];
  const notes = notesText(doc.notes);
  if (notes) {
    const head = `Title: ${doc.title}\n`;
    let buf = "";
    const flush = () => { if (buf) out.push({ part: "notes", text: head + buf }); buf = ""; };
    for (const row of notes.split("\n")) {
      for (const piece of cut(row, PIECE_CHARS - head.length)) {
        if (buf && buf.length + 1 + piece.length > PIECE_CHARS - head.length) flush();
        buf = buf ? buf + "\n" + piece : piece;
      }
    }
    flush();
  }
  let from = 0, rows = [];
  const flush = (to) => { if (rows.length) out.push({ part: "lines", from, to, text: rows.join("\n") }); rows = []; };
  doc.lines.forEach((l, i) => {
    const text = `[${i}] ${l.who}: ${l.src}` + (l.dst && l.dst !== l.src ? `\n    ${l.dst}` : "");
    const size = rows.reduce((n, r) => n + r.length + 1, 0);
    if (rows.length && (rows.length >= LINES_PER_CHUNK || size + text.length > PIECE_CHARS)) flush(i - 1);
    if (!rows.length) from = i;
    if (text.length > PIECE_CHARS) {
      for (const piece of cut(text)) out.push({ part: "lines", from: i, to: i, text: piece });
      return;
    }
    rows.push(text);
  });
  flush(doc.lines.length - 1);
  return out;
}
