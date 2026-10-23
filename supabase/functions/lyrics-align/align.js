// AIMUSE 歌詞の自動同期：音声認識（Whisper）の結果と、登録済みの歌詞を照合して、各行の歌い出しの時刻を推定する
// ・検証（lyrics-align-probe、おぼろ月で 65／65行）と同じ照合。本番用に「時刻の品質の検査」（assessQuality）を追加
// ・ライブラリに頼らない純粋な JavaScript（Edge Function とテストの両方で同じものを使う）
// ・照合は文字単位（日本語は単語の区切りが無いため）。ひらがな・カタカナの違い、全角・半角、記号・空白は無視する
// ・認識の誤り（漢字とかなの違い・聞き間違い）、認識されなかった行、間奏中の誤認識（いわゆる幻聴）を想定し、
//   一致した文字が少ない行は「推定（要確認）」として前後の行から時刻を割り出す
// ・時刻は、単語ごとの時刻があればそれを、無ければ発話のまとまり（segment）の中で文字数に応じて割り振って求める

const HEAD = /^\s*(\[[^\]]*\]|【[^】]*】)\s*$/;
export const lyricKind = (l) => (l == null || !String(l).trim()) ? "gap" : HEAD.test(l) ? "head" : "text";

// 比べやすい形にそろえる：NFKC・小文字・カタカナ→ひらがな・文字と数字以外を除く
export function norm(s) {
  return String(s || "").normalize("NFKC").toLowerCase()
    .replace(/[ァ-ヶ]/g, (c) => String.fromCharCode(c.charCodeAt(0) - 0x60))
    .replace(/[^\p{L}\p{N}ー]/gu, "");
}

// Whisper の結果 → 1文字ずつの時刻の並び [{c, t}]
//   result.segments[].words[] があれば単語の時刻、無ければ segments の start〜end、それも無ければ vtt を使う
export function transcriptChars(result) {
  const out = [];
  const push = (text, start, end) => {
    const cs = [...norm(text)]; if (!cs.length || !isFinite(start)) return;
    const e = isFinite(end) && end > start ? end : start + 0.25 * cs.length;
    const step = (e - start) / cs.length;
    cs.forEach((c, k) => out.push({ c, t: start + step * k }));
  };
  const segs = Array.isArray(result && result.segments) ? result.segments : [];
  let words = 0;
  for (const s of segs) if (Array.isArray(s.words)) for (const w of s.words) if (w && isFinite(w.start)) words++;
  if (words > 0) {
    for (const s of segs) for (const w of (s.words || [])) push(w.word ?? w.text, +w.start, +w.end);
    return { chars: out, granularity: "word" };
  }
  if (segs.length && segs.some((s) => isFinite(+s.start))) {
    for (const s of segs) push(s.text, +s.start, +s.end);
    return { chars: out, granularity: "segment" };
  }
  if (result && typeof result.vtt === "string") {
    const re = /(\d+):(\d{2}):(\d{2})[.,](\d{3})\s*-->\s*(\d+):(\d{2}):(\d{2})[.,](\d{3})[^\n]*\n([\s\S]*?)(?:\n\n|$)/g;
    const sec = (h, m, s, ms) => (+h) * 3600 + (+m) * 60 + (+s) + (+ms) / 1000;
    let m; while ((m = re.exec(result.vtt))) push(m[9], sec(m[1], m[2], m[3], m[4]), sec(m[5], m[6], m[7], m[8]));
    return { chars: out, granularity: "segment" };
  }
  return { chars: out, granularity: "none" };
}

