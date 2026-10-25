// Standalone test executable. Exercises the real test-hook code without launching Witcher 3.
#define WITCHER_NATIVE_BRIDGE_EXPORTS
#include "../witcher3-coop/w3test/w3test.cpp"

extern "C" {
bool WNB_RegisterNative(const char *, WNB_NativeImplementation) { return true; }
int WNB_ReadIntParameter(void *) { return 0; }
int WNB_ReadStringParameter(void *, WNB_String *) { return 0; }
void WNB_ReturnVoid(void *) {}
void WNB_ReturnInt(void *, void *, int) {}
bool WNB_ReturnString(void *, void *, const wchar_t *, uint32_t) { return true; }
}

bool HideOwnImport(const char *function)
{
    auto *base = reinterpret_cast<unsigned char *>(GetModuleHandleW(nullptr));
    const auto *dos = reinterpret_cast<IMAGE_DOS_HEADER *>(base);
    const auto *nt = reinterpret_cast<IMAGE_NT_HEADERS *>(base + dos->e_lfanew);
    const auto &dir = nt->OptionalHeader.DataDirectory[IMAGE_DIRECTORY_ENTRY_IMPORT];
    for (auto *desc = reinterpret_cast<IMAGE_IMPORT_DESCRIPTOR *>(base + dir.VirtualAddress); desc->Name; ++desc) {
        if (_stricmp(reinterpret_cast<char *>(base + desc->Name), "SHELL32.dll") != 0) continue;
        auto *names = reinterpret_cast<IMAGE_THUNK_DATA *>(base + desc->OriginalFirstThunk);
        for (; names->u1.AddressOfData; ++names) {
            if (IMAGE_SNAP_BY_ORDINAL(names->u1.Ordinal)) continue;
            auto *item = reinterpret_cast<IMAGE_IMPORT_BY_NAME *>(base + names->u1.AddressOfData);
            if (strcmp(item->Name, function) != 0) continue;
            DWORD old = 0;
            if (!VirtualProtect(item->Name, 1, PAGE_READWRITE, &old)) return false;
            item->Name[0] = 'X'; // alter only this test process's import-name metadata
            DWORD unused = 0;
            VirtualProtect(item->Name, 1, old, &unused);
            return true;
        }
    }
    return false;
}

int wmain(int argc, wchar_t **argv)
{
    const std::wstring mode = argc > 1 ? argv[1] : L"valid";
    const bool interactive = mode == L"interactive";
    if (interactive) {
        SetEnvironmentVariableW(L"W3T_SCENARIO", nullptr);
        const auto documents = GetEnv(L"W3T_DOCUMENTS");
        SetEnvironmentVariableW(L"W3LAN_DOCUMENTS", documents.c_str());
    }
    if (mode == L"owner" || mode == L"owner-slash" || mode == L"owner-dot") {
        PWSTR path = nullptr;
        if (FAILED(SHGetKnownFolderPath(FOLDERID_Documents, 0, nullptr, &path))) return 20;
        std::wstring selected(path);
        if (mode == L"owner-slash") selected += L"\\";
        if (mode == L"owner-dot") selected += L"\\.";
        SetEnvironmentVariableW(L"W3T_DOCUMENTS", selected.c_str());
        CoTaskMemFree(path);
    }
    if (mode == L"missing-import" && !HideOwnImport("SHGetFolderPathA")) return 21;
    if (mode == L"long-wide") {
        wchar_t path[MAX_PATH] = {};
        return HookSHGetFolderPathW(nullptr, CSIDL_PERSONAL, nullptr, 0, path) == E_INVALIDARG ? 0 : 22;
    }
    if (interactive) InstallSandboxHooks();
    else InstallHooks(); // invalid inputs/missing imports must terminate with code 9
    if (mode != L"valid" && !interactive) return 23;
    PWSTR known = nullptr;
    wchar_t wide[MAX_PATH] = {};
    char narrow[MAX_PATH] = {};
    if (FAILED(SHGetKnownFolderPath(FOLDERID_Documents, 0, nullptr, &known))) return 24;
    if (FAILED(SHGetFolderPathW(nullptr, CSIDL_PERSONAL, nullptr, 0, wide))) return 25;
    if (FAILED(SHGetFolderPathA(nullptr, CSIDL_PERSONAL, nullptr, 0, narrow))) return 26;
    const bool matches = SandboxDocuments() == known && SandboxDocuments() == wide;
    CoTaskMemFree(known);
    char expected[MAX_PATH] = {};
    WideCharToMultiByte(CP_ACP, 0, SandboxDocuments().c_str(), -1, expected, MAX_PATH, nullptr, nullptr);
    return matches && strcmp(narrow, expected) == 0 ? 0 : 27;
}
