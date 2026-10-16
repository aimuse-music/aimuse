// AIMUSE BOOST の接続設定
// ・Supabase は AIMUSE と同じプロジェクトを使います（公開用キー。データはRLSで保護）
// ・「service_role」や「secret」キーは絶対にここへ入れないでください
// ・aimuseUrl：宣伝リンクの移動先になる AIMUSE の公開URL（例："https://xxxx.pages.dev"）
//   空欄のあいだは、計測リンクを作らずに文章だけコピーできます
window.BOOST_CONFIG = {
  supabaseUrl: "https://tqtrvjmjfthlrwwligmu.supabase.co",
  supabaseAnonKey: "sb_publishable_p1C-sr805QLLx4LARKcFcw_NFzm3r1H",
  aimuseUrl: "https://aimusemusic.com"
};
