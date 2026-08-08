import Foundation

// Runnable checks for the app's pure logic — the parts that turn text into
// settings and typed text into an address. Plain Swift with no test framework,
// for the same reason tests/gate.cpp is plain C++: it compiles and runs anywhere
// the toolchain exists, and needs no simulator, host application or device.
//
// Everything the app does beyond this needs the engine or a screen, and is
// covered by the gates and by building the app.

var failures = 0

func check(_ what: String, _ condition: Bool, _ detail: @autoclosure () -> String = "") {
    if condition {
        print("ok   \(what)")
    } else {
        let extra = detail()
        print("FAIL \(what)\(extra.isEmpty ? "" : ": \(extra)")")
        failures += 1
    }
}

// MARK: Overrides seeded from a profile

// The engine reports its resolved configuration as "key = value" lines; these are
// the three keys the app exposes, in the forms Orca actually writes them.
let profile = [
    "wall_loops": "3",
    "sparse_infill_density": "20%",
    "enable_support": "1",
]

let seeded = Overrides(from: profile)
check("wall loops come from the profile", seeded.wallLoops == 3, "got \(seeded.wallLoops)")
check("infill drops the percent sign", seeded.infillPercent == 20, "got \(seeded.infillPercent)")
check("supports read as a flag", seeded.supports)

// A profile that says nothing about a key must leave the control alone rather
// than assert a default, since whatever is in the struct is sent on every slice.
let partial = Overrides(from: ["wall_loops": "5"])
let untouched = Overrides()
check("an absent key keeps the current value",
      partial.infillPercent == untouched.infillPercent,
      "got \(partial.infillPercent), expected \(untouched.infillPercent)")

// Orca writes some densities with a decimal point, which Int() alone will not read.
let fractional = Overrides(from: ["sparse_infill_density": "12.5%"])
check("a fractional density still parses", fractional.infillPercent == 12,
      "got \(fractional.infillPercent)")

// MARK: What the overrides send back

let json = Overrides(from: profile).json
for fragment in ["\"wall_loops\": \"3\"", "\"sparse_infill_density\": \"20%\"",
                 "\"enable_support\": \"1\""] {
    check("override JSON contains \(fragment)", json.contains(fragment), json)
}
check("override JSON parses",
      (try? JSONSerialization.jsonObject(with: Data(json.utf8))) != nil, json)

// MARK: Printer address

check("a bare host gains a scheme",
      Moonraker.address(from: "sv08.local")?.absoluteString == "http://sv08.local")
check("host and port survive",
      Moonraker.address(from: "sv08.local:7125")?.port == 7125,
      String(describing: Moonraker.address(from: "sv08.local:7125")))
check("an explicit scheme is left alone",
      Moonraker.address(from: "https://sv08.local")?.scheme == "https")
check("scheme detection is case insensitive",
      Moonraker.address(from: "HTTP://sv08.local")?.host == "sv08.local")
check("surrounding whitespace is ignored",
      Moonraker.address(from: "  sv08.local  ")?.host == "sv08.local")
// The reason the check is a prefix test rather than a search for "://".
check("a query string is not mistaken for a scheme",
      Moonraker.address(from: "sv08.local/x?u=a://b")?.host == "sv08.local",
      String(describing: Moonraker.address(from: "sv08.local/x?u=a://b")))
check("empty input is refused", Moonraker.address(from: "   ") == nil)

// MARK: Upload replies

// Moonraker has returned the uploaded item both at the top level and inside a
// "result" envelope, and both shapes are in the field. Reading only the envelope
// meant a real SV08 upload that had already landed was reported as a failure.
func uploadedPath(_ json: String) -> String? {
    try? Moonraker.uploadedPath(fromResponse: Data(json.utf8))
}

check("the top-level reply names the file",
      uploadedPath(#"{"item": {"path": "part.gcode", "root": "gcodes"}, "print_started": false}"#)
          == "part.gcode")
check("the result-wrapped reply names the file",
      uploadedPath(#"{"result": {"item": {"path": "part.gcode", "root": "gcodes"}}}"#)
          == "part.gcode")
// The server renames on collision, so the reply is authoritative over what we sent.
check("a renamed file is taken from the reply",
      uploadedPath(#"{"item": {"path": "part_1.gcode"}}"#) == "part_1.gcode")

check("malformed JSON is refused", uploadedPath("not json at all") == nil)
check("a reply without a path is refused", uploadedPath(#"{"result": {}}"#) == nil)
check("an empty path is refused", uploadedPath(#"{"item": {"path": ""}}"#) == nil)

// Falling back to the name we sent would risk starting an older print of the same
// name, so the refusal has to say what actually arrived instead.
do {
    _ = try Moonraker.uploadedPath(fromResponse: Data(#"{"surprise": 1}"#.utf8))
    check("an unreadable reply throws", false)
} catch {
    check("an unreadable reply throws", true)
    check("and quotes what came back",
          error.localizedDescription.contains("surprise"), error.localizedDescription)
}

check("a Moonraker error message is lifted out of its envelope",
      Moonraker.detail(fromErrorBody: #"{"error": {"code": 503, "message": "Klippy Not Connected"}}"#)
          == "Klippy Not Connected")
check("a body that is not a Moonraker error is passed through",
      Moonraker.detail(fromErrorBody: "upstream timed out") == "upstream timed out")

// MARK: Slice statistics

let statsJSON = """
{"estimated_seconds": 6240.5, "filament_mm": 374.94, "filament_grams": 1.12,
 "filament_mm3": 900.0, "layer_count": 64, "travel_mm": 120.0, "object_count": 1}
"""
if let stats = try? JSONDecoder().decode(SliceStats.self, from: Data(statsJSON.utf8)) {
    check("layer count decodes", stats.layer_count == 64)
    check("time reads as hours and minutes", stats.formattedTime == "1h 44m", stats.formattedTime)
} else {
    check("statistics decode", false, "decoding failed outright")
}

// Before the first slice the engine reports "{}", which must not decode into
// something the UI would then display as a real result.
check("an empty result does not decode",
      (try? JSONDecoder().decode(SliceStats.self, from: Data("{}".utf8))) == nil)

// MARK: Remembering the profile

// Loading a profile saves it, and restoring loads the saved one — so save() is
// called with its own destination, and used to delete it.
if let directory = try? FileManager.default.url(for: .applicationSupportDirectory,
                                                in: .userDomainMask,
                                                appropriateFor: nil, create: true) {
    let original = directory.appendingPathComponent("profile-store-check.3mf")
    try? Data("carrier".utf8).write(to: original)

    try? ProfileStore.save(original)
    let stored = ProfileStore.saved
    check("a profile is stored", stored != nil)

    if let stored {
        try? ProfileStore.save(stored)
        check("storing the stored profile leaves it there",
              FileManager.default.fileExists(atPath: stored.path))
        check("and it still has its contents",
              (try? Data(contentsOf: stored)) == Data("carrier".utf8))
    }
    try? FileManager.default.removeItem(at: original)
}

print(failures == 0 ? "PASS" : "FAIL: \(failures) checks")
exit(failures == 0 ? 0 : 1)
