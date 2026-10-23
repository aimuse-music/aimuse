// 歌詞の自動同期の照合（supabase/functions/lyrics-align/align.js）のテスト
// 正解の時刻が分かっている歌詞から、Whisper に似た結果（聞き間違い・漢字とかなの違い・認識されない行・間奏の誤認識・時刻のずれ）を作って照合する
// 使い方: node tests/edge/test_align.mjs
import { alignLyrics, norm, transcriptChars, assessQuality } from "../../supabase/functions/lyrics-align/align.js";
const R = []; const ok = (n, c, i) => { R.push([n, !!c]); console.log(`[${c ? "PASS" : "FAIL"}] ${n}${i !== undefined ? "  → " + JSON.stringify(i) : ""}`); };

const LYR = ["[Verse 1]", "あの夜は　少し寒くて", "君と肩を寄せ合って歩いた", "白い息が　夜空に溶けて", "何も言えずに笑ってた", "",
  "【Chorus】", "おぼろ月の下で", "君の名前を呼んだ", "届かなくても　いいから", "この想いだけは消さないで", "",
  "[Verse 2]", "季節はめぐり　春が来て", "桜の道を一人で歩く", "あの日の君の横顔を", "今でも覚えているよ", "",
  "[Chorus]", "おぼろ月の下で", "君の名前を呼んだ", "届かなくても　いいから", "この想いだけは消さないで", "[Outro]", "おぼろ月"];
// 正解：行ごとの歌い出し・歌い終わり（イントロ12秒、サビの後に間奏、最後にアウトロ）
const TRUE = {}; let t = 12.0;
LYR.forEach((l, i) => { if (!l.trim() || /^\s*(\[|【)/.test(l)) { if (/Verse 2|Chorus\]|Outro/.test(l)) t += 9; return; }
  const d = [...norm(l)].length * 0.33 + 0.6; TRUE[i] = { t: +t.toFixed(2), end: +(t + d - 0.4).toFixed(2) }; t += d; });
let seed = 7; const rnd = () => (seed = (seed * 16807) % 2147483647) / 2147483647;
const noise = (a) => (rnd() * 2 - 1) * a;
// 認識結果の文字の誤り：漢字→かな、聞き間違い
const garble = (s) => s.replace("寒くて", "さむくて").replace("肩", "方").replace("溶けて", "とけて").replace("名前", "なまえ").replace("桜", "さくら").replace("横顔", "よこがお");
function whisperLike({ words, drop = [], hall = true, jitter = 0.3, group = 2 }) {
  const segs = []; const ids = Object.keys(TRUE).map(Number);
  for (let k = 0; k < ids.length; k += group) {
    const grp = ids.slice(k, k + group).filter((i) => !drop.includes(i)); if (!grp.length) continue;
    const s = { start: TRUE[grp[0]].t + noise(jitter), end: TRUE[grp[grp.length - 1]].end + noise(jitter), text: grp.map((i) => garble(LYR[i])).join(" ") };
    if (words) s.words = grp.flatMap((i) => { const cs = [...garble(LYR[i]).replace(/\s/g, "")]; const st = TRUE[i].t, d = (TRUE[i].end - st) / cs.length;
      const ws = []; for (let q = 0; q < cs.length; q += 3) ws.push({ word: cs.slice(q, q + 3).join(""), start: st + q * d + noise(jitter / 3), end: st + Math.min(cs.length, q + 3) * d + noise(jitter / 3) }); return ws; });
    segs.push(s);
  }
  if (hall) { segs.splice(5, 0, { start: TRUE[10].end + 2, end: TRUE[10].end + 5, text: "ご視聴ありがとうございました", words: words ? [{ word: "ご視聴ありがとうございました", start: TRUE[10].end + 2, end: TRUE[10].end + 5 }] : undefined }); }
  return { segments: segs.sort((a, b) => a.start - b.start) };
}
const stats = (lines) => { const e = lines.filter((x) => TRUE[x.i] && x.t != null).map((x) => Math.abs(x.t - TRUE[x.i].t)).sort((a, b) => a - b);
  const q = (p) => e[Math.min(e.length - 1, Math.floor(p * (e.length - 1)))]; return { n: e.length, med: +q(0.5).toFixed(2), p90: +q(0.9).toFixed(2), w05: +(e.filter((x) => x <= 0.5).length / e.length).toFixed(2), w10: +(e.filter((x) => x <= 1).length / e.length).toFixed(2) }; };

