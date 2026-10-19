// The app receives recipes as JSON from our server (lib/generate.ts). Swift must read and write the same JSON.
import Foundation
import Testing
@testable import DialInCamera

@Suite("Recipe JSON")
struct RecipeJSONTests {
    /// Semantic JSON equality (key order and 1 vs 1.0 don't matter).
    func sameJSON(_ a: Data, _ b: Data) throws -> Bool {
        let x = try JSONSerialization.jsonObject(with: a) as AnyObject
        let y = try JSONSerialization.jsonObject(with: b) as AnyObject
        return x.isEqual(y)
    }

    @Test("A DayPlan from the server decodes, and re-encodes to the same JSON")
    func dayPlanRoundTrip() throws {
        let raw = try Fixture.data("day-plan-sample.json")
        let plan = try JSONDecoder().decode(DayPlan.self, from: raw)
        #expect(plan.looks.count == 7)
        #expect(plan.recipes.map(\.name) == [
            "Morning coffee", "Midday sand", "Blue water", "Hard B&W", "Golden faces", "After sunset", "Dinner inside",
        ])
        let golden = plan.looks[4]
        #expect(golden.recipe.filmSim == .nostalgicNeg)
        #expect(golden.recipe.whiteBalance == .kelvin && golden.recipe.kelvin == 6700)
        #expect(golden.recipe.highlight == -2 && golden.recipe.colorChromeFxBlue == .weak)
        #expect(golden.exposure == Exposure(aperture: "f/2", shutter: "1/500", iso: "A", expComp: "+⅓", nd: false))
        #expect(plan.looks[1].recipe.highlight == -1.5)
        #expect(plan.looks[3].recipe.filmSim.isMonochrome)
        #expect(plan.looks[5].recipe.whiteBalance == .fluorescent3)
        let again = try JSONEncoder().encode(plan)
        #expect(try sameJSON(raw, again))
        #expect(try JSONDecoder().decode(DayPlan.self, from: again) == plan)
    }

    @Test("A bare Recipe encodes with exactly the TS keys and round-trips")
    func recipeKeys() throws {
        let tsKeys: Set<String> = [
            "name", "film_sim", "grain", "color_chrome", "color_chrome_fx_blue", "white_balance", "kelvin", "wb_shift_r",
            "wb_shift_b", "dynamic_range", "highlight", "shadow", "color", "sharpness", "noise_reduction", "clarity", "why",
        ]
        for v in try Fixture.vectors() {
            let data = try JSONEncoder().encode(v.recipe)
            let obj = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
            #expect(Set(obj.keys) == tsKeys)
            #expect(try JSONDecoder().decode(Recipe.self, from: data) == v.recipe)
        }
    }

    @Test("The recipes inside the golden-vector file (written by the TS exporter) decode")
    func tsWrittenRecipes() throws {
        let names = try Fixture.vectors().map(\.recipe.name)
        #expect(names == ["Warm Gold", "Golden faces", "Moody B&W", "After sunset"])
    }

    @Test("Enum strings are the TS strings")
    func enumStrings() {
        #expect(FilmSimulation.allCases.map(\.rawValue) == [
            "Provia", "Velvia", "Astia", "Classic Chrome", "Reala Ace", "Pro Neg Hi", "Pro Neg Std", "Classic Neg",
            "Nostalgic Neg", "Eterna", "Eterna Bleach Bypass", "Acros", "Acros+Ye", "Acros+R", "Acros+G", "Monochrome",
            "Monochrome+Ye", "Monochrome+R", "Monochrome+G", "Sepia",
        ])
        #expect(WhiteBalance.allCases.map(\.rawValue) == [
            "Auto", "Auto Ambience", "Daylight", "Shade", "Fluorescent 1", "Fluorescent 2", "Fluorescent 3", "Incandescent", "Kelvin",
        ])
        #expect(Grain.allCases.map(\.rawValue) == ["Off", "Weak Small", "Strong Small", "Weak Large", "Strong Large"])
        #expect(DynamicRange.allCases.map(\.minimumISO) == [125, 250, 500])
        #expect(FilmSimulation.acrosR.code == 0x0E && WhiteBalance.kelvin.code == 0x8007)
    }

    @Test("An unknown film sim is a decoding error, not a silent default")
    func unknownEnum() throws {
        var obj = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(Fixture.vectors()[0].recipe)) as? [String: Any])
        obj["film_sim"] = "Kodachrome"
        let bad = try JSONSerialization.data(withJSONObject: obj)
        #expect(throws: DecodingError.self) { try JSONDecoder().decode(Recipe.self, from: bad) }
    }

    @Test("A missing `why` is tolerated (defaults to empty)")
    func missingWhy() throws {
        var obj = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(Fixture.vectors()[0].recipe)) as? [String: Any])
        obj.removeValue(forKey: "why")
        let r = try JSONDecoder().decode(Recipe.self, from: JSONSerialization.data(withJSONObject: obj))
        #expect(r.why == "")
    }

    @Test("A moment Plan decodes")
    func momentPlan() throws {
        let look = String(decoding: try JSONEncoder().encode(Fixture.vectors()[0].recipe), as: UTF8.self)
        let json = #"{"scene":"Backlit by the pool","looks":[\#(look)],"exposure":{"aperture":"f/2","shutter":"A","iso":"A","exp_comp":"+⅔","nd":true},"focus_tip":"Tap her eye.","why":"Warm, soft light."}"#
        let plan = try JSONDecoder().decode(MomentPlan.self, from: Data(json.utf8))
        #expect(plan.looks.count == 1 && plan.exposure.nd && plan.focusTip == "Tap her eye.")
    }
}
