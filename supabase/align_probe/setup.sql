-- =====================================================================
-- 歌詞の自動同期の検証（lyrics-align-probe）の準備（追加のみ。既存のデータ・関数・ルールは変更しません）
--   ・呼び出しの合言葉（64文字）を金庫（Vault）に作る（表示しません）
--   ・合言葉の照合の関数 align_probe_secret_matches（service_role だけが実行でき、true/false だけを返す）
--   ・読み取りだけの関数 align_probe_track（曲の情報）・align_probe_is_admin（管理者か）。どちらも service_role だけ
--   ・何度実行しても同じ結果。片付けは teardown.sql
-- =====================================================================
begin;
do $$
begin
  if not exists (select 1 from vault.secrets where name = 'aimuse_align_probe_secret') then
    perform vault.create_secret(encode(extensions.gen_random_bytes(32), 'hex'), 'aimuse_align_probe_secret', 'AIMUSE 歌詞の自動同期の検証の合言葉');
  end if;
end $$;
create or replace function public.align_probe_secret_matches(p_secret text)
returns boolean
language plpgsql stable security definer set search_path = ''
as $$
declare v text;
begin
  if p_secret is null or char_length(p_secret) < 32 or to_regclass('vault.decrypted_secrets') is null then return false; end if;
  execute 'select decrypted_secret from vault.decrypted_secrets where name = $1 order by created_at desc limit 1' into v using 'aimuse_align_probe_secret';
  return v is not null and char_length(v) >= 32 and v = p_secret;
end;
$$;
revoke all on function public.align_probe_secret_matches(text) from public, anon, authenticated;
grant execute on function public.align_probe_secret_matches(text) to service_role;

-- 解析する曲の情報（読み取りだけ）。この DB では service_role に表の直接の読み取り権限が無いため、関数で渡す
--   ・検証の対象として決めた1曲（おぼろ月）だけ、しかも公開中のときだけ返す。ほかの曲の ID を渡しても何も返さない
--   ・返すのは曲名・歌詞・音源の保存場所・長さだけ（投稿者・会員の情報は含めない）
create or replace function public.align_probe_track(p_track uuid)
returns table (id uuid, title text, lyrics text[], audio_path text, duration integer)
language sql stable security definer set search_path = ''
as $$ select t.id, t.title, t.lyrics, t.audio_path, t.duration from public.tracks t
      where t.id = p_track and t.status = 'public'
        and t.id = any (array['8ff6cf08-3d73-40b7-8dbc-4b09bac917cc']::uuid[]) $$;
revoke all on function public.align_probe_track(uuid) from public, anon, authenticated;
grant execute on function public.align_probe_track(uuid) to service_role;

-- 管理者か（読み取りだけ。true/false だけを返す。利用停止中は false。名前・メールなどは返さない）
create or replace function public.align_probe_is_admin(p_user uuid)
returns boolean
language sql stable security definer set search_path = ''
as $$ select coalesce((select p.is_admin and not p.is_banned from public.profiles p where p.id = p_user), false) $$;
revoke all on function public.align_probe_is_admin(uuid) from public, anon, authenticated;
grant execute on function public.align_probe_is_admin(uuid) to service_role;
commit;
select (select count(*) from vault.secrets where name = 'aimuse_align_probe_secret') as "金庫の合言葉（1なら正常）",
       has_function_privilege('anon', 'public.align_probe_secret_matches(text)', 'execute')
         or has_function_privilege('anon', 'public.align_probe_track(uuid)', 'execute')
         or has_function_privilege('authenticated', 'public.align_probe_track(uuid)', 'execute')
         or has_function_privilege('authenticated', 'public.align_probe_is_admin(uuid)', 'execute') as "会員・未ログインが実行できる（false なら正常）";
