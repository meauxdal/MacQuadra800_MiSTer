// Independent absolute-time reference for the public diagnostic stream.
// Do not include DUT timing constants or inspect internal counters here.
#include "Vtv525_diagnostic.h"
#include "verilated.h"
#include "verilated_vcd_c.h"
#include <algorithm>
#include <array>
#include <cstdint>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <stdexcept>
#include <string>
#include <vector>

namespace fs = std::filesystem;
constexpr unsigned line_ticks = 1716, field_ticks = 450450, frame_ticks = 900900;
constexpr unsigned pixels = 640 * 480;

// Build a pulse-event schedule over a complete frame. Vertical pulse events
// override the continuous ordinary-H schedule; field 2 starts at half a line.
std::vector<uint8_t> sync_reference() {
    std::vector<uint8_t> sync(frame_ticks, 1);
    for (unsigned t = 0; t < frame_ticks; ++t)
        if (t % line_ticks < 127) sync[t] = 0;
    for (unsigned origin : {0u, field_ticks}) {
        for (unsigned t = origin; t < origin + 9 * line_ticks; ++t) sync[t] = 1;
        const std::array<unsigned, 18> widths = {
            62,62,62,62,62,62, 731,731,731,731,731,731, 62,62,62,62,62,62};
        for (unsigned pulse = 0; pulse < widths.size(); ++pulse)
            for (unsigned dt = 0; dt < widths[pulse]; ++dt)
                sync[origin + pulse * 858 + dt] = 0;
    }
    return sync;
}

struct Picture {
    bool de, image, ce;
    unsigned x, y, field, line, h;
};
Picture reference(unsigned t, unsigned geometry) {
    const unsigned line = t / line_ticks + 1, h = t % line_ticks;
    const bool first = line >= 23 && line <= 262;
    const bool second = line >= 285 && line <= 524;
    const bool de = (first || second) && h >= 253 && h <= 1674;
    const unsigned field = t < field_ticks; // spatial parity: electrical field 1 is odd
    const unsigned x = de ? (h - 253) * 640 / 1422 : 0;
    const unsigned y = de ? (first ? (line - 23) * 2 + 1 : (line - 285) * 2) : 0;
    const bool ce = de && (h == 253 || x != (h - 254) * 640 / 1422);
    const bool small = geometry == 1 || geometry == 2;
    const unsigned top = geometry == 1 ? 48 : geometry == 2 ? 69 : 0;
    const unsigned height = geometry == 1 ? 384 : geometry == 2 ? 342 : 480;
    const bool image = de && x >= (small ? 64 : 0) && x < (small ? 576 : 640) &&
                       y >= top && y < top + height;
    return {de, image, ce, x, y, field, line, h};
}

uint32_t reference_rgb(const Picture& p, unsigned pattern, unsigned geometry) {
    if (!p.image) return 0;
    const unsigned x = p.x, y = p.y;
    switch (pattern) {
    case 0: return 0;
    case 1: return 0xffffff;
    case 2: return (x * 255 / 639) * 0x010101;
    case 3: {
        const std::array<uint32_t, 8> bars = {
            0xbfbfbf, 0xbfbf00, 0x00bfbf, 0x00bf00,
            0xbf00bf, 0xbf0000, 0x0000bf, 0};
        return bars[x / 80];
    }
    case 4: {
        uint32_t rgb = 0x101010;
        if (x % 32 == 0 || y % 32 == 0) rgb = 0x606060;
        const int dx = int(x) - 320, dy = int(y) - 240;
        const int r2 = dx * dx + dy * dy;
        if (r2 >= 25344 && r2 <= 25856) rgb = 0xffffff;
        if (x == 320 || y == 240) rgb = 0xffff00;
        if (x < 2 || x >= 638 || y < 2 || y >= 478) rgb = 0x00ff00;
        return rgb;
    }
    case 5: return x >= 288 && x < 352 && y >= 208 && y < 272 ?
                   (p.field ? 0x00ffff : 0xff0000) : 0x404040;
    case 6: return y % 2 ? 0 : 0xffffff;
    case 7: {
        const bool small = geometry == 1 || geometry == 2;
        const unsigned sx = x - (small ? 64 : 0);
        const unsigned sy = y - (geometry == 1 ? 48 : geometry == 2 ? 69 : 0);
        return ((sy & 255) << 16) | ((sx & 255) << 8) |
               ((sy >> 8) << 7) | ((sx >> 8) << 5) | 21;
    }
    default: throw std::runtime_error("unknown reference pattern");
    }
}

