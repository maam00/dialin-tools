// Shared with FilmKit's session.ts (not vendored — we use our own Node USB transport).
export interface RawProp {
  id: number
  name: string
  bytes: Uint8Array
  value: number | string
}
