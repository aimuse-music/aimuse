// AIMUSE の接続設定
// Supabase プロジェクト作成後、Project URL と公開用キー（anon / publishable key）をここに入れます。
// 公開用キーはブラウザに公開される前提のキーで、データの保護はデータベース側のルール（RLS）で行います。
// 「service_role」や「secret」キーは絶対にここへ入れないでください。
window.AIMUSE_CONFIG = {
  supabaseUrl: "https://tqtrvjmjfthlrwwligmu.supabase.co",
  supabaseAnonKey: "sb_publishable_p1C-sr805QLLx4LARKcFcw_NFzm3r1H",
  // 機能スイッチ（公開の段階に合わせて運営者が切り替えます。true 以外はすべてオフ）
  features: {
    pwa: false,              // ホーム画面に追加（PWA）。オフの間は登録済みの Service Worker も解除
    accountDeletion: false   // 退会の申請画面。オフでも、退会手続き中の方の状況表示と取り消しは使えます
  }
};
