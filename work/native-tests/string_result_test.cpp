#include "../WitcherNativeBridge/src/ScriptStringResult.h"
#include <array>
#include <cassert>
#include <cstdio>
#include <cstring>

int main() {
    // Misaligned packed engine properties with a neighbouring live string.
    std::array<unsigned char, 32> properties;
    properties.fill(0xA5);
    char value[] = "host";
    void* pointer = value;
    witcher_native_bridge::StoreScriptStringResult(properties.data() + 1, pointer, 5);
    void* actual = nullptr;
    std::uint32_t length = 0;
    std::memcpy(&actual, properties.data() + 1, 8);
    std::memcpy(&length, properties.data() + 9, 4);
    assert(actual == pointer && length == 5);
    assert(properties[0] == 0xA5);
    for (std::size_t i = 13; i < properties.size(); ++i) assert(properties[i] == 0xA5);
    std::puts("String result packed-property bounds PASS");
}
