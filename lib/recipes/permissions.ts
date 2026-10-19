import type { RawRecipeRecord } from "./types.js";

/** Private public-fact research was explicitly requested by the workspace owner; this is not a creator license. */
export type RecipeUseMode = "private_research" | "permission_reviewed";

/** A reviewed, server-side record of permission. Neither an HTTP body nor a model answer is a grant. */
export type RecipeUsageGrant = {
  record_id: string;
  content_sha256: string;
  scopes: ("model_context" | "training")[];
  permission_evidence: string;
  reviewed_by: string;
  reviewed_at: string;
  expires_at?: string;
};

export function recipeUsage(record: RawRecipeRecord, scope: RecipeUsageGrant["scopes"][number],
  grants: readonly RecipeUsageGrant[], now = Date.now(), mode: RecipeUseMode = "permission_reviewed"): { allowed: boolean; reason: string } {
  if (mode === "private_research" && record.source_scope === "public_web_facts") {
    return { allowed: true, reason: "Owner-authorized private research on public setting facts; creator usage permission remains unverified." };
  }
  for (const grant of grants) {
    if (grant.record_id !== record.id || grant.content_sha256 !== record.content_sha256) continue;
    const reviewed = Date.parse(grant.reviewed_at);
    const expires = grant.expires_at === undefined ? Infinity : Date.parse(grant.expires_at);
    if (!/^[a-f0-9]{64}$/.test(grant.content_sha256) || !Number.isFinite(reviewed) || reviewed > now
      || !(expires > now) || !grant.reviewed_by?.trim() || !grant.permission_evidence?.trim()) continue;
    if (Array.isArray(grant.scopes) && grant.scopes.includes(scope)) return { allowed: true, reason: "Reviewed permission matches this record and source revision." };
  }
  return { allowed: false, reason: `No current, reviewed ${scope} permission for this exact source record.` };
}
