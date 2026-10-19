import type { RecipeFields } from "../plan/types.js";

export type RawRecipeRecord = {
  id: string;
  title: string;
  article_title?: string;
  variant_name?: string | null;
  source_url: string | null;
  groups: string[];
  fetched_at: string | null;
  content_sha256: string | null;
  settings: Record<string, string>;
  status: "public_settings" | "linked_only" | "unavailable" | "ambiguous";
  notes: string[];
  source_scope: "public_web_facts";
  training_permission: "not_verified";
};

export type NativeFilmSimulation = "Provia" | "Velvia" | "Astia" | "Classic Chrome" | "Reala Ace" | "Pro Neg Hi"
  | "Pro Neg Std" | "Classic Neg" | "Nostalgic Neg" | "Eterna" | "Eterna Bleach Bypass" | "Acros" | "Acros+Ye"
  | "Acros+R" | "Acros+G" | "Monochrome" | "Monochrome+Ye" | "Monochrome+R" | "Monochrome+G" | "Sepia";
export type NativeWhiteBalance = "Auto" | "Auto White Priority" | "Auto Ambience" | "Daylight" | "Shade"
  | "Fluorescent 1" | "Fluorescent 2" | "Fluorescent 3" | "Incandescent" | "Kelvin" | "Underwater"
  | "Custom 1" | "Custom 2" | "Custom 3";
export type NativeRecipeSettings = {
  grain_strength?: "Off" | "Weak" | "Strong";
  grain_size?: "Small" | "Large";
  auto_wb_priority?: "White" | "Ambience";
  dynamic_range_auto?: true;
  dr_priority?: "Off" | "Weak" | "Strong" | "Auto";
  smooth_skin?: "Off" | "Weak" | "Strong";
  mono_wc?: number;
  mono_mg?: number;
  iso?: number | "Auto";
  iso_auto_max?: number;
  iso_min?: number;
  iso_max?: number;
  exposure_compensation?: number;
  exposure_compensation_min?: number;
  exposure_compensation_max?: number;
  long_exposure_nr?: "On" | "Off";
  color_space?: "sRGB" | "Adobe RGB";
};

export type RecipeSettingKey = Exclude<keyof RecipeFields, "name" | "why">;
export type NormalizedSettingKey = RecipeSettingKey | keyof NativeRecipeSettings;
export type NormalizationIssue = {
  code: "source_status" | "unknown_label" | "unknown_value" | "ambiguous_value" | "conflicting_values"
    | "source_unavailable" | "missing_field" | "out_of_range" | "unsupported_camera_value" | "manual_mapping"
    | "unconfirmed_code" | "dependent_setting";
  severity: "needs_review" | "manual_mapping";
  field: NormalizedSettingKey | null;
  message: string;
  raw_labels: string[];
  raw_values: string[];
};
export type NormalizedSettingFact = {
  field: NormalizedSettingKey | null;
  label: string;
  value: string;
  status: "parsed" | "ambiguous" | "unrecognized" | "unavailable" | "metadata";
  normalized_value?: string | number | boolean;
  alternatives?: string[];
};

export type NormalizedRecipe = {
  /** The creator recipe version remains separate from its underlying Fujifilm simulation. */
  id: string;
  title: string;
  base_film_sim: NativeFilmSimulation | null;
  fields: Partial<RecipeFields>;
  native: NativeRecipeSettings;
  /** Source navigation/sensor groups are provenance, never a compatibility assertion. */
  source_groups: string[];
  raw: RawRecipeRecord;
  facts: NormalizedSettingFact[];
  issues: NormalizationIssue[];
  missing_fields: RecipeSettingKey[];
  inactive_fields: RecipeSettingKey[];
  /** Completeness of the published core transcription, independent of native baseline/readback requirements. */
  published_core: { complete: boolean; missing_fields: RecipeSettingKey[] };
  unavailable_fields: NormalizedSettingKey[];
  status: "normalized" | "needs_review" | "no_public_settings";
  /** Public accessibility is not verified permission to export a training set. */
  training_export_allowed: false;
};

export type RecipeCameraAssessment = {
  camera_model: string;
  published_core: NormalizedRecipe["published_core"];
  /** Complete source facts and native menu legality, not a claim about equal rendering across bodies. */
  exact_settings: { eligible: boolean; issues: NormalizationIssue[] };
  /** Current app representation and confirmed codes; not a successful upload or runtime authorization. */
  new_write: { supported: boolean; issues: NormalizationIssue[] };
  automatic_adaptation: {
    changes: { field: "clarity"; from: number; to: 0; changes_creator_recipe: true }[];
    requires_confirmation: boolean;
  };
  training_export_allowed: false;
  photographic_equivalence_verified: false;
};
