// Development harness for the slicing core.
//
// Exists to exercise core/ on Linux at full speed, where the iPad app cannot be
// iterated on. Two subcommands, matching the project's two correctness gates:
//
//   slicepad-cli config <bundle> [--printer N] [--process N] [--filament N]
//       Resolves presets and prints the merged config as "key = value" lines,
//       comparable against the config block Orca embeds in its G-code.
//
//   slicepad-cli slice <bundle> <model> -o <out.gcode> [selectors...]
#include "slicepad.h"

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>

namespace {

struct Options {
    std::string command;
    std::string bundle;
    std::string model;
    std::string output;
    std::string printer;
    std::string process;
    std::string filament;
    std::string overrides;
};

void usage()
{
    std::fputs(
        "usage:\n"
        "  slicepad-cli config <bundle> [selectors]\n"
        "  slicepad-cli slice  <bundle> <model> -o <out.gcode> [selectors]\n"
        "\n"
        "selectors:\n"
        "  --printer NAME   --process NAME   --filament NAME\n"
        "  --overrides JSON   config overrides, as an Orca preset fragment\n"
        "\n"
        "environment:\n"
        "  SLICEPAD_RESOURCES  OrcaSlicer resources dir (contains profiles/)\n"
        "  SLICEPAD_DATA       writable dir for imported presets\n",
        stderr);
}

int progress_line(int percent, const char *stage, void *)
{
    std::fprintf(stderr, "\r%3d%%  %-48s", percent, stage ? stage : "");
    std::fflush(stderr);
    return 0;
}

bool select(sp_engine *engine, sp_preset_kind kind, const std::string &name, const char *label)
{
    if (name.empty())
        return true;
    if (sp_select_preset(engine, kind, name.c_str()) != SP_OK) {
        std::fprintf(stderr, "error: %s: %s\n", label, sp_last_error(engine));
        return false;
    }
    return true;
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
        else if (arg == "-o")           next(opt.output);
        else if (arg == "--printer")    next(opt.printer);
        else if (arg == "--process")    next(opt.process);
        else if (arg == "--filament")   next(opt.filament);
        else if (arg == "--overrides")  next(opt.overrides);
        else if (opt.command.empty())   opt.command = arg;
        else if (opt.bundle.empty())    opt.bundle = arg;
        else if (opt.model.empty())     opt.model = arg;
        else { std::fprintf(stderr, "error: unexpected argument %s\n", arg.c_str()); return 2; }
    }

    if (opt.command.empty() || opt.bundle.empty()) { usage(); return 2; }

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
    if (sp_load_presets(engine, opt.bundle.c_str()) != SP_OK) {
        std::fprintf(stderr, "error: loading presets: %s\n", sp_last_error(engine));
        status = 1;
    } else if (!select(engine, SP_PRESET_MACHINE, opt.printer, "printer") ||
               !select(engine, SP_PRESET_PROCESS, opt.process, "process") ||
               !select(engine, SP_PRESET_FILAMENT, opt.filament, "filament")) {
        status = 1;
    } else if (sp_set_overrides(engine, opt.overrides.empty() ? nullptr : opt.overrides.c_str()) != SP_OK) {
        std::fprintf(stderr, "error: overrides: %s\n", sp_last_error(engine));
        status = 1;
    } else if (opt.command == "list") {
        const struct { sp_preset_kind kind; const char *label; } kinds[] = {
            {SP_PRESET_MACHINE,  "machine"},
            {SP_PRESET_PROCESS,  "process"},
            {SP_PRESET_FILAMENT, "filament"},
        };
        for (const auto &k : kinds) {
            const int count = sp_preset_count(engine, k.kind);
            std::printf("== %s (%d)\n", k.label, count);
            for (int i = 0; i < count; ++i) {
                const char *name = sp_preset_name(engine, k.kind, i);
                std::printf("   %s\n", name ? name : "(null)");
            }
        }
    } else if (opt.command == "config") {
        // Printed by the core so that the comparison covers exactly the config
        // the slice would use.
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
        }
    } else {
        std::fprintf(stderr, "error: unknown command %s\n", opt.command.c_str());
        status = 2;
    }

    sp_engine_destroy(engine);
    return status;
}
