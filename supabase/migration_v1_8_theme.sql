-- =====================================================================
-- AIMUSE v1.8 カラーテーマの保存（追加のみ）
-- Supabase の SQL Editor に全文を貼り付けて、1回実行してください。
--   ・前提：v1.5（構築）・v1.6（プロフィール）・v1.7（フォロー一覧）を実行済みであること。満たさなければ中止します
--   ・profiles に theme（テーマ設定）の列を1つ追加するだけ。既存のデータは削除・変更しません。何度実行しても壊れません
--   ・theme は本人と管理者だけが読める（profiles の既存のルールのまま）。公開用の関数では返しません
--   ・アプリから直接は書き換えられず、確認つきの関数 set_my_theme だけで変更できます
--   ・AIMUSE BOOST が使う is_admin()・profiles.is_admin・protect_profile_flags・tracks・covers・admin_stats は変更しません
-- =====================================================================

-- ---------- 0. 前提の確認 ----------
do $$
begin
  if to_regclass('public.profiles') is null then
    raise exception 'AIMUSE の構築SQL（v1.5）が未実行です。中止しました。';
  end if;
  if to_regprocedure('public.my_following(timestamptz,uuid,integer)') is null then
    raise exception 'フォロー一覧SQL（v1.7）が未実行です。先に v1.6・v1.7 を実行してください。中止しました。';
  end if;
end $$;

-- ---------- 1. テーマ設定の列 ----------
-- 形式：{"v":1, "preset":"standard|ocean|rose|emerald|gold|mono|custom", "accent":"#rrggbb", "bg":"#rrggbb", "button":"#rrggbb"}
-- これ以外の形（余分な項目・色以外の値・長い文字列など）は保存できません
alter table public.profiles add column if not exists theme jsonb;
do $$
begin
  if not exists (select 1 from pg_constraint where conname = 'profiles_theme_chk' and conrelid = 'public.profiles'::regclass) then
    alter table public.profiles add constraint profiles_theme_chk check (
      theme is null or (
        jsonb_typeof(theme) = 'object'
        and theme ?& array['v', 'preset', 'accent', 'bg', 'button']
        and (theme - array['v', 'preset', 'accent', 'bg', 'button']) = '{}'::jsonb
        and jsonb_typeof(theme -> 'v') = 'number' and theme ->> 'v' = '1'
        and jsonb_typeof(theme -> 'preset') = 'string'
        and theme ->> 'preset' in ('standard', 'ocean', 'rose', 'emerald', 'gold', 'mono', 'custom')
        and jsonb_typeof(theme -> 'accent') = 'string' and theme ->> 'accent' ~ '^#[0-9a-fA-F]{6}$'
        and jsonb_typeof(theme -> 'bg') = 'string'     and theme ->> 'bg'     ~ '^#[0-9a-fA-F]{6}$'
        and jsonb_typeof(theme -> 'button') = 'string' and theme ->> 'button' ~ '^#[0-9a-fA-F]{6}$'
      ));
  end if;
end $$;

-- アプリ（会員・未ログイン）に theme 列を直接書き換える権限を与えない（profiles の更新権限は従来どおり display_name だけ）
revoke update (theme) on public.profiles from anon, authenticated;

-- ---------- 2. 本人のテーマを保存する関数（null で未設定＝端末のテーマに戻す） ----------
create or replace function public.set_my_theme(p_theme jsonb)
returns void
language plpgsql security definer set search_path = ''
as $$
declare
  v_uid uuid := auth.uid();
begin
  if v_uid is null then
    raise exception 'ログインしてください';
  end if;
  begin
    update public.profiles set theme = p_theme where id = v_uid;
  exception when check_violation then
    raise exception 'テーマの形式が正しくありません';
  end;
  if not found then
    raise exception 'プロフィールが見つかりません';
  end if;
end;
$$;

revoke all on function public.set_my_theme(jsonb) from public, anon, authenticated;
grant execute on function public.set_my_theme(jsonb) to authenticated;

notify pgrst, 'reload schema';

-- =====================================================================
-- 完了
-- =====================================================================