// 歌詞（L）と認識結果（T）の文字の並びを、端の余り（イントロ・アウトロの誤認識）を無料にした全体の並べ方で対応づける
function alignChars(L, T) {
  const n = L.length, m = T.length;
  const MATCH = 3, MIS = -1, GAP_L = -1, GAP_T = -1;
  const W = m + 1;
  const tb = new Uint8Array((n + 1) * W);   // 1=斜め 2=上（歌詞の文字が認識されていない） 3=左（認識の余分な文字）
  let prev = new Int32Array(W), cur = new Int32Array(W);
  for (let j = 1; j <= m; j++) { prev[j] = 0; tb[j] = 3; }   // 認識結果の先頭の余りは無料
  for (let i = 1; i <= n; i++) {
    cur[0] = prev[0] + GAP_L; tb[i * W] = 2;
    const li = L[i - 1];
    for (let j = 1; j <= m; j++) {
      const d = prev[j - 1] + (li === T[j - 1].c ? MATCH : MIS);
      const u = prev[j] + GAP_L;
      const l = cur[j - 1] + (i === n ? 0 : GAP_T);   // 末尾の余りは無料
      if (d >= u && d >= l) { cur[j] = d; tb[i * W + j] = 1; }
      else if (u >= l) { cur[j] = u; tb[i * W + j] = 2; }
      else { cur[j] = l; tb[i * W + j] = 3; }
    }
    [prev, cur] = [cur, prev];
  }
  const pair = new Int32Array(n).fill(-1), exact = new Uint8Array(n);
  let i = n, j = m;
  while (i > 0 && j >= 0) {
    const k = tb[i * W + j];
    if (j === 0 || k === 2) { i--; continue; }
    if (k === 1) { pair[i - 1] = j - 1; exact[i - 1] = L[i - 1] === T[j - 1].c ? 1 : 0; i--; j--; }
    else j--;
  }
  return { pair, exact };
}

// lyrics：歌詞の行の配列（見出し・空行を含む）、result：Whisper の結果
// 戻り値：{ lines:[{i,t,e?,conf,est}], granularity, matchedLines, textLines }
export function alignLyrics(lyrics, result, opts = {}) {
  const minConf = opts.minConf ?? 0.35;
  const { chars: T, granularity } = transcriptChars(result);
  const items = [];   // 時刻を付ける行
  const L = [], owner = [];
  (lyrics || []).forEach((l, i) => {
    if (lyricKind(l) !== "text") return;
    const cs = [...norm(l)]; if (!cs.length) return;
    items.push({ i, start: L.length, len: cs.length });
    cs.forEach((c) => { L.push(c); owner.push(items.length - 1); });
  });
  if (!items.length) return { lines: [], granularity, matchedLines: 0, textLines: 0 };
  if (!T.length) return { lines: items.map((x) => ({ i: x.i, t: null, conf: 0, est: true })), granularity, matchedLines: 0, textLines: items.length };
  const { pair, exact } = alignChars(L, T);
  // 1文字あたりの歌う長さ（曲全体の目安）
  const span = T[T.length - 1].t - T[0].t;
  const charDur = Math.min(0.6, Math.max(0.12, span / Math.max(1, T.length)));
  const lines = items.map((x) => {
    let hits = 0, first = -1, last = -1;
    for (let k = x.start; k < x.start + x.len; k++) if (pair[k] >= 0 && exact[k]) { hits++; if (first < 0) first = k; last = k; }
    const conf = hits / x.len;
    if (first < 0 || conf < minConf) return { i: x.i, t: null, conf, est: true, len: x.len, start: x.start };
    const t = Math.max(0, T[pair[first]].t - (first - x.start) * charDur);
    const lastT = T[pair[last]].t + (x.start + x.len - 1 - last) * charDur + charDur;
    return { i: x.i, t, lastT, conf, est: false, len: x.len, start: x.start };
  });
  // 順番が逆になった行は信頼しない（前の行より前に戻らない）
  let pt = -Infinity;
  for (const x of lines) { if (x.t == null) continue; if (x.t < pt + 0.2) { x.t = null; x.est = true; } else pt = x.t; }
  // 一致が少ない行：前後の確かな行の間に、文字数に応じて割り振る（推定・要確認）
  const known = lines.map((x, k) => x.t != null ? k : -1).filter((k) => k >= 0);
  for (let k = 0; k < lines.length; k++) {
    if (lines[k].t != null) continue;
    const a = [...known].reverse().find((q) => q < k), b = known.find((q) => q > k);
    if (a == null && b == null) continue;
    if (a == null) { lines[k].t = Math.max(0, lines[b].t - (lines[b].start - lines[k].start) * charDur); continue; }
    if (b == null) { lines[k].t = (lines[a].lastT ?? lines[a].t) + (lines[k].start - lines[a].start - lines[a].len) * charDur; continue; }
    const ta = lines[a].lastT ?? lines[a].t, tb = lines[b].t;
    const ca = lines[a].start + lines[a].len, cb = lines[b].start;
    lines[k].t = ta + (tb - ta) * ((lines[k].start - ca) / Math.max(1, cb - ca));
  }
  // 歌い終わり：次の行まで3秒以上あいている（間奏）、または最後の行
  for (let k = 0; k < lines.length; k++) {
    const x = lines[k]; if (x.est || x.lastT == null) continue;
    const nx = lines[k + 1];
    if (!nx) { x.e = x.lastT + 0.8; continue; }
    if (nx.t != null && nx.t - x.lastT >= 3) x.e = x.lastT + 0.4;
  }
  const r2 = (v) => Math.round(v * 100) / 100;
  let pt2 = 0;
  const out = lines.map((x) => {
    let t = x.t == null ? null : Math.max(pt2, r2(x.t));
    if (t != null) pt2 = x.e != null ? Math.max(t, r2(x.e)) : t;
    const o = { i: x.i, t, conf: r2(x.conf), est: !!x.est };
    if (x.e != null && t != null && r2(x.e) > t) o.e = r2(x.e);
    return o;
  });
  return { lines: out, granularity, matchedLines: lines.filter((x) => !x.est).length, textLines: lines.length };
}

