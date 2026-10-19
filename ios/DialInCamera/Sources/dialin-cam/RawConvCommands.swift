// dialin-cam rawconv: genuine-Fuji alternates of a photo, rendered by the X100VI itself from its own RAF.
// Only the camera's RAW-conversion profile (D185) changes; C1–C7 are never read or written, so nothing is backed up.
// Engine: DialInCamera/RawConv (FujiRawConverter, D185Patch).
#if os(macOS)
import CryptoKit
import DialInCamera
import Foundation

@MainActor
enum RawConvCLI {
    static let commands: Set<String> = ["rawconv"]

    static let usage = """
        dialin-cam rawconv <file.RAF> [--unchanged] [--recipe look.json] [--variants variants.json] [--out dir]
            Camera: CONNECTION MODE › USB RAW CONV./BACKUP RESTORE, charged, USB-C data cable. Uploads the RAF once, then
            renders each variant in the camera and writes <photo>__<variant>.jpg + renders.json into --out
            (default ~/Pictures/Dial In/colorlab/<photo>/renders). Never touches C1–C7.
          --unchanged              re-render with the camera's own profile, untouched (fidelity test vs the camera JPEG);
                                   the default when no recipe/variants are given
          --recipe look.json       a whole look (Recipe JSON)
          --variants v.json        candidates from tools/colorlab/propose.py (its "raf" is used when no RAF is given)
          --start 0|1|both         D183 value that starts a render: 0 = preview conversion (the shot's own
                                   size; default), 1 = full conversion (honours image_size, e.g. "M" = 5472 px)
          --thumb                  download only the camera's small preview of each render (GetThumb), falls back to full
          --repeat N               render the list N times (timing / wedge test); files kept for pass 1 unless --keep-repeats
          --exposure-index 4|5     where exposure bias lives in D185 (full map: 5; only needed with --layout filmkit)
          --layout full|filmkit|layout.json   D185 field map: full = the complete 29-field map (not yet tried on the camera),
                                   filmkit = the indices verified on an X100VI (default), or a JSON of indices (keys as in renders.json)
          --photo SOOC.JPG         the camera JPEG to compare against (default: the RAF's sibling .JPG)
          --render-timeout S       give up on a render after S seconds (default 30) — then power-cycle the camera
          --poll-ms N              GetObjectHandles poll interval (default 100)
          --dry-run [--profile base.d185.bin]   no camera: show each variant's patch against a saved profile
          --rehearse               the whole run against a built-in fake camera; its "renders" are the RAF's embedded
                                   camera JPEG and are labelled REHEARSAL (never Fuji re-renders)
          --verbose  --timeout S (wait for the camera, default 30)  --catalog S (default 15)
        """

    struct Args {
        var positional: [String] = []
        var flags: Set<String> = []
        var values: [String: String] = [:]

        static let valued: Set<String> = [
            "--recipe", "--variants", "--out", "--start", "--repeat", "--exposure-index", "--layout", "--photo",
            "--render-timeout", "--poll-ms", "--profile", "--timeout", "--catalog",
        ]

        init(_ argv: [String]) {
            var it = argv.dropFirst().makeIterator()   // argv[0] is the command name
            while let a = it.next() {
                if Self.valued.contains(a) {
                    values[a] = it.next() ?? ""
                } else if a.hasPrefix("-") {
                    flags.insert(a == "-v" ? "--verbose" : a)
                } else {
                    positional.append(a)
                }
            }
        }

        func int(_ k: String) -> Int? { values[k].flatMap { Int($0) } }
        var verbose: Bool { flags.contains("--verbose") }
    }

    struct Job {
        var variant: RenderVariant
        var start: FujiRawConverter.StartValue
        var pass: Int
        var keep: Bool
    }

