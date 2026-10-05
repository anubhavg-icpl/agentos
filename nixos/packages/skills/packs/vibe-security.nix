# raroque/vibe-security-skill: audits AI-written ("vibe-coded") apps for the
# security mistakes assistants tend to make: exposed API keys, broken access
# control (Supabase RLS, Firebase rules), insecure auth, missing rate limits.
# One skill with reference notes. Markdown only.
{ mkSkillPack, sources }:

mkSkillPack {
  pack = "vibe-security";
  version = "0-unstable-2026-10-05";
  src = sources.vibe-security;
  skills.vibe-security = "vibe-security";
  description = "Security audit of AI-written apps: leaked keys, broken access control, insecure auth, rate limits";
  homepage = "https://github.com/raroque/vibe-security-skill";
  license = "MIT";
  collections = [ "community" "security" ];
  defaultEnable = false;
  notes = "Markdown only; no network, tools or keys.";
}
