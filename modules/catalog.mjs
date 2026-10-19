// Discovery data only. Importing this file never loads a model, native library, or camera.
// `optional: true` marks a platform-specific helper; `doctor` with no component reports it without failing the core check.
export const components = [
  { id: 'recipes', title: 'Explore recipe guidance and books', runtime: 'Node.js', entry: 'modules/recipes/README.md', command: 'recipes knowledge --query "people in mixed light"', needs: ['node', 'tsx'], capability: 'Original setting rules, film-simulation profiles and directions, and your own recipe books; an optional private catalog via DIALIN_RECIPE_CATALOG. No camera or model needed.' },
  { id: 'plan', title: 'Plan a shoot', runtime: 'Node.js + your coding agent, or optional API key', entry: 'modules/planner/README.md', command: 'plan --help', needs: ['node', 'tsx', 'sdk'], capability: 'Agent handoff, validated answers, explicit API mode, and an offline fixture.' },
  { id: 'camera', title: 'Prepare and transfer your recipes', runtime: 'Node.js; optional USB driver for device operations', entry: 'modules/camera/README.md', command: 'camera --help', needs: ['node', 'tsx'], capability: 'Offline placement checks; explicit guarded USB operations. Modified Bluetooth writes remain blocked.' },
  { id: 'photos', title: 'Prepare a photo folder for your agent', runtime: 'Python + Pillow', entry: 'modules/photos/README.md', command: 'photos --help', needs: ['python', 'pillow'], capability: 'Capture-ordered contact sheets, previews, a label-keyed review sheet, stable identities and copy-only export. Originals stay in place.' },
  { id: 'curate', title: 'Validate and sequence a photo edit', runtime: 'Python standard library', entry: 'modules/curation/README.md', command: 'curate --help', needs: ['python'], capability: 'Uses supplied observations and constraints. Does not itself inspect image pixels.' },
  { id: 'import', title: 'Retrieve photos from a camera', runtime: 'Existing macOS camera helper (optional)', entry: 'modules/import/README.md', command: 'import --help', needs: ['macos', 'swift'], optional: true, capability: 'Desktop import wifi/usb/folder commands with JSON receipts; Bluetooth wake and Wi-Fi transfer use the explicitly built macOS helper. Without it, use an SD-card reader or your usual OS import.' },
  { id: 'demo', title: 'Rehearse the connected workflow', runtime: 'Node.js + Python', entry: 'README.md', command: 'demo --out .dialin/demo', needs: ['node', 'tsx', 'sdk', 'python'], capability: 'Original fixture through planning, camera preparation and metadata curation; device and visual judgments are not run. Writes a readable SUMMARY.md.' },
];

export function component(id) {
  const found = components.find((entry) => entry.id === id);
  if (!found) throw new Error(`Unknown component '${id}'. Choose ${components.map((entry) => entry.id).join(', ')}.`);
  return found;
}
