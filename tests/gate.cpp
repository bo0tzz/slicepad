// The project's two correctness gates, as a portable test.
//
//   slicepad-gate <fixtures-dir> <writable-dir>
//
// Deliberately plain C++ over slicepad.h with no platform dependencies and no
// shell, so the same source runs on the Linux dev machine and on the iOS
// Simulator in CI. Anything Apple-specific belongs above the C ABI, never here.
//
// Gate 1 compares the resolved configuration against the config block Orca
// embeds in reference.gcode; it needs no slicing and catches profile handling.
// Gate 2 slices the fixture mesh and compares every G/M command line in order.
#include "slicepad.h"

#include <algorithm>
#include <filesystem>
#include <cctype>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <fstream>
#include <map>
#include <sstream>
#include <string>
#include <vector>

namespace {

// Keys where a difference from the reference is understood and expected.
const std::vector<std::pair<const char *, const char *>> kKnownConfigDiffs = {
    {"enable_prime_tower",
     "Orca normalises the prime tower off for single-filament prints, so the "
     "reference records the post-slice value while the project stores the "
     "pre-slice one"},
    {"extruder_colour", "a display colour with no effect on toolpaths"},
};

std::string read_file(const std::string &path)
{
    std::ifstream in(path, std::ios::binary);
    std::ostringstream buffer;
    buffer << in.rdbuf();
    return buffer.str();
}

std::string trim(const std::string &text)
{
    const size_t first = text.find_first_not_of(" \t\r\n");
    if (first == std::string::npos)
        return {};
    const size_t last = text.find_last_not_of(" \t\r\n");
    return text.substr(first, last - first + 1);
}

std::vector<std::string> lines_of(const std::string &text)
{
    std::vector<std::string> out;
    std::istringstream in(text);
    std::string line;
    while (std::getline(in, line)) {
        if (!line.empty() && line.back() == '\r')
            line.pop_back();
        out.push_back(line);
    }
    return out;
}

// "key = value" pairs, from either our config dump or the "; key = value"
// comment block Orca writes into its G-code.
std::map<std::string, std::string> parse_config(const std::string &text, bool comment_prefixed)
{
    std::map<std::string, std::string> out;
    for (const std::string &raw : lines_of(text)) {
        std::string line = raw;
        if (comment_prefixed) {
            if (line.rfind("; ", 0) != 0)
                continue;
            line = line.substr(2);
        }
        const size_t sep = line.find(" = ");
        if (sep == std::string::npos)
            continue;
        const std::string key = trim(line.substr(0, sep));
        if (key.empty() || key.find(' ') != std::string::npos)
            continue;
        out[key] = trim(line.substr(sep + 3));
    }
    return out;
}

// G-code motion and machine commands, ignoring comments and metadata so that
// timestamps and embedded thumbnails do not register as differences.
std::vector<std::string> commands_of(const std::string &gcode)
{
    std::vector<std::string> out;
    for (const std::string &line : lines_of(gcode))
        if (!line.empty() && (line[0] == 'G' || line[0] == 'M'))
            out.push_back(line);
    return out;
}

bool is_known_diff(const std::string &key)
{
    return std::any_of(kKnownConfigDiffs.begin(), kKnownConfigDiffs.end(),
                       [&](const auto &entry) { return key == entry.first; });
}

// Minimal extractors so the test stays free of a JSON dependency.
double number_after(const std::string &text, const std::string &needle)
{
    const size_t at = text.find(needle);
    if (at == std::string::npos)
        return -1.0;
    return std::strtod(text.c_str() + at + needle.size(), nullptr);
}

// "1m 44s", "2h 3m 5s" and bare "44s" all appear in Orca's output.
double seconds_from_duration(const std::string &text)
{
    double total = 0.0;
    double value = 0.0;
    for (size_t i = 0; i < text.size(); ++i) {
        if (std::isdigit(static_cast<unsigned char>(text[i]))) {
            value = value * 10 + (text[i] - '0');
        } else if (text[i] == 'h') { total += value * 3600; value = 0; }
        else if (text[i] == 'm') { total += value * 60;   value = 0; }
        else if (text[i] == 's') { total += value;        value = 0; }
    }
    return total;
}

std::string line_containing(const std::string &text, const std::string &needle)
{
    for (const std::string &line : lines_of(text))
        if (line.find(needle) != std::string::npos)
            return line;
    return {};
}

int fail(const char *gate, const std::string &detail)
{
    std::fprintf(stderr, "FAIL %s: %s\n", gate, detail.c_str());
    return 1;
}

} // namespace