ok("0 文字をそろえる：カタカナ→ひらがな・全角→半角・記号と空白を除く", norm("キミの　名前！ ＡＢＣ♪") === "きみの名前abc");
ok("0 単語の時刻があれば単語単位、無ければ発話単位、vtt にも対応", transcriptChars({ segments: [{ start: 1, end: 2, text: "あい", words: [{ word: "あ", start: 1, end: 1.5 }] }] }).granularity === "word"
  && transcriptChars({ segments: [{ start: 1, end: 2, text: "あい" }] }).granularity === "segment"
  && transcriptChars({ vtt: "WEBVTT\n\n00:00:01.000 --> 00:00:02.500\nあいう\n\n" }).chars.length === 3);

// 1. 単語ごとの時刻あり
let r = alignLyrics(LYR, whisperLike({ words: true })); let s = stats(r.lines);
ok("1 単語の時刻あり：見出し・空行を除く全行（17行）に時刻", r.textLines === 17 && r.lines.every((x) => x.t != null), r.textLines);
ok("1 単語の時刻あり：ずれの中央値 0.3秒以下・90%の行が 0.6秒以内", s.med <= 0.3 && s.p90 <= 0.6, s);
ok("1 時刻は前の行より後（逆戻りしない）", r.lines.every((x, k) => k === 0 || x.t >= r.lines[k - 1].t));
ok("1 間奏の誤認識（「ご視聴ありがとうございました」）に引きずられない", Math.abs(r.lines.find((x) => x.i === 13).t - TRUE[13].t) < 1, r.lines.find((x) => x.i === 13));
ok("1 間奏の前の行に歌い終わりが付く（サビの後・3秒以上あく）", r.lines.find((x) => x.i === 10).e != null && r.lines.find((x) => x.i === 10).e < TRUE[13].t, r.lines.find((x) => x.i === 10));
ok("1 最後の行にも歌い終わり（アウトロで光り続けない）", r.lines[r.lines.length - 1].e != null);
// 2. 発話単位の時刻だけ（Workers AI が単語の時刻を返さない場合）
r = alignLyrics(LYR, whisperLike({ words: false })); s = stats(r.lines);
ok("2 発話単位だけ：ずれの中央値 0.8秒以下・90%の行が 1.5秒以内", s.med <= 0.8 && s.p90 <= 1.5, s);
r = alignLyrics(LYR, whisperLike({ words: false, group: 4, jitter: 0.8 })); s = stats(r.lines);
ok("2 発話単位が長い（4行で1まとまり・ずれ±0.8秒）場合：中央値 1.0秒以下・90%の行が 2秒以内", s.med <= 1.0 && s.p90 <= 2.0, s);
// 3. 認識されなかった行
r = alignLyrics(LYR, whisperLike({ words: true, drop: [14, 15] })); s = stats(r.lines);
const d14 = r.lines.find((x) => x.i === 14), d15 = r.lines.find((x) => x.i === 15);
ok("3 認識されなかった行は「推定（要確認）」になり、前後の行から時刻を割り出す", d14.est && d15.est && d14.t > r.lines.find((x) => x.i === 13).t && d15.t < r.lines.find((x) => x.i === 16).t, { d14, d15 });
ok("3 ほかの行の精度は保たれる（中央値 0.3秒以下）", s.med <= 0.3, s);
// 4. 繰り返すサビ（同じ歌詞）でも、それぞれの位置に付く
r = alignLyrics(LYR, whisperLike({ words: true }));
ok("4 同じ歌詞の2回目のサビも、2回目の位置に付く", Math.abs(r.lines.find((x) => x.i === 19).t - TRUE[19].t) < 0.6 && Math.abs(r.lines.find((x) => x.i === 7).t - TRUE[7].t) < 0.6);
// 5. 認識結果が空・歌詞が空
r = alignLyrics(LYR, { segments: [] });
ok("5 認識結果が空なら、すべて推定（時刻なし）で返す（手動で合わせられる）", r.lines.every((x) => x.est && x.t == null) && r.matchedLines === 0);
ok("5 歌詞が見出しだけなら空", alignLyrics(["[Intro]", ""], whisperLike({ words: true })).lines.length === 0);
// 6. 処理の速さ（行数の多い曲：歌詞176行・認識2,000文字程度）
const big = []; for (let k = 0; k < 176; k++) big.push(k % 9 === 0 ? "[Chorus]" : "まだ知らない世界があって" + k);
const segs = []; for (let k = 0; k < 176; k++) if (k % 9) segs.push({ start: k * 1.5, end: k * 1.5 + 1.4, text: "まだ知らない世界があって" + k });
const t0 = Date.now(); r = alignLyrics(big, { segments: segs }); const ms = Date.now() - t0;
ok("6 行数の多い曲でも 1秒以内に照合（Edge Function の CPU 上限 2秒）", ms < 1000 && r.matchedLines > 150, { ms, matched: r.matchedLines });

