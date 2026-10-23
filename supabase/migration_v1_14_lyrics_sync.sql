-- =====================================================================
-- AIMUSE v1.14 歌詞の同期（各行の歌い出しの時刻）（追加のみ）
-- Supabase の SQL Editor に全文を貼り付けて、1回実行してください。
--   ・既存のテーブル・データ・関数・アクセスルールは変更しません（表1つと関数2つの「追加」のみ）
--     楽曲の歌詞（tracks.lyrics）はそのまま使い、時刻だけを別の表に保存します
--   ・何度実行しても壊れません。全体を BEGIN〜COMMIT で囲んでいます（途中でエラーなら全体を取り消し）
--   ・前提：v1.9（退会）まで適用済みであること。満たさない場合は何もせずに中止します
--   ・AIMUSE BOOST の表・関数には触れません
--
-- 仕組み
--   ・表 track_lyrics_sync はアプリから直接は読み書きできません（RLS 有効・ルールなし・権限なし）
--   ・読み書きは下の関数経由
--       lyrics_sync_get(p_track)          … 時刻の一覧（その曲が見える人なら誰でも。未ログインでも可）
--                                            stale = true なら、時刻を作った後に歌詞が変わっている（要確認）
--       lyrics_sync_save(p_track, p_lines) … 保存（投稿者本人か管理者。書き込みできる会員だけ）
--   ・時刻の形式：[{"i": 歌詞の行番号（0から）, "t": 歌い出しの秒, "e": 歌い終わりの秒（任意。間奏の前に付ける）}, …]
--       ・空行と見出し（[Verse 1]・【サビ】など、行全体が [ ] か【 】で囲まれた行）には付けられません
--       ・行番号は小さい順、時刻は前の行より後（同じ時刻は可）、歌い終わりは歌い出しより後で次の行の歌い出し以前
--       ・空の一覧 [] で保存すると「同期なし」に戻ります（歌詞は全文表示のまま）
--   ・曲が削除されると、その曲の時刻も消えます（会員の完全削除でも同じ）
-- =====================================================================

begin;

do $$
begin
  if to_regprocedure('public.is_active_member()') is null or to_regclass('aimuse_private.account_deletions') is null then
    raise exception 'v1.9 が未適用です。何も変更せずに中止しました。';
  end if;
end $$;

create table if not exists public.track_lyrics_sync (
  track_id uuid primary key references public.tracks(id) on delete cascade,
  lines jsonb not null default '[]'::jsonb check (jsonb_typeof(lines) = 'array'),
  source text not null default 'manual' check (source in ('manual', 'auto', 'mixed')),
  lyrics_hash text not null,
  updated_by uuid,
  updated_at timestamptz not null default now()
);
alter table public.track_lyrics_sync enable row level security;
revoke all on public.track_lyrics_sync from public, anon, authenticated;

-- 歌詞の指紋（時刻を作った後に歌詞が変わったかの判定用）
create or replace function public.lyrics_hash(p_lyrics text[])
returns text
language sql immutable set search_path = ''
as $$ select md5(array_to_string(coalesce(p_lyrics, '{}'::text[]), E'\n', '')) $$;

-- 見出しの行か（行全体が [ ] か【 】で囲まれている）。アプリの判定と同じ
create or replace function public.lyrics_is_heading(p_line text)
returns boolean
language sql immutable set search_path = ''
as $$ select coalesce(p_line ~ '^\s*(\[[^\]]*\]|【[^】]*】)\s*$', false) $$;

create or replace function public.lyrics_sync_get(p_track uuid)
returns table (lines jsonb, source text, updated_at timestamptz, stale boolean)
language sql stable security definer set search_path = ''
as $$
  select s.lines, s.source, s.updated_at, s.lyrics_hash <> public.lyrics_hash(t.lyrics)
  from public.track_lyrics_sync s
  join public.tracks t on t.id = s.track_id
  where s.track_id = p_track
    and (t.status = 'public' or t.user_id = auth.uid() or public.is_admin());
$$;

create or replace function public.lyrics_sync_save(p_track uuid, p_lines jsonb)
returns jsonb
language plpgsql security definer set search_path = ''
as $$
declare
  v_t public.tracks;
  v_limit numeric;
  v_item jsonb;
  v_i int; v_ts numeric; v_te numeric;
  v_prev_i int := -1; v_prev_t numeric := 0; v_prev_e numeric := null;
  v_out jsonb := '[]'::jsonb;
  v_n int := 0;
  v_line text;