// 時刻の品質の検査：照合率だけでなく、時刻の並び方もおかしくないかを確かめる（合格しても、初期は確認待ちにする）
//   low_match   …… 歌詞と認識結果が合った行が 60% 未満
//   est_run     …… 推定（認識されなかった）の行が 5行以上続く（中盤が丸ごと聞き取れていない など）
//   tight_gaps  …… 次の行まで 0.3秒未満の行が 1割を超える（時刻が詰まっている）
//   out_of_range …… 時刻が無い行・曲の長さを超える行がある
//   short_span  …… 最初の行から最後の行までが曲の長さの 3割未満（一部にだけ固まっている）
//   no_timing   …… 認識結果に時刻が無い
export function assessQuality(lyrics, al, duration) {
  const reasons = [];
  const lines = al.lines || [];
  const text = al.textLines || 0;
  const ratio = text ? al.matchedLines / text : 0;
  if (ratio < 0.6) reasons.push("low_match");
  let run = 0, maxRun = 0;
  for (const x of lines) { if (x.est) { run++; maxRun = Math.max(maxRun, run); } else run = 0; }
  if (maxRun >= 5) reasons.push("est_run");
  const ts = lines.map((x) => x.t);
  if (ts.some((t) => t == null || !isFinite(t)) || (duration > 0 && ts.some((t) => t > duration + 1))) reasons.push("out_of_range");
  const valid = ts.filter((t) => t != null && isFinite(t));
  let tight = 0; for (let k = 1; k < valid.length; k++) if (valid[k] - valid[k - 1] < 0.3) tight++;
  if (valid.length > 1 && tight / (valid.length - 1) > 0.1) reasons.push("tight_gaps");
  if (duration > 60 && valid.length > 1 && (valid[valid.length - 1] - valid[0]) < duration * 0.3) reasons.push("short_span");
  if (al.granularity === "none") reasons.push("no_timing");
  return { ok: reasons.length === 0, reasons, ratio: Math.round(ratio * 1000) / 1000, maxEstRun: maxRun, est: lines.filter((x) => x.est).map((x) => x.i) };
}