class Bench {
public:
    VerilatedContext context;
    Vtv525_diagnostic dut{&context};
    VerilatedVcdC trace;
    std::vector<uint8_t> sync = sync_reference();
    uint64_t edge = 0;
    bool tracing = false;
    Bench() { context.traceEverOn(true); dut.trace(&trace, 1); }
    void clock_level(unsigned level) {
        // Rounded picosecond timestamps for an ideal 27 MHz clock. Counts,
        // not a truncated integer simulation period, determine exact rates.
        const uint64_t ps = edge++ * 1000000ULL / 54;
        context.time(ps);
        dut.clk = level;
        dut.eval();
        if (tracing) trace.dump(ps);
    }
    void reset(unsigned cycles, bool release_low = false) {
        dut.reset = 1;
        for (unsigned i = 0; i < cycles; ++i) {
            clock_level(0); clock_level(1);
            if (!dut.csync_n || !dut.hsync_n || !dut.vsync_n || dut.picture_de ||
                dut.image_de || dut.pixel_ce || dut.frame_start || dut.field_start ||
                dut.line_start || dut.halfline_start || dut.rgb)
                throw std::runtime_error("reset did not blank picture/markers/sync");
        }
        if (release_low) clock_level(0);
        dut.reset = 0;
    }
    Picture check(unsigned t, unsigned pattern, unsigned geometry) {
        const Picture p = reference(t, geometry);
        const unsigned ft = t % field_ticks;
        // Compare public outputs at EVERY electrical sample, including repeats
        // within a logical pixel and the last sample of every active row.
        auto require = [&](bool ok, const char* name) {
            if (!ok) throw std::runtime_error(std::string(name) + " at frame tick " +
                std::to_string(t) + " (line " + std::to_string(p.line) + ", h=" +
                std::to_string(p.h) + ", pattern=" + std::to_string(pattern) +
                ", geometry=" + std::to_string(geometry) + ")");
        };
        require(dut.csync_n == sync[t], "composite sync");
        require(dut.hsync_n == (p.h >= 127), "HS helper");
        require(dut.vsync_n == !(ft >= 3 * line_ticks && ft < 6 * line_ticks), "VS envelope");
        require(dut.line_number == p.line && dut.h_sample == p.h, "electrical coordinates");
        require(dut.field_id == p.field, "field parity");
        require(dut.frame_start == (t == 0), "frame marker");
        require(dut.field_start == (ft == 0), "field marker");
        require(dut.line_start == (p.h == 0), "line marker");
        require(dut.halfline_start == (t % 858 == 0), "half-line marker");
        require(dut.picture_de == p.de, "picture aperture");
        require(dut.canvas_x == p.x && dut.canvas_y == p.y, "canvas coordinates");
        // Idealized vertical scan position relative to each field's sync
        // origin, measured in half-lines. A software weave alone can hide
        // swapped spatial fields; this time-derived oracle cannot. The two
        // first picture rows occur 21.5H (row 0) / 22H (row 1) after origin.
        if (p.de) {
            const int physical_y = (2 * (int(ft) - int(p.h))) / int(line_ticks) - 43;
            require(physical_y == int(dut.canvas_y), "physical vertical phase / row order");
        }
        require(dut.pixel_ce == p.ce, "logical pixel enable");
        require(dut.image_de == p.image, "image borders");
        require(dut.rgb == reference_rgb(p, pattern, geometry), "RGB integrity");
        return p;
    }
};

