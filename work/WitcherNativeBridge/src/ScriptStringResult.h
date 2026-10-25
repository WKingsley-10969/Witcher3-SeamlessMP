#pragma once
#include <cstdint>
#include <cstring>

namespace witcher_native_bridge {
// Remastered script strings are packed pointer + uint32 length (12 bytes).
// WNB_String has C++ tail padding for ABI convenience; that padding is NOT
// part of an engine property. A native may return directly into such a property.
inline void StoreScriptStringResult(void* result, void* data, std::uint32_t bytes) {
    static_assert(sizeof(void*) == 8, "Witcher native bridge requires x64");
    std::memcpy(result, &data, sizeof(data));
    std::memcpy(static_cast<unsigned char*>(result) + sizeof(data), &bytes, sizeof(bytes));
}
}
