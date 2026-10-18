// Bounded read-only image host. Window contents use the simulator's existing
// Main-compatible builders; ordinary requests use the same 512-byte offsets.
#include <cstdio>
#include <cstdlib>
#include <cstdint>
#include "cd_window.h"
static FILE *image;
static uint8_t buffer[32768];
extern "C" int platform_image_open(const char *path) {
    image = fopen(path, "rb");
    if (!image) return -1;
    fseek(image, 0, SEEK_END);
    int size = ftell(image);
    cdwin_mount(size);
    return size;
}
extern "C" int platform_image_read(int slot, unsigned lba, int bytes) {
    if (bytes > int(sizeof(buffer)) || bytes <= 0) return -1;
    if (slot == 2 && cdwin_is_window(lba))
        return cdwin_read(lba, buffer, bytes) ? bytes : -1;
    if (fseek(image, uint64_t(lba) * 512, SEEK_SET)) return -1;
    return fread(buffer, 1, bytes, image);
}
extern "C" int platform_image_byte(int offset) { return buffer[offset]; }
extern "C" void platform_window_word(int offset, int value) {
    buffer[offset*2] = value >> 8;
    buffer[offset*2+1] = value;
}
extern "C" void platform_window_write(unsigned lba) { cdwin_write(lba, buffer, 512); }
