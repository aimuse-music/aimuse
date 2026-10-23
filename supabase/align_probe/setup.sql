-- =====================================================================
-- 歌詞の自動同期の検証（lyrics-align-probe）の準備（追加のみ。既存のデータ・関数・ルールは変更しません）
--   ・呼び出しの合言葉（64文字）を金庫（Vault）に作る（表示しません）
--   ・合言葉の照合の関数 align_probe_secret_matches（service_role だけが実行でき、true/false だけを返す）
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
commit;
select (select count(*) from vault.secrets where name = 'aimuse_align_probe_secret') as "金庫の合言葉（1なら正常）",
       has_function_privilege('anon', 'public.align_probe_secret_matches(text)', 'execute') as "未ログインが実行できる（false なら正常）";
