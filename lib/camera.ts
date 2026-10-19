// Fujifilm X100VI dial positions. These are the only values the model may return,
// enforced through the JSON schema enums, so every card is something you can physically dial.

export const SLOTS = ["C1", "C2", "C3", "C4", "C5", "C6", "C7"] as const;

// Aperture ring clicks in 1/3 stops; full stops are printed on the ring.
export const APERTURES = [
  "A",
  "f/2", "f/2.2", "f/2.5", "f/2.8", "f/3.2", "f/3.6", "f/4", "f/4.5", "f/5",
  "f/5.6", "f/6.4", "f/7.1", "f/8", "f/9", "f/10", "f/11", "f/13", "f/14", "f/16",
] as const;

// Shutter dial positions (full stops). Slower than 1s lives on T, which we spell out.
export const SHUTTERS = [
  "A",
  "1/4000", "1/2000", "1/1000", "1/500", "1/250", "1/125", "1/60", "1/30",
  "1/15", "1/8", "1/4", "1/2", "1s", "2s", "4s", "8s",
] as const;

// ISO dial (lift and turn on the shutter dial), 1/3 stops. "A" = Auto ISO.
export const ISOS = [
  "A", "125", "160", "200", "250", "320", "400", "500", "640", "800", "1000", "1250",
  "1600", "2000", "2500", "3200", "4000", "5000", "6400", "8000", "10000", "12800",
] as const;

export const EXP_COMPS = [
  "-3", "-2⅔", "-2⅓", "-2", "-1⅔", "-1⅓", "-1", "-⅔", "-⅓", "0",
  "+⅓", "+⅔", "+1", "+1⅓", "+1⅔", "+2", "+2⅓", "+2⅔", "+3",
] as const;

export const INTENTS = [
  "Portrait", "Street", "Silhouette", "Motion blur", "Freeze action", "Low light", "Landscape",
] as const;

export type Intent = (typeof INTENTS)[number];

export { X100VI_FACTS as CAMERA_FACTS } from "./fuji/camera-facts.js";