// 7. 時刻の品質の検査（assessQuality）
{ const good = alignLyrics(LYR, whisperLike({ words: true })); const qa = assessQuality(LYR, good, 120);
  ok("7 よい結果は品質に合格（理由なし）", qa.ok && qa.reasons.length === 0 && qa.ratio === 1, qa); }
{ const half = alignLyrics(LYR, whisperLike({ words: true, drop: [13, 14, 15, 16, 19, 20, 21, 22] })); const qa = assessQuality(LYR, half, 120);
  ok("7 中盤がまとめて認識されない（無音の除去で消えた場合など）→ 不合格（est_run）", !qa.ok && qa.reasons.includes("est_run") && qa.maxEstRun >= 5, qa); }
{ const qa = assessQuality(LYR, alignLyrics(LYR, { segments: [] }), 120);
  ok("7 認識結果が空 → 不合格（low_match・out_of_range）", !qa.ok && qa.reasons.includes("low_match") && qa.reasons.includes("out_of_range"), qa.reasons); }
{ const al = alignLyrics(LYR, whisperLike({ words: true })); const crowd = { ...al, lines: al.lines.map((x, k) => ({ ...x, t: 30 + k * 0.1 })) };
  const qa = assessQuality(LYR, crowd, 120); ok("7 時刻が詰まっている・一部に固まっている → 不合格（tight_gaps・short_span）", !qa.ok && qa.reasons.includes("tight_gaps") && qa.reasons.includes("short_span"), qa.reasons); }
{ const al = alignLyrics(LYR, whisperLike({ words: true })); const qa = assessQuality(LYR, al, 40);
  ok("7 曲の長さを超える時刻 → 不合格（out_of_range）", !qa.ok && qa.reasons.includes("out_of_range"), qa.reasons); }
{ const al = alignLyrics(LYR, whisperLike({ words: true, drop: [14] })); const qa = assessQuality(LYR, al, 120);
  ok("7 1行だけ認識されない程度なら合格（その行は推定として印が付く）", qa.ok && qa.est.includes(14), qa); }

const f = R.filter((x) => !x[1]); console.log(`\n合計 ${R.length} 件 / 不合格 ${f.length} 件`); f.forEach((x) => console.log("  FAIL:", x[0]));
process.exit(f.length ? 1 : 0);