int main(int argc, char **argv)
{
    if (argc < 3) {
        std::fputs("usage: slicepad-gate <fixtures-dir> <writable-dir>\n", stderr);
        return 2;
    }
    const std::string fixtures = argv[1];
    const std::string work = argv[2];

    // The engine writes a temporary profile here and the sliced G-code, so the
    // directory has to exist before anything else. CI passes a path that does
    // not exist yet.
    std::error_code ec;
    std::filesystem::create_directories(work, ec);
    if (ec)
        return fail("setup", "cannot create working directory " + work + ": " + ec.message());

    const std::string profile = fixtures + "/empty.3mf";
    const std::string model = fixtures + "/model.3mf";
    const std::string reference = fixtures + "/reference.gcode";

    // Resources only need to exist; profiles arrive fully resolved.
    sp_engine *engine = sp_engine_create(fixtures.c_str(), work.c_str());
    if (engine == nullptr)
        return fail("setup", "could not create engine");

    int failures = 0;

    if (sp_load_config(engine, profile.c_str()) != SP_OK) {
        failures += fail("gate1", std::string("loading profile: ") + sp_last_error(engine));
    } else {
        const auto ours = parse_config(sp_resolved_config_text(engine), false);
        const auto ref = parse_config(read_file(reference), true);

        size_t compared = 0, matched = 0;
        std::vector<std::string> unexpected;
        for (const auto &[key, ref_value] : ref) {
            const auto found = ours.find(key);
            if (found == ours.end())
                continue; // the G-code omits some keys and adds legacy aliases
            ++compared;
            if (found->second == ref_value)
                ++matched;
            else if (!is_known_diff(key))
                unexpected.push_back(key + " (reference " + ref_value + ", ours " + found->second + ")");
        }

        std::printf("gate1 config: %zu/%zu keys identical, %zu known differences\n",
                    matched, compared, compared - matched);
        if (compared < 500)
            failures += fail("gate1", "suspiciously few keys compared — is the reference intact?");
        for (const std::string &key : unexpected)
            failures += fail("gate1", "unexpected difference: " + key);
    }

    const std::string produced = work + "/gate.gcode";
    if (sp_load_model(engine, model.c_str()) != SP_OK) {
        failures += fail("gate2", std::string("loading model: ") + sp_last_error(engine));
    } else if (sp_slice(engine, produced.c_str(), nullptr, nullptr) != SP_OK) {
        failures += fail("gate2", std::string("slicing: ") + sp_last_error(engine));
    } else {
        const auto ref = commands_of(read_file(reference));
        const auto ours = commands_of(read_file(produced));
        std::printf("gate2 gcode: %zu reference commands, %zu ours\n", ref.size(), ours.size());
        // Without a floor, two unreadable files both yield zero commands and the
        // comparison below would report them as identical.
        if (ref.size() < 1000 || ours.size() < 1000) {
            failures += fail("gate2", "implausibly few commands — check the fixtures parsed");
        } else if (ref.size() != ours.size()) {
            failures += fail("gate2", "command count differs");
        } else {
            size_t first_diff = ref.size();
            for (size_t i = 0; i < ref.size(); ++i)
                if (ref[i] != ours[i]) { first_diff = i; break; }
            if (first_diff != ref.size())
                failures += fail("gate2", "first difference at command " + std::to_string(first_diff) +
                                              "\n  reference: " + ref[first_diff] +
                                              "\n  ours:      " + ours[first_diff]);
            else
                std::printf("gate2 gcode: all %zu commands identical in sequence\n", ref.size());
        }
    }

    // Gate 3: the figures a UI shows must agree with what the desktop reports
    // for the same job, since a number that is quietly wrong by a little is
    // worse than one that is obviously missing.
    if (failures == 0) {
        const std::string stats = sp_slice_stats_json(engine);
        const std::string ref = read_file(reference);

        struct Check { const char *label; double ours; double theirs; double tolerance; };
        const std::string time_line = line_containing(ref, "estimated printing time (normal mode)");
        const Check checks[] = {
            {"filament_mm", number_after(stats, "\"filament_mm\":"),
             number_after(line_containing(ref, "filament used [mm]"), "= "), 0.01},
            {"filament_grams", number_after(stats, "\"filament_grams\":"),
             number_after(line_containing(ref, "total filament used [g]"), "= "), 0.01},
            {"layer_count", number_after(stats, "\"layer_count\":"),
             number_after(line_containing(ref, "total layer number:"), ": "), 0.0},
            {"estimated_seconds", number_after(stats, "\"estimated_seconds\":"),
             seconds_from_duration(time_line.substr(time_line.find("= ") + 2)), 0.01},
        };

        for (const Check &check : checks) {
            if (check.theirs <= 0.0) {
                failures += fail("gate3", std::string("no reference value for ") + check.label);
                continue;
            }
            const double drift = std::fabs(check.ours - check.theirs) / check.theirs;
            if (drift > check.tolerance)
                failures += fail("gate3", std::string(check.label) + ": ours " +
                                              std::to_string(check.ours) + ", desktop " +
                                              std::to_string(check.theirs));
        }
        if (failures == 0)
            std::puts("gate3 stats: filament, layers and time agree with the desktop");

        // Gate 4: the toolpath handed to a renderer must actually describe the
        // printed object. Cheap to check and worth doing before any view is built
        // on top of it: the tallest extrusion should reach the same height the
        // desktop's G-code does.
        const size_t segments = sp_toolpath_segment_count(engine);
        const float *packed = sp_toolpath_segments(engine);
        if (segments == 0 || packed == nullptr) {
            failures += fail("gate4", "no toolpath segments produced");
        } else {
            float top = 0.0f;
            for (size_t i = 0; i < segments * 6; i += 3)
                top = std::max(top, packed[i + 2]);

            // The highest Z at which the desktop actually extrudes. Not simply the
            // highest Z move: the last one is the end-of-print lift, a travel, so
            // comparing against that overstates the object by one hop.
            double reference_top = 0.0;
            double current_z = 0.0;
            for (const std::string &line : lines_of(ref)) {
                if (line.rfind("G1", 0) != 0)
                    continue;
                const size_t z_at = line.find(" Z");
                if (z_at != std::string::npos)
                    current_z = std::strtod(line.c_str() + z_at + 2, nullptr);
                // Values are written like "E.33867", so the character after " E"
                // is often a decimal point; only a leading '-' means retraction.
                const size_t e_at = line.find(" E");
                const char after_e = e_at != std::string::npos ? line[e_at + 2] : '\0';
                const bool extruding =
                    e_at != std::string::npos &&
                    (std::isdigit(static_cast<unsigned char>(after_e)) || after_e == '.');
                if (extruding && line.find(" X") != std::string::npos)
                    reference_top = std::max(reference_top, current_z);
            }

            if (reference_top <= 0.0)
                failures += fail("gate4", "no Z moves found in the reference");
            else if (std::fabs(top - reference_top) / reference_top > 0.01)
                failures += fail("gate4", "toolpath top " + std::to_string(top) +
                                              " but the desktop reaches " +
                                              std::to_string(reference_top));
            else
                std::printf("gate4 toolpath: %zu segments, top %.2fmm matches the desktop\n",
                            segments, double(top));
        }
    }

    sp_engine_destroy(engine);
    if (failures == 0)
        std::puts("PASS");
    return failures == 0 ? 0 : 1;
}
