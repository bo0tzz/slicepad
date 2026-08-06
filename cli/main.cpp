// Development harness for the slicing core.
//
// Exists to exercise core/ on Linux at full speed, where the iPad app cannot be
// iterated on. Two subcommands, matching the project's two correctness gates:
//
//   slicepad-cli config <profile.3mf>
//       Prints the configuration as "key = value" lines, comparable against the
//       config block Orca embeds in its own G-code.
//
//   slicepad-cli slice <profile.3mf> <model> -o <out.gcode>
//
// <profile.3mf> is a project saved by desktop Orca; its geometry is ignored.
#include "slicepad.h"

#include <cstdio>
#include <cstdlib>
#include <string>

namespace {

struct Options {
    std::string command;
    std::string profile;
    std::string model;
    std::string output;
    std::string overrides;
};

void usage()
{
    std::fputs(
        "usage:\n"
        "  slicepad-cli config <profile.3mf> [--overrides JSON]\n"
        "  slicepad-cli slice  <profile.3mf> <model> -o <out.gcode> [--overrides JSON]\n"
        "\n"
        "  <profile.3mf>  a project saved by desktop Orca (File > Save Project As);\n"
        "                 only its configuration is used, not its geometry\n"
        "  --overrides    config overrides as an Orca preset fragment, e.g.\n"
        "                 '{\"sparse_infill_density\":\"25%\"}'\n"
        "\n"
        "environment:\n"
        "  SLICEPAD_RESOURCES  OrcaSlicer resources dir\n"
        "  SLICEPAD_DATA       writable working dir\n"
        "  SLICEPAD_LOG        libslic3r log level (0 quiet, 4 debug)\n",
        stderr);
}

int progress_line(int percent, const char *stage, void *)
{
    std::fprintf(stderr, "\r%3d%%  %-48s", percent, stage ? stage : "");
    std::fflush(stderr);
    return 0;
}

} // namespace

int main(int argc, char **argv)
{
    Options opt;
    for (int i = 1; i < argc; ++i) {
        const std::string arg = argv[i];
        auto next = [&](std::string &dest) {
            if (i + 1 >= argc) {
                std::fprintf(stderr, "error: %s needs a value\n", arg.c_str());
                std::exit(2);
            }
            dest = argv[++i];
        };
        if (arg == "-h" || arg == "--help") { usage(); return 0; }
        else if (arg == "-o")          next(opt.output);
        else if (arg == "--overrides") next(opt.overrides);
        else if (opt.command.empty())  opt.command = arg;
        else if (opt.profile.empty())  opt.profile = arg;
        else if (opt.model.empty())    opt.model = arg;
        else { std::fprintf(stderr, "error: unexpected argument %s\n", arg.c_str()); return 2; }
    }

    if (opt.command.empty() || opt.profile.empty()) { usage(); return 2; }

    const char *resources = std::getenv("SLICEPAD_RESOURCES");
    const char *data = std::getenv("SLICEPAD_DATA");
    if (resources == nullptr || data == nullptr) {
        std::fputs("error: set SLICEPAD_RESOURCES and SLICEPAD_DATA\n", stderr);
        return 2;
    }

    sp_engine *engine = sp_engine_create(resources, data);
    if (engine == nullptr) {
        std::fputs("error: could not create engine\n", stderr);
        return 1;
    }

    int status = 0;
    if (sp_load_config(engine, opt.profile.c_str()) != SP_OK) {
        std::fprintf(stderr, "error: loading profile: %s\n", sp_last_error(engine));
        status = 1;
    } else if (sp_set_overrides(engine, opt.overrides.empty() ? nullptr
                                                             : opt.overrides.c_str()) != SP_OK) {
        std::fprintf(stderr, "error: overrides: %s\n", sp_last_error(engine));
        status = 1;
    } else if (opt.command == "config") {
        const std::string profile_version = sp_config_source_version(engine);
        std::fprintf(stderr, "engine %s (config %s), profile config %s%s\n",
                     sp_engine_version(), sp_engine_config_version(),
                     profile_version.empty() ? "unknown" : profile_version.c_str(),
                     (!profile_version.empty() && profile_version != sp_engine_config_version())
                         ? " — migrated" : "");
        std::fputs(sp_resolved_config_text(engine), stdout);
    } else if (opt.command == "slice") {
        if (opt.model.empty() || opt.output.empty()) {
            usage();
            status = 2;
        } else if (sp_load_model(engine, opt.model.c_str()) != SP_OK) {
            std::fprintf(stderr, "error: loading model: %s\n", sp_last_error(engine));
            status = 1;
        } else if (sp_slice(engine, opt.output.c_str(), progress_line, nullptr) != SP_OK) {
            std::fprintf(stderr, "\nerror: slicing: %s\n", sp_last_error(engine));
            status = 1;
        } else {
            std::fprintf(stderr, "\nwrote %s\n", opt.output.c_str());
            std::fputs(sp_slice_stats_json(engine), stdout);
            std::fputc('\n', stdout);
            std::fprintf(stderr, "toolpath: %zu segments\n",
                         sp_toolpath_segment_count(engine));
        }
    } else {
        std::fprintf(stderr, "error: unknown command %s\n", opt.command.c_str());
        status = 2;
    }

    sp_engine_destroy(engine);
    return status;
}