void ppm(const fs::path& name, const std::vector<uint8_t>& bytes, unsigned height) {
    std::ofstream f(name, std::ios::binary);
    f << "P6\n640 " << height << "\n255\n";
    f.write(reinterpret_cast<const char*>(bytes.data()), bytes.size());
    if (!f) throw std::runtime_error("failed writing " + name.string());
}

int main(int argc, char** argv) {
    const fs::path out = argc > 1 ? argv[1] : "out/tv525";
    fs::create_directories(out);
    std::ofstream report(out / "verification.txt");
    try {
        Bench b;
        // Reproducible randomized interruptions and reset pulse lengths, with
        // reset asserted/released on alternating clock phases. The fourth trial
        // also checks the reserved geometry's full-canvas fallback for a pair.
        uint32_t rng = 0x525480;
        for (unsigned trial = 0; trial < 6; ++trial) {
            rng = rng * 1664525 + 1013904223;
            b.dut.pattern = trial % 8;
            b.dut.geometry = trial % 4;
            if (trial % 2) b.clock_level(0);
            b.reset(1 + rng % 17, trial % 2);
            const unsigned duration = trial == 3 ? frame_ticks + 1716 : 2000 + rng % field_ticks;
            for (unsigned t = 0; t < duration; ++t) {
                b.clock_level(0); b.check(t % frame_ticks, trial % 8, trial % 4); b.clock_level(1);
            }
        }
        b.reset(7);
        std::ofstream edges(out / "sync_edges.csv");
        edges << "tick,time_ps,field,line,h,csync_n,hsync_n,vsync_n,picture_de\n";
        std::vector<uint8_t> image(pixels * 3), visits(pixels);
        std::array<uint64_t, 3> pulse_counts{};
        uint64_t samples = 0, logical_pixels = 0, fields = 0, frames = 0;
        uint64_t previous_field_tick = 0, previous_frame_tick = 0;
        unsigned low_width = 0, previous_controls = 0xffff;
        unsigned field_rows = 0, field_pixels = 0, field_samples = 0;
        const std::array<const char*, 8> names = {
            "black", "white", "ramp", "bars", "grid", "field", "lines", "coordinates"};
        for (uint64_t tick = 0; tick < uint64_t(field_ticks) * 120; ++tick) {
            const unsigned t = tick % frame_ticks, pair = tick / frame_ticks;
            const unsigned pattern = pair % 8, geometry = (pair / 8) % 3;
            const unsigned field_serial = tick / field_ticks;
            b.dut.pattern = pattern; b.dut.geometry = geometry;
            b.clock_level(0);
            const Picture p = b.check(t, pattern, geometry);
            if (b.dut.field_start) {
                if (fields && tick - previous_field_tick != field_ticks)
                    throw std::runtime_error("measured field period");
                if (p.h != (p.field ? 0u : 858u)) throw std::runtime_error("measured field H phase");
                previous_field_tick = tick; ++fields;
            }
            if (b.dut.frame_start) {
                if (frames && tick - previous_frame_tick != frame_ticks)
                    throw std::runtime_error("measured frame period");
                previous_frame_tick = tick; ++frames;
                std::fill(visits.begin(), visits.end(), 0);
            }
            if (!b.dut.csync_n) ++low_width;
            else if (low_width) {
                const int bin = low_width == 62 ? 0 : low_width == 127 ? 1 : low_width == 731 ? 2 : -1;
                if (bin < 0) throw std::runtime_error("measured sync width " + std::to_string(low_width));
                ++pulse_counts[bin]; low_width = 0;
            }
            const unsigned controls = b.dut.csync_n | (b.dut.hsync_n << 1) |
                                      (b.dut.vsync_n << 2) | (b.dut.picture_de << 3);
            if (field_serial < 4 && (controls != previous_controls || b.dut.field_start))
                edges << tick << ',' << b.context.time() << ',' << p.field << ',' << p.line << ',' << p.h
                      << ',' << unsigned(b.dut.csync_n) << ',' << unsigned(b.dut.hsync_n)
                      << ',' << unsigned(b.dut.vsync_n) << ',' << unsigned(b.dut.picture_de) << '\n';
            previous_controls = controls;
            if (p.de) { ++samples; ++field_samples; }
            if (p.ce) {
                ++logical_pixels; ++field_pixels;
                if (p.x == 0) ++field_rows;
                const unsigned address = p.y * 640 + p.x;
                if (++visits[address] != 1) throw std::runtime_error("duplicate woven pixel");
                if (pair < 24) {
                    image[3 * address] = b.dut.rgb >> 16;
                    image[3 * address + 1] = b.dut.rgb >> 8;
                    image[3 * address + 2] = b.dut.rgb;
                }
            }
            if ((tick + 1) % field_ticks == 0) {
                if (field_rows != 240 || field_pixels != 153600 || field_samples != 341280)
                    throw std::runtime_error("measured active field dimensions");
                field_rows = field_pixels = field_samples = 0;
            }
            if (t == frame_ticks - 1) {
                for (uint8_t n : visits) if (n != 1) throw std::runtime_error("missing woven pixel");
                if (pair < 24) {
                    const std::string base = "g" + std::to_string(geometry) + "_" + names[pattern];
                    ppm(out / (base + ".ppm"), image, 480);
                    if (pattern == 4 || pattern == 7 || pattern == 5 || pattern == 6) {
                        for (unsigned field = 0; field < 2; ++field) {
                            std::vector<uint8_t> rows(640 * 240 * 3);
                            for (unsigned y = 0; y < 240; ++y)
                                std::copy_n(image.data() + ((2 * y + field) * 640 * 3), 640 * 3,
                                            rows.data() + y * 640 * 3);
                            ppm(out / (base + "_field" + std::to_string(field) + ".ppm"), rows, 240);
                        }
                    }
                }
            }
            // Start one half-clock before the field-origin edge, so the VCD
            // includes the FULL first equalization pulse rather than cropping
            // its leading half-clock. Capture four steady fields (1..4).
            if ((tick + 1) % field_ticks == 0 && field_serial < 4) {
                b.trace.open((out / ("steady" + std::to_string(field_serial) +
                    "_sync.vcd")).string().c_str());
                b.tracing = true;
                b.trace.dump(b.context.time());
            }
            b.clock_level(1);
            if (b.tracing && (tick + 1) % field_ticks == 12 * line_ticks) {
                b.trace.close(); b.tracing = false;
            }
        }
        if (fields != 120 || frames != 60 || pulse_counts != std::array<uint64_t,3>{1440,30420,720})
            throw std::runtime_error("long-run field/frame/pulse totals");
        report << "PASS: 120 fields / 60 pairs at nominal 27 MHz; 6 reset interruptions\n"
               << "Field ticks: 450450; pair ticks: 900900; H ticks: 1716\n"
               << "H: 15734.265734 Hz; fields: 59.94005994 Hz; pairs: 29.97002997 Hz\n"
               << "Pulse counts (62,127,731 ticks): 1440,30420,720\n"
               << "Active samples checked: " << samples << "; logical pixels checked: " << logical_pixels << '\n'
               << "24 complete pattern/geometry pairs exported; 24 separate field images\n"
               << "Four VCD windows: first 12 lines from each electrical field origin\n"
               << "Physical row-phase check: electrical field 1 odd / field 2 even\n"
               << "No Mac source, DDR, PLL IP, DAC, or hardware is exercised by this bench.\n";
        std::cout << "PASS: 120 fields, all electrical samples and 18432000 logical pixels; 6 reset trials\n";
        b.dut.final();
        return 0;
    } catch (const std::exception& e) {
        report << "FAIL: " << e.what() << '\n';
        std::cerr << "FAIL: " << e.what() << '\n';
        return 1;
    }
}
