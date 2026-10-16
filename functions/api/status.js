// 接続状況（秘密の値そのものは返さず、「設定済みかどうか」だけを返します）
import { cfg, json } from "../../lib/shared.js";
import { AI_MODEL } from "./generate.js";

export const onRequestGet = ({ env }) => {
  const c = cfg(env);
  return json({
    app: "AIMUSE BOOST",
    version: "0.1",
    ai: { connected: !!(env && env.AI && typeof env.AI.run === "function"), provider: "Cloudflare Workers AI", model: AI_MODEL },
    aimuseUrlSet: !!c.aimuseUrl,
  });
};