begin
  if not public.is_active_member() then
    raise exception 'NOT_ALLOWED: 同期を保存できるのは、ログイン中の会員だけです';
  end if;
  select * into v_t from public.tracks t where t.id = p_track for update;
  if not found then raise exception 'NOT_FOUND: 楽曲が見つかりません'; end if;
  if v_t.user_id is distinct from auth.uid() and not public.is_admin() then
    raise exception 'NOT_ALLOWED: 歌詞の同期を変更できるのは、投稿者本人と運営だけです';
  end if;
  if p_lines is null or jsonb_typeof(p_lines) <> 'array' then raise exception 'BAD_DATA: 形式が正しくありません'; end if;
  if jsonb_array_length(p_lines) > 1000 then raise exception 'BAD_DATA: 行が多すぎます'; end if;
  v_limit := case when v_t.duration > 0 then v_t.duration + 30 else 3600 end;

  for v_item in select x from jsonb_array_elements(p_lines) as x loop
    if jsonb_typeof(v_item) <> 'object'
       or exists (select 1 from jsonb_object_keys(v_item) k where k not in ('i', 't', 'e')) then
      raise exception 'BAD_DATA: 形式が正しくありません';
    end if;
    if coalesce(jsonb_typeof(v_item->'i'), '') <> 'number' or (v_item->>'i') !~ '^\d{1,4}$' then raise exception 'BAD_DATA: 行番号が正しくありません'; end if;
    v_i := (v_item->>'i')::int;
    if v_i >= coalesce(cardinality(v_t.lyrics), 0) then raise exception 'BAD_DATA: 行番号が歌詞の範囲外です'; end if;
    v_line := v_t.lyrics[v_i + 1];
    if v_line is null or btrim(v_line) = '' or public.lyrics_is_heading(v_line) then
      raise exception 'BAD_DATA: 空行・見出しには時刻を付けられません（%行目）', v_i + 1;
    end if;
    if v_i <= v_prev_i then raise exception 'BAD_DATA: 行の順番が正しくありません'; end if;
    if coalesce(jsonb_typeof(v_item->'t'), '') <> 'number' then raise exception 'BAD_DATA: 時刻が正しくありません'; end if;
    v_ts := round((v_item->>'t')::numeric, 2);
    if v_ts < 0 or v_ts > v_limit then raise exception 'BAD_DATA: 時刻が曲の長さの範囲外です（%行目）', v_i + 1; end if;
    if v_ts < v_prev_t or (v_prev_e is not null and v_ts < v_prev_e) then
      raise exception 'BAD_DATA: 時刻が前の行より前になっています（%行目）', v_i + 1;
    end if;
    v_te := null;
    if v_item ? 'e' and jsonb_typeof(v_item->'e') <> 'null' then
      if jsonb_typeof(v_item->'e') <> 'number' then raise exception 'BAD_DATA: 歌い終わりの時刻が正しくありません'; end if;
      v_te := round((v_item->>'e')::numeric, 2);
      if v_te <= v_ts or v_te > v_limit then raise exception 'BAD_DATA: 歌い終わりの時刻が正しくありません（%行目）', v_i + 1; end if;
    end if;
    v_out := v_out || jsonb_build_array(case when v_te is null then jsonb_build_object('i', v_i, 't', v_ts)
                                             else jsonb_build_object('i', v_i, 't', v_ts, 'e', v_te) end);
    v_prev_i := v_i; v_prev_t := v_ts; v_prev_e := v_te; v_n := v_n + 1;
  end loop;

  insert into public.track_lyrics_sync as s (track_id, lines, source, lyrics_hash, updated_by, updated_at)
  values (p_track, v_out, 'manual', public.lyrics_hash(v_t.lyrics), auth.uid(), now())
  on conflict (track_id) do update
    set lines = excluded.lines, source = excluded.source, lyrics_hash = excluded.lyrics_hash,
        updated_by = excluded.updated_by, updated_at = excluded.updated_at;
  return jsonb_build_object('count', v_n, 'updated_at', now());
end;
$$;

revoke all on function public.lyrics_hash(text[]) from public;
revoke all on function public.lyrics_is_heading(text) from public;
grant execute on function public.lyrics_hash(text[]) to anon, authenticated, service_role;
grant execute on function public.lyrics_is_heading(text) to anon, authenticated, service_role;
revoke all on function public.lyrics_sync_get(uuid) from public;
grant execute on function public.lyrics_sync_get(uuid) to anon, authenticated, service_role;
revoke all on function public.lyrics_sync_save(uuid, jsonb) from public, anon;
grant execute on function public.lyrics_sync_save(uuid, jsonb) to authenticated, service_role;

commit;