    static func run(_ argv: [String]) async throws {
        let a = Args(argv)
        if a.flags.contains("--help") || a.flags.contains("-h") { print(usage); return }

        // Inputs.
        var variantsFile: VariantsFile?
        var variantsDir: URL?
        if let path = a.values["--variants"] {
            let url = URL(fileURLWithPath: path)
            variantsFile = try VariantsFile.decode(Data(contentsOf: url))
            variantsDir = url.deletingLastPathComponent()
        }
        func resolve(_ p: String, from dir: URL?) -> URL {
            p.hasPrefix("/") || p.hasPrefix("~") || dir == nil
                ? URL(fileURLWithPath: (p as NSString).expandingTildeInPath)
                : dir!.appendingPathComponent(p)
        }
        guard let rafPath = a.positional.first.map({ URL(fileURLWithPath: $0) }) ?? variantsFile?.raf.map({ resolve($0, from: variantsDir) }) else {
            throw RawConvError.invalidSettings("rawconv needs a .RAF (or a variants.json with \"raf\")\n\n\(usage)")
        }
        let head = try FileHandle(forReadingFrom: rafPath).read(upToCount: 64) ?? Data()
        guard let rafModel = RAFHeader.model(head) else { throw RawConvError.notRAF("\(rafPath.path) has no FUJIFILMCCD-RAW header") }
        let rafBytes = (try? FileManager.default.attributesOfItem(atPath: rafPath.path)[.size] as? Int) ?? 0
        let name = rafPath.deletingPathExtension().lastPathComponent
        let photo: URL? = a.values["--photo"].map { URL(fileURLWithPath: $0) }
            ?? variantsFile?.photo.map { resolve($0, from: variantsDir) }
            ?? ["JPG", "jpg", "JPEG", "jpeg"].map { rafPath.deletingPathExtension().appendingPathExtension($0) }
                .first { FileManager.default.fileExists(atPath: $0.path) }

        var variants: [RenderVariant] = []
        let wantUnchanged = a.flags.contains("--unchanged")
        if let r = a.values["--recipe"] {
            let recipe = try JSONDecoder().decode(Recipe.self, from: Data(contentsOf: URL(fileURLWithPath: r)))
            variants.append(RenderVariant(name: RenderVariant.slug(recipe.name), label: recipe.name, kind: "recipe",
                                          why: recipe.why.isEmpty ? nil : recipe.why, settings: RenderSettings(recipe: recipe)))
        }
        variants += variantsFile?.variants ?? []
        if wantUnchanged || variants.isEmpty {
            variants.removeAll { $0.settings.isEmpty }
            variants.insert(.unchanged, at: 0)
            if !wantUnchanged { print("no --recipe/--variants: rendering the unchanged profile (fidelity test)") }
        }
        var seen: [String: Int] = [:]
        for i in variants.indices {
            var n = RenderVariant.slug(variants[i].name)
            seen[n, default: 0] += 1
            if seen[n]! > 1 { n += "-\(seen[n]!)" }
            variants[i].name = n
            do { try variants[i].settings.validate() } catch { throw RawConvError.invalidSettings("variant \(n): \(error)") }
        }

        // filmkit stays the default until the full map is verified on the camera
        var layout = D185Layout.filmKit
        if let l = a.values["--layout"] {
            layout = try D185Layout.named(l) ?? JSONDecoder().decode(D185Layout.self, from: Data(contentsOf: URL(fileURLWithPath: l)))
        }
        if let e = a.int("--exposure-index") { layout.exposureBias = e }

        let starts: [FujiRawConverter.StartValue] = switch a.values["--start"] ?? "0" {
        case "1": [.one]
        case "both": [.zero, .one]
        default: [.zero]
        }
        let passes = max(1, a.int("--repeat") ?? 1)
        let keepRepeats = a.flags.contains("--keep-repeats")
        let thumb = a.flags.contains("--thumb")
        let rehearse = a.flags.contains("--rehearse")
        let dryRun = a.flags.contains("--dry-run")

        let defaultOut = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Pictures/Dial In/colorlab/\(name)/renders")
        let out = a.values["--out"].map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) } ?? defaultOut
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

        let renderedBy = dryRun ? "DRY RUN: no camera, nothing rendered"
            : rehearse ? "REHEARSAL fake camera: these files are the RAF's embedded camera JPEG, NOT re-renders"
            : "\(rafModel) in-camera RAW conversion"
        var manifest = RenderManifest(
            createdAt: ISO8601DateFormatter().string(from: Date()), renderedBy: renderedBy, rehearsal: rehearse, dryRun: dryRun,
            source: .init(name: name, raf: rafPath.path, rafBytes: rafBytes, photo: photo?.path))
        let manifestURL = out.appendingPathComponent("renders.json")

        print("\(name).RAF · \(rafModel) · \(String(format: "%.1f", Double(rafBytes) / 1_048_576)) MB · \(variants.count) variant(s) × \(starts.count) start value(s) × \(passes) pass(es)")
        if let photo { print("camera JPEG: \(photo.path)") } else { print("camera JPEG: not found (pass --photo for compare.py)") }
        print("out: \(out.path)")

        if dryRun {
            try dryRunPatches(a, variants: variants, layout: layout, manifest: &manifest, out: out)
            try manifest.jsonData().write(to: manifestURL)
            print("wrote \(manifestURL.path) (dry run, no images)")
            return
        }

        // Camera (or the fake).
        let transport: any PTPTransport
        if rehearse {
            let raf = try Data(contentsOf: rafPath)
            var cfg = FakeRawConvCamera.Config()
            cfg.model = rafModel
            cfg.pollsUntilReady = 3
            if let jpg = RAFHeader.embeddedJPEG(raf) { cfg.renderBytes = jpg; cfg.thumbBytes = jpg }
            transport = FakeRawConvCamera(config: cfg)
            print("REHEARSAL: fake camera, nothing leaves this Mac and nothing is rendered")
        } else {
            let ic = ImageCaptureTransport(catalogTimeout: .seconds(a.int("--catalog") ?? 15))
            if a.verbose { ic.trace = { print("  · \($0)") } }
            transport = ic
        }
        let timing = FujiRawConverter.Timing(
            pollInterval: .milliseconds(a.int("--poll-ms") ?? 100), renderTimeout: .seconds(a.int("--render-timeout") ?? 30))
        let conv = FujiRawConverter(transport: transport, timing: timing, log: { print("  \($0)") })

        print("looking for the camera on USB (up to \(a.int("--timeout") ?? 30)s)…")
        let t0 = ContinuousClock.now
        do {
            let info = try await conv.connect(timeout: .seconds(a.int("--timeout") ?? 30))
            manifest.camera = info
            print("\(info.model) fw \(info.firmware) · USB mode \(info.usbMode.map(String.init) ?? "?") · "
                + (info.identity.isEmpty ? "" : info.identity.map { "\($0.key) \($0.value)" }.joined(separator: " · ") + " · ")
                + "connected in \(ms(since: t0))")

            // Upload + base profile.
            print("uploading \(name).RAF…")
            let load = try await conv.loadRaf(url: rafPath)
            manifest.upload = load.steps
            print("  " + load.steps.map(\.line).joined(separator: " · "))
            let base = load.profile
            let profileFile = "\(name).d185.bin"
            try base.bytes.write(to: out.appendingPathComponent(profileFile))
            let section = RenderManifest.profileSection(base, layout: layout, file: profileFile)
            manifest.profile = section
            if rehearse { print("(REHEARSAL: this is the fake camera's SYNTHETIC profile, not your camera's)") }
            printProfile(base, section)

            // Render.
            var jobs: [Job] = []
            for pass in 1...passes {
                for v in variants { for s in starts { jobs.append(Job(variant: v, start: s, pass: pass, keep: pass == 1 || keepRepeats)) } }
            }
            for (i, job) in jobs.enumerated() {
                let tag = job.variant.name + (starts.count > 1 ? " d183=\(job.start.rawValue)" : "") + (passes > 1 ? " #\(job.pass)" : "")
                var rec = RenderManifest.Record(variant: job.variant, pass: job.pass, thumbnail: thumb, startValue: job.start.rawValue)
                do {
                    let (r, patch) = try await conv.render(job.variant.settings, layout: layout, start: job.start, thumbnail: thumb)
                    rec.changes = patch.changes
                    rec.notes = patch.notes
                    rec.steps = r.steps
                    rec.totalMs = r.totalMs
                    rec.bytes = r.data.count
                    rec.imageKind = r.kind
                    rec.thumbnail = r.thumbnail
                    rec.sha256 = SHA256.hash(data: r.data).map { String(format: "%02x", $0) }.joined()
                    if let size = JPEGSize.of(r.data) { rec.width = size.width; rec.height = size.height }
                    if job.keep {
                        var file = "\(name)__\(job.variant.name)"
                        if starts.count > 1 { file += ".d183-\(job.start.rawValue)" }
                        if job.pass > 1 { file += ".p\(job.pass)" }
                        if r.thumbnail { file += ".thumb" }
                        if rehearse { file += ".REHEARSAL" }
                        file += "." + r.kind.fileExtension
                        try r.data.write(to: out.appendingPathComponent(file))
                        rec.file = file
                    }
                    var line = "[\(i + 1)/\(jobs.count)] \(tag): " + r.steps.map(\.line).joined(separator: " · ")
                    line += String(format: " · total %.2fs", r.totalMs / 1000)
                    if let w = rec.width, let h = rec.height { line += " · \(w)×\(h)" }
                    if r.kind != .jpeg { line += " · \(r.kind.rawValue.uppercased())!" }
                    if let f = rec.file { line += " → \(f)" }
                    print(line)
                    if !patch.changes.isEmpty {
                        print("        changed: " + patch.changes.map { "[\($0.index)] \($0.field) \($0.from)→\($0.to)" }.joined(separator: ", "))
                    }
                    for n in patch.notes { print("        note: \(n)") }
                } catch let e as RawConvError {
                    rec.error = e.description
                    manifest.variants.append(rec)
                    if e.isWedge {
                        manifest.aborted = e.description
                        manifest.timing = .from(upload: manifest.upload, records: manifest.variants)
                        try manifest.jsonData().write(to: manifestURL)
                        print("[\(i + 1)/\(jobs.count)] \(tag): WEDGED. Saved what was done: \(manifestURL.path)")
                        await conv.disconnect()
                        throw e
                    }
                    print("[\(i + 1)/\(jobs.count)] \(tag): FAILED: \(e.description)")
                    continue
                }
                manifest.variants.append(rec)
            }
        } catch {
            if manifest.aborted == nil {
                manifest.aborted = "\(error)"
                manifest.timing = .from(upload: manifest.upload, records: manifest.variants)
                try? manifest.jsonData().write(to: manifestURL)
            }
            await conv.disconnect()
            throw error
        }
        await conv.disconnect()

        manifest.timing = .from(upload: manifest.upload, records: manifest.variants)
        try manifest.jsonData().write(to: manifestURL)
        if let t = manifest.timing {
            print(String(format: "timing: upload %@ · first render %@ · later renders %@ (min %@, max %@) · %d rendered%@",
                         fmt(t.uploadMs), fmt(t.firstRenderMs), fmt(t.laterMeanMs), fmt(t.laterMinMs), fmt(t.laterMaxMs), t.renders,
                         t.deterministic.map { $0 ? " · repeats byte-identical" : " · repeats DIFFER byte-wise" } ?? ""))
        }
        print("wrote \(manifestURL.path)")
        let colorlab = "tools/colorlab"
        if let photo, let f = manifest.variants.first(where: { $0.name == "unchanged" && $0.file != nil })?.file {
            print("next: python3 \(colorlab)/diff.py \(photo.path) \(out.appendingPathComponent(f).path)   (fidelity)")
        }
        print("      python3 \(colorlab)/compare.py \(manifestURL.path)")
    }

    // MARK: Pieces

    static func printProfile(_ p: D185Profile, _ s: RenderManifest.Profile) {
        print("profile D185: \(p.bytes.count) bytes · \(p.count) params at offset \(p.paramsOffset) · IOP \"\(p.iopCode)\"")
        for i in 0..<p.count {
            let v = p[i]
            print(String(format: "  [%2d] %11d  0x%08X  ", i, v, UInt32(bitPattern: v)) + s.labels[i])
        }
        print("as shot (FilmKit decode): \(s.asShot.line)")
        print("exposure index \(s.exposureIndex.index) (\(s.exposureIndex.confident ? "confident" : "GUESS")): \(s.exposureIndex.evidence)")
    }

    static func dryRunPatches(_ a: Args, variants: [RenderVariant], layout: D185Layout, manifest: inout RenderManifest, out: URL) throws {
        let base: D185Profile
        if let path = a.values["--profile"] {
            base = try D185Profile(Data(contentsOf: URL(fileURLWithPath: path)))
            print("profile: \(path)")
        } else {
            base = try D185Profile(FakeRawConvCamera.sampleProfile())
            print("profile: the built-in SYNTHETIC sample (pass --profile <photo>.d185.bin from a real run)")
        }
        let section = RenderManifest.profileSection(base, layout: layout, file: a.values["--profile"])
        manifest.profile = section
        printProfile(base, section)
        for v in variants {
            var rec = RenderManifest.Record(variant: v, pass: 1, thumbnail: false, startValue: 0)
            do {
                let patch = try D185Patch.apply(v.settings, to: base, layout: layout)
                rec.changes = patch.changes
                rec.notes = patch.notes
                print("\(v.name): \(v.settings.summary)")
                for c in patch.changes { print("    [\(c.index)] \(c.field) \(c.from) → \(c.to)") }
                for n in patch.notes { print("    note: \(n)") }
            } catch {
                rec.error = "\(error)"
                print("\(v.name): \(error)")
            }
            manifest.variants.append(rec)
        }
    }

    static func fmt(_ ms: Double?) -> String {
        guard let ms else { return "—" }
        return ms >= 1000 ? String(format: "%.2fs", ms / 1000) : String(format: "%.0fms", ms)
    }

    static func ms(since start: ContinuousClock.Instant) -> String {
        let d = ContinuousClock.now - start
        return "\(d.components.seconds * 1000 + d.components.attoseconds / 1_000_000_000_000_000)ms"
    }
}
#endif
