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
#include <cstdio>
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

    sp_engine_destroy(engine);
    if (failures == 0)
        std::puts("PASS");
    return failures == 0 ? 0 : 1;
}
