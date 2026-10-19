// Shared physical-control facts for modern and legacy planner entry points.
// X100VI owner manual: https://fujifilm-dsc.com/en-int/manual/x100vi/
export const X100VI_FACTS = `
FUJIFILM X100VI: what the user can physically set (verified against the owner's manual)
- Lens: fixed 23mm f/2 (35mm-equivalent field of view), close focus about 10cm. Choose depth of field for intent; don't promise lens character from a rendering recipe.
- Aperture ring: f/2 to f/16 in 1/3 stops, plus "A". Full stops are printed: 2, 2.8, 4, 5.6, 8, 11, 16. Prefer printed values.
- Shutter dial: A, 1/4000 … 1s in full stops, plus T for longer.
- Leaf shutter limit (mechanical): 1/2000 from f/2 through f/4, 1/4000 from f/4.5 down. Never recommend a faster mechanical speed than that for the chosen aperture; turn the ND on instead.
- Electronic shutter goes much faster but bends fast motion and bands under LED/neon. Avoid it; the ND is the answer to too much light.
- ISO dial (lift and turn the shutter dial's outer ring): A (Auto ISO), standard ISO 125 to 12800. Noise/detail depend on exposure, processing and delivery. The suggested Auto ISO maximum 6400 is a user-configured baseline; do not assume it is already set.
- Exposure comp dial: -3 to +3 in 1/3 stops. It only does something when at least one of aperture / shutter / ISO is on A. In full manual (all three set), use "0".
- Built-in 4-stop ND filter on a function button.
- In-body stabilization assists camera shake, not subject motion. Slow handheld speeds need technique and review; they are not guaranteed. For freezing ordinary motion, start around 1/250 or faster, and faster for sport/kids/pets; intentional motion blur is a different goal.
- Each look has a minimum ISO (DR400 = ISO 500+, DR200 = ISO 250+). Never recommend a fixed ISO below the chosen look's minimum; in bright light that usually means ND on.
- Custom banks can contain more than color recipes. Dial In currently writes/verifies its supported rendering fields; do not claim it sets or checks every saved bank option, Auto ISO, focus/drive or the active bank. Physical dials remain physical. ND state must be checked: a filter left On reduces available light by four stops.
`.trim();
