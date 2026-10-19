import type { CameraCaps } from "../cameras.js";
import { recipeOf, recipeProblems } from "./looks.js";
import { expertSettingsSignature } from "./expert-metadata.js";
import type { RecipeFields } from "./types.js";

export type RecipePreference = "favorite" | "avoid";
export type FavoriteRecipe = { recipe_id: string; recipe: RecipeFields; purpose: string; note: string; preference: RecipePreference };
/** User-selected exact versions. Names and photo timing are never evidence of recipe identity. */
export function favoriteRecipes(taste: unknown, cam: CameraCaps): FavoriteRecipe[] {
  const raw = taste && typeof taste === "object" ? (taste as Record<string, unknown>).favorites : null;
  if (!Array.isArray(raw)) return [];
  const seen = new Set<string>();
  return raw.slice(0, 8).flatMap((value) => {
    if (!value || typeof value !== "object") return [];
    const f = value as Record<string, unknown>;
    if (!f.recipe || typeof f.recipe !== "object" || typeof f.recipe_id !== "string" || !/^[a-f0-9]{64}$/.test(f.recipe_id)) return [];
    // An invalid explicit preference must not quietly become a positive favorite.
    const preference = f.preference === undefined ? "favorite" : typeof f.preference === "string" ? f.preference.trim().toLowerCase() : null;
    if (preference !== "favorite" && preference !== "avoid") return [];
    const recipe = recipeOf(f.recipe as Record<string, unknown>);
    if (recipeProblems(recipe, cam).length) return [];
    // Preserve an explicit conflict for review instead of choosing one preference silently.
    const identity = `${preference}:${expertSettingsSignature(recipe)}`;
    if (seen.has(identity)) return [];
    seen.add(identity);
    const text = (s: unknown) => typeof s === "string" ? s.replace(/\0/g, "").trim().slice(0, 300) : "";
    return [{ recipe_id: f.recipe_id, recipe, purpose: text(f.purpose), note: text(f.note), preference }];
  });
}

export function favoriteContext(favorites: FavoriteRecipe[]): string {
  if (!favorites.length) return "";
  const liked = favorites.filter((f) => f.preference === "favorite");
  const avoided = favorites.filter((f) => f.preference === "avoid");
  return ["EXPLICIT TASTE RECIPE VERSIONS (chosen by this photographer, not inferred from photo hearts).",
    ...(liked.length ? ["FAVORITE EXACT VERSIONS", ...liked.map((f) => JSON.stringify(f))] : []),
    ...(avoided.length ? ["AVOIDED EXACT VERSIONS", ...avoided.map((f) => JSON.stringify(f))] : []),
    "Their current explicit words take priority over saved favorites and avoids. Use favorites as positive taste evidence when relevant; adapt for the scene and disclose the tradeoff. "
      + "An avoid is strong, reviewable negative taste context for the supplied exact version and note. Steer away when relevant, but do not turn it into a blanket hard exclusion of a simulation, setting, name or style. "
      + "If today's explicit request calls for an avoided version, honor the current intent and disclose the saved preference conflict. If the same exact settings appear as both favorite and avoid, explain the ambiguity; do not invent confidence or silently choose a side. "
      + "Neither preference grants permission to overwrite, relocate, remove or change a camera slot; protected settings stay exact even if avoided. "
      + "Names are not recipe identity; do not reuse by name unless a matching recipe is independently supplied in the camera/past-look library. Never infer an avoid from hearts, a low keep rate or missing favorites. Never invent photo counts or a learned preference."] .join("\n");
}
