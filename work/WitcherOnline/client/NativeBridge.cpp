#include "NativeBridge.h"
#include "pch.h"
#include "seamless/FactDeltaTracker.h"
#include <WitcherNativeBridgeApi.h>

#include <windows.h>
#include <bcrypt.h>
#include <winhttp.h>

#include <algorithm>
#include <array>
#include <atomic>
#include <cstdint>
#include <deque>
#include <fstream>
#include <iterator>
#include <list>
#include <mutex>
#include <string>
#include <thread>
#include <unordered_map>
#include <cstdio>
#include <cstring>
#include <utility>
#include <vector>

#pragma comment(lib, "version.lib")
#pragma comment(lib, "bcrypt.lib")
#pragma comment(lib, "winhttp.lib")

namespace wo_native
{
	static std::mutex g_logMutex;
	static std::ofstream g_logFile;
	static std::atomic<bool> g_registrationAttempted{false};
	static std::atomic<bool> g_registrationSucceeded{false};

	void InitLog(const std::string &path)
	{
		std::lock_guard<std::mutex> lock(g_logMutex);
		g_logFile.open(path, std::ios::out | std::ios::trunc);
	}

	void ShutdownLog()
	{
		std::lock_guard<std::mutex> lock(g_logMutex);
		if (g_logFile.is_open())
		{
			g_logFile.flush();
			g_logFile.close();
		}
	}

	void DebugLog(const std::string &text)
	{
		SYSTEMTIME now{};
		GetLocalTime(&now);

		char time[32]{};
		sprintf_s(time, sizeof(time), "%02u:%02u:%02u.%03u", now.wHour, now.wMinute, now.wSecond, now.wMilliseconds);
		const std::string message = std::string(time) + " WitcherOnline debug: " + text;

		OutputDebugStringA((message + "\n").c_str());

		std::lock_guard<std::mutex> lock(g_logMutex);
		if (g_logFile.is_open())
		{
			g_logFile << message << "\n";
			g_logFile.flush();
		}
	}

	static constexpr size_t kMaxQueueDepth = 4096;

	static std::mutex g_queueMutex;
	static std::deque<std::string> g_outbound;
	static std::array<std::string, 5> g_outboundRealtime;
	static std::array<bool, 5> g_outboundRealtimePending{};
	static size_t g_outboundRealtimeCursor = 0;
	static std::list<InboundMessage> g_inbound;
	static std::unordered_map<unsigned long long, std::list<InboundMessage>::iterator> g_inboundReplaceable;
	static InboundMessage g_current;

	static std::mutex g_stateMutex;
	static int g_localId = 0;
	static std::string g_username;
	static std::atomic<bool> g_connected{false};

	// Remastered (5.x) script strings are UTF-8 bytes; Next-Gen (4.x) strings are UTF-16.
	static bool g_utf8Strings = false;

	static bool IsRemasteredHost()
	{
		wchar_t path[MAX_PATH]{};
		if (GetModuleFileNameW(nullptr, path, MAX_PATH) == 0)
			return false;

		DWORD ignored = 0;
		const DWORD bytes = GetFileVersionInfoSizeW(path, &ignored);
		if (bytes == 0)
			return false;

		std::vector<uint8_t> data(bytes);
		VS_FIXEDFILEINFO *info = nullptr;
		UINT infoSize = 0;
		if (!GetFileVersionInfoW(path, 0, bytes, data.data()) || !VerQueryValueW(data.data(), L"\\", reinterpret_cast<LPVOID *>(&info), &infoSize) || !info)
			return false;

		return HIWORD(info->dwFileVersionMS) >= 5;
	}

	static bool IsReplaceableInbound(InboundOpcode opcode)
	{
		return opcode == InboundOpcode::Move || opcode == InboundOpcode::Update1 || opcode == InboundOpcode::Update2 || opcode == InboundOpcode::Update3 || opcode == InboundOpcode::Update4;
	}

	static unsigned long long InboundKey(const InboundMessage &message)
	{
		return (static_cast<unsigned long long>(static_cast<unsigned int>(message.playerId)) << 8) | static_cast<unsigned int>(message.opcode);
	}

	static int OutboundRealtimeSlot(const std::string &payload)
	{
		if (payload.rfind("move ", 0) == 0)
			return 0;
		if (payload.rfind("wo ", 0) == 0)
			return 1;
		if (payload.rfind("wo2 ", 0) == 0)
			return 2;
		if (payload.rfind("wo3 ", 0) == 0)
			return 3;
		if (payload.rfind("wo4 ", 0) == 0)
			return 4;
		return -1;
	}

	static uint32_t LogicalLength(const WNB_String &text)
	{
		return (text.data && text.size > 0) ? text.size - 1 : 0;
	}

	static std::string NarrowPayload(const WNB_String &text)
	{
		std::string out;
		if (!text.data)
			return out;

		const uint32_t length = LogicalLength(text);

		if (g_utf8Strings)
		{
			const char *bytes = reinterpret_cast<const char *>(text.data);
			out.assign(bytes, bytes + length);
			return out;
		}

		out.reserve(length);

		for (uint32_t i = 0; i < length; ++i)
		{
			const wchar_t c = text.data[i];
			out += (c < 256) ? static_cast<char>(c) : '?';
		}
		return out;
	}

	static std::wstring WidenPayload(const std::string &text)
	{
		if (!g_utf8Strings || text.empty())
			return std::wstring(text.begin(), text.end());

		const int chars = MultiByteToWideChar(CP_UTF8, 0, text.data(), static_cast<int>(text.size()), nullptr, 0);
		if (chars <= 0)
			return std::wstring(text.begin(), text.end());

		std::wstring wide(static_cast<size_t>(chars), L'\0');
		MultiByteToWideChar(CP_UTF8, 0, text.data(), static_cast<int>(text.size()), wide.data(), chars);
		return wide;
	}

	static bool ReturnString(void *frame, void *result, const std::string &text)
	{
		const std::wstring wide = WidenPayload(text);
		return WNB_ReturnString(frame, result, wide.c_str(), static_cast<uint32_t>(wide.size()));
	}

	static void ReturnName(void *frame, void *result, const std::string &text)
	{
		const std::wstring wide = WidenPayload(text);
		WNB_ReturnNameFromString(frame, result, wide.c_str());
	}

	static const std::string &CurrentField(int index)
	{
		static const std::string empty;
		if (index < 0 || static_cast<size_t>(index) >= g_current.fields.size())
			return empty;
		return g_current.fields[static_cast<size_t>(index)];
	}

	bool PopOutbound(std::string &payload)
	{
		std::lock_guard<std::mutex> lock(g_queueMutex);

		if (g_outboundRealtimePending[0])
		{
			payload = std::move(g_outboundRealtime[0]);
			g_outboundRealtime[0].clear();
			g_outboundRealtimePending[0] = false;
			return true;
		}

		for (size_t checked = 0; checked < 4; ++checked)
		{
			const size_t slot = 1 + ((g_outboundRealtimeCursor + checked) % 4);
			if (!g_outboundRealtimePending[slot])
				continue;

			payload = std::move(g_outboundRealtime[slot]);
			g_outboundRealtime[slot].clear();
			g_outboundRealtimePending[slot] = false;
			g_outboundRealtimeCursor = (slot - 1 + 1) % 4;
			return true;
		}

		if (!g_outbound.empty())
		{
			payload = std::move(g_outbound.front());
			g_outbound.pop_front();
			return true;
		}

		return false;
	}

	void PushInbound(InboundMessage &&message)
	{
		std::lock_guard<std::mutex> lock(g_queueMutex);
		const bool replaceable = IsReplaceableInbound(message.opcode);
		const unsigned long long key = replaceable ? InboundKey(message) : 0;

		if (replaceable)
		{
			auto found = g_inboundReplaceable.find(key);
			if (found != g_inboundReplaceable.end())
			{
				*(found->second) = std::move(message);
				return;
			}
		}

		if (g_inbound.size() >= kMaxQueueDepth)
		{
			if (IsReplaceableInbound(g_inbound.front().opcode))
				g_inboundReplaceable.erase(InboundKey(g_inbound.front()));
			g_inbound.pop_front();
		}

		g_inbound.push_back(std::move(message));
		if (replaceable)
		{
			auto inserted = g_inbound.end();
			--inserted;
			g_inboundReplaceable[key] = inserted;
		}
	}

	void SetLocalId(int id)
	{
		std::lock_guard<std::mutex> lock(g_stateMutex);
		g_localId = id;
	}

	void SetUsername(const std::string &name)
	{
		std::lock_guard<std::mutex> lock(g_stateMutex);
		g_username = name;
	}

	void SetConnected(bool connected)
	{
		g_connected.store(connected);
	}

	void PushControl(InboundOpcode opcode)
	{
		InboundMessage message;
		message.opcode = opcode;
		PushInbound(std::move(message));
	}

	// ---- facts: read the engine's facts database (party leader's quest facts for members) ----

	static bool ReadMemory(const void *address, void *out, size_t size)
	{
		__try
		{
			memcpy(out, address, size);
			return true;
		}
		__except (EXCEPTION_EXECUTE_HANDLER)
		{
			return false;
		}
	}

	struct FactsDbSite
	{
		bool searched = false;
		uint8_t *global = nullptr;
		int32_t countOffset = 0;
		int32_t systemsOffset = 0;
	};
	static FactsDbSite g_factsSite;

	// The facts natives reach the facts DB as game->systems[1] (seen in FactsQuerySum):
	//   mov rax,[rip+game]; ...; cmp dword [rax+count],1; jle; mov rax,[rax+systems]; mov rsi,[rax+8]
	static void FindFactsSite()
	{
		static const int pattern[] = {0x48, 0x8B, 0x05, -1, -1, -1, -1, -1, -1, -1, -1, -1, 0x48, 0x85, 0xC0, 0x0F, 0x84, -1, -1, -1, -1,
		                              0x83, 0xB8, -1, -1, -1, -1, 0x01, 0x0F, 0x8E, -1, -1, -1, -1, 0x48, 0x8B, 0x80, -1, -1, -1, -1, 0x48, 0x8B, 0x70, 0x08};
		const size_t length = sizeof(pattern) / sizeof(pattern[0]);

		g_factsSite.searched = true;
		auto *base = reinterpret_cast<uint8_t *>(GetModuleHandleW(nullptr));
		auto *dos = reinterpret_cast<IMAGE_DOS_HEADER *>(base);
		auto *nt = reinterpret_cast<IMAGE_NT_HEADERS64 *>(base + dos->e_lfanew);
		IMAGE_SECTION_HEADER *section = IMAGE_FIRST_SECTION(nt);
		for (unsigned s = 0; s < nt->FileHeader.NumberOfSections; ++s, ++section)
		{
			if (memcmp(section->Name, ".text", 5) != 0)
				continue;
			uint8_t *text = base + section->VirtualAddress;
			const size_t size = section->Misc.VirtualSize;
			for (size_t i = 0; i + length < size; ++i)
			{
				size_t k = 0;
				while (k < length && (pattern[k] < 0 || text[i + k] == pattern[k]))
					++k;
				if (k != length)
					continue;
				uint8_t *site = text + i;
				g_factsSite.global = site + 7 + *reinterpret_cast<int32_t *>(site + 3);
				g_factsSite.countOffset = *reinterpret_cast<int32_t *>(site + 23);
				g_factsSite.systemsOffset = *reinterpret_cast<int32_t *>(site + 37);
				return;
			}
		}
		DebugLog("facts: code pattern not found; fact sync is off");
	}

	static uint8_t *FindFactsDb()
	{
		if (!g_factsSite.searched)
			FindFactsSite();
		uint8_t *game = nullptr, *systems = nullptr, *facts = nullptr;
		int32_t count = 0;
		if (!g_factsSite.global || !ReadMemory(g_factsSite.global, &game, 8) || !game ||
		    !ReadMemory(game + g_factsSite.countOffset, &count, 4) || count <= 1 ||
		    !ReadMemory(game + g_factsSite.systemsOffset, &systems, 8) || !systems || !ReadMemory(systems + 8, &facts, 8))
			return nullptr;
		return facts;
	}

	static std::string g_factsError;

	// Sums of every fact. 5.01 layout (found by probing): the facts map sits at +0x58 of the facts DB, fact count
	// at +0x64; its nodes come from one pool, [+0x68, +0x80), node size at +0x74 (0x28), free slots linked from
	// +0x78. Node (pack 4): key text +0x00, key size +0x08, entries +0x0C, entry count +0x14, link +0x20; 24-byte
	// entries, the int value first. Anything off (unreadable memory, odd sizes, a used-slot count that doesn't
	// match the fact count) and it reports failure instead of guessing.
	static bool ReadAllFacts(std::unordered_map<std::string, int> &out)
	{
		uint8_t *db = FindFactsDb();
		if (!db)
		{
			g_factsError = "no facts DB";
			return false;
		}
		uint32_t factCount = 0, nodeSize = 0;
		uint8_t *pool = nullptr, *poolEnd = nullptr, *freeHead = nullptr;
		if (!ReadMemory(db + 0x64, &factCount, 4) || !ReadMemory(db + 0x74, &nodeSize, 4) || !ReadMemory(db + 0x68, &pool, 8) ||
		    !ReadMemory(db + 0x80, &poolEnd, 8) || !ReadMemory(db + 0x78, &freeHead, 8) || nodeSize != 0x28 || !pool || poolEnd <= pool ||
		    (poolEnd - pool) % nodeSize != 0 || (poolEnd - pool) / nodeSize > 4000000)
		{
			g_factsError = "map header: facts=" + std::to_string(factCount) + " node size=" + std::to_string(nodeSize);
			return false;
		}

		const size_t capacity = (poolEnd - pool) / nodeSize;
		std::vector<uint8_t> nodes(capacity * nodeSize);
		if (!ReadMemory(pool, nodes.data(), nodes.size()))
		{
			g_factsError = "pool unreadable (" + std::to_string(capacity) + " slots)";
			return false;
		}

		for (const size_t link : {size_t(0x20), size_t(0x00)})
		{
			std::vector<bool> isFree(capacity, false);
			size_t freeSlots = 0;
			for (uint8_t *slot = freeHead; slot >= pool && slot < poolEnd && freeSlots < capacity; ++freeSlots)
			{
				const size_t index = (slot - pool) / nodeSize;
				if ((slot - pool) % nodeSize != 0 || isFree[index])
					break;
				isFree[index] = true;
				slot = *reinterpret_cast<uint8_t **>(nodes.data() + index * nodeSize + link);
			}
			if (capacity - freeSlots != factCount)
				continue;

			out.clear();
			std::vector<uint8_t> entries;
			bool ok = true;
			for (size_t i = 0; i < capacity && ok; ++i)
			{
				if (isFree[i])
					continue;
				const uint8_t *raw = nodes.data() + i * nodeSize;
				const char *key = *reinterpret_cast<const char *const *>(raw);
				const uint32_t keySize = *reinterpret_cast<const uint32_t *>(raw + 0x08);
				uint8_t *values = *reinterpret_cast<uint8_t *const *>(raw + 0x0C);
				const uint32_t valueCount = *reinterpret_cast<const uint32_t *>(raw + 0x14);
				std::string id(keySize > 1 && keySize <= 1024 ? keySize - 1 : 0, '\0');
				if (id.empty() || valueCount > 1000000 || !ReadMemory(key, id.data(), id.size()))
				{
					g_factsError = "odd node " + std::to_string(i) + ": key size " + std::to_string(keySize) + ", entries " + std::to_string(valueCount);
					ok = false;
					break;
				}
				int sum = 0;
				if (valueCount > 0)
				{
					entries.resize(static_cast<size_t>(valueCount) * 24);
					if (!ReadMemory(values, entries.data(), entries.size()))
					{
						g_factsError = "entries unreadable at node " + std::to_string(i);
						ok = false;
						break;
					}
					for (uint32_t v = 0; v < valueCount; ++v)
						sum += *reinterpret_cast<int32_t *>(entries.data() + v * 24);
				}
				out[id] = sum;
			}
			if (ok && out.size() == factCount)
				return true;
			if (ok)
				g_factsError = "read " + std::to_string(out.size()) + " distinct facts, map says " + std::to_string(factCount);
			return false;
		}
		g_factsError = "free list doesn't match the fact count (" + std::to_string(factCount) + " facts, " + std::to_string(capacity) + " slots)";
		return false;
	}

	static std::unordered_map<std::string, int> g_factsBaseline;
	static bool g_factsBaselineValid = false;
	static size_t g_factsPage = 0;
	static seamless::FactDeltaTracker g_campaignFacts;
	static bool CampaignSnapshot(seamless::FactDeltaTracker::Snapshot &snapshot)
	{
		std::unordered_map<std::string, int> values;
		if (!ReadAllFacts(values)) return false;
		snapshot = {values.begin(), values.end()};
		return true;
	}

	static void WO_SCResetFacts(void *, void *frame, void *result)
	{
		WNB_ReturnInt(frame, result, g_campaignFacts.Reset());
		DebugLog("campaign: fact observation reset");
	}
	static void WO_SCWatchFact(void *, void *frame, void *result)
	{
		WNB_String value{};
		WNB_ReadStringParameter(frame, &value);
		seamless::FactDeltaTracker::Snapshot snapshot;
		const std::string target = NarrowPayload(value);
		WNB_ReturnBool(frame, result, seamless::FactDeltaTracker::IsAllowed(target) && CampaignSnapshot(snapshot) && g_campaignFacts.Watch(target, snapshot));
	}
	static void WO_SCReadFactChange(void *, void *frame, void *result)
	{
		seamless::FactDeltaTracker::Snapshot snapshot;
		seamless::FactChange change;
		if (!CampaignSnapshot(snapshot)) { ReturnString(frame, result, "ERROR SNAPSHOT"); return; }
		if (!g_campaignFacts.Observe(snapshot)) { ReturnString(frame, result, "ERROR CAPTURE"); return; }
		if (!g_campaignFacts.Peek(change)) { ReturnString(frame, result, ""); return; }
		ReturnString(frame, result, std::to_string(change.generation) + " " + std::to_string(change.revision) + " " + change.target + " " +
			(change.after.exists ? "1" : "0") + " " + std::to_string(change.after.value));
	}
	static void WO_SCAckFactChange(void *, void *frame, void *result)
	{
		const int generation = WNB_ReadIntParameter(frame);
		const int revision = WNB_ReadIntParameter(frame);
		WNB_ReturnBool(frame, result, g_campaignFacts.Ack(generation, revision));
	}
	static void WO_SCBeginRemoteFact(void *, void *frame, void *result)
	{
		WNB_String value{};
		WNB_ReadStringParameter(frame, &value);
		seamless::FactDeltaTracker::Snapshot snapshot;
		WNB_ReturnBool(frame, result, CampaignSnapshot(snapshot) && g_campaignFacts.BeginRemote(NarrowPayload(value), snapshot));
	}
	static void WO_SCEndRemoteFact(void *, void *frame, void *result)
	{
		seamless::FactDeltaTracker::Snapshot snapshot;
		WNB_ReturnBool(frame, result, CampaignSnapshot(snapshot) && g_campaignFacts.EndRemote(snapshot));
	}

	// session start (a save loaded): changes are counted from here
	static void WO_FactsBaseline(void *, void *frame, void *result)
	{
		g_factsBaseline.clear();
		g_factsBaselineValid = ReadAllFacts(g_factsBaseline);
		g_factsPage = 0;
		DebugLog("facts: baseline " + std::string(g_factsBaselineValid ? "of " + std::to_string(g_factsBaseline.size()) + " facts" : "failed (" + g_factsError + ")"));
		WNB_ReturnBool(frame, result, g_factsBaselineValid);
	}

	// "page pages count {id sum}" for facts whose sum changed since the baseline, one page per call in turn
	// (pages keep each message small; a member that joins late gets every page within a few calls)
	static void WO_FactsPage(void *, void *frame, void *result)
	{
		const int pageSize = (std::max)(1, WNB_ReadIntParameter(frame));
		std::unordered_map<std::string, int> current;
		if (!g_factsBaselineValid || !ReadAllFacts(current))
		{
			ReturnString(frame, result, "");
			return;
		}

		std::vector<std::pair<std::string, int>> changes;
		for (const auto &fact : current)
		{
			const auto before = g_factsBaseline.find(fact.first);
			if (before == g_factsBaseline.end() ? fact.second != 0 : before->second != fact.second)
				changes.emplace_back(fact.first, fact.second);
		}
		for (const auto &fact : g_factsBaseline)
		{
			if (current.find(fact.first) == current.end())
				changes.emplace_back(fact.first, 0);
		}
		std::sort(changes.begin(), changes.end());

		const size_t pages = changes.empty() ? 1 : (changes.size() + pageSize - 1) / pageSize;
		const size_t page = g_factsPage++ % pages;
		const size_t first = page * pageSize;
		const size_t last = (std::min)(changes.size(), first + pageSize);
		std::string text = std::to_string(page) + " " + std::to_string(pages) + " " + std::to_string(last - first);
		for (size_t i = first; i < last; ++i)
		{
			std::string id = changes[i].first;
			std::replace(id.begin(), id.end(), ' ', '*');
			text += " " + id + " " + std::to_string(changes[i].second);
		}
		ReturnString(frame, result, text);
	}

	// Only campaign bootstrap settings are visible to scripts. Never expose the
	// process environment wholesale or write the host proof to the diagnostic log.
	static std::string CampaignSetting(const std::string &key)
	{
		static const std::string session = [] {
			char persisted[65]{};
			const DWORD size = GetEnvironmentVariableA("WO_SC_SESSION", persisted, sizeof(persisted));
			if (size != 0)
			{
				if (size != 32) return std::string();
				for (DWORD i = 0; i < size; ++i)
					if (!((persisted[i] >= 'a' && persisted[i] <= 'f') || (persisted[i] >= '0' && persisted[i] <= '9'))) return std::string();
				return std::string(persisted);
			}
			unsigned char bytes[16]{};
			if (BCryptGenRandom(nullptr, bytes, sizeof(bytes), BCRYPT_USE_SYSTEM_PREFERRED_RNG) != 0)
				return std::string(); // fail closed: no predictable session identity
			static const char hex[] = "0123456789abcdef";
			std::string value;
			for (unsigned char byte : bytes) { value += hex[byte >> 4]; value += hex[byte & 15]; }
			return value;
		}();
		char enabled[8]{};
		if (GetEnvironmentVariableA("WO_SC_ENABLED", enabled, sizeof(enabled)) != 1 || enabled[0] != '1' || session.empty())
			return key == "enabled" ? "0" : "";
		if (key == "enabled") return "1";
		if (key == "session") return session;
		if (key == "effects")
		{
			char effects[8]{};
			return GetEnvironmentVariableA("WO_SC_EFFECTS", effects, sizeof(effects)) == 1 && effects[0] == '1' ? "1" : "0";
		}
		char role[16]{};
		const DWORD length = GetEnvironmentVariableA("WO_SC_ROLE", role, sizeof(role));
		const std::string roleValue = length > 0 && length < sizeof(role) ? role : "";
		if (roleValue != "host" && roleValue != "guest") return "";
		if (key == "role") return roleValue;
		if (key == "proof" && roleValue == "host")
		{
			char proof[129]{};
			const DWORD count = GetEnvironmentVariableA("WO_SC_HOST_TOKEN", proof, sizeof(proof));
			if (count < 32 || count >= sizeof(proof)) return "";
			for (DWORD i = 0; i < count; ++i)
				if (!((proof[i] >= 'a' && proof[i] <= 'f') || (proof[i] >= '0' && proof[i] <= '9'))) return "";
			return proof;
		}
		return "";
	}

	static void WO_SCConfig(void *, void *frame, void *result)
	{
		WNB_String key{};
		WNB_ReadStringParameter(frame, &key);
		const std::string name = NarrowPayload(key);
		const std::string value = CampaignSetting(name);
		if (name == "enabled" || name == "role" || name == "session" || name == "effects" || name == "proof")
			DebugLog("campaign: bootstrap field " + name + " available=" + (value.empty() ? "no" : "yes"));
		ReturnString(frame, result, value);
	}

	// Custom Player Characters (nikich340, installed by the player) in this game folder: its mod and
	// DLC folders next to the running witcher3.exe (<game>\bin\x64_dx12).
	static bool CustomPlayerCharactersInstalled()
	{
		char exe[MAX_PATH]{};
		const DWORD length = GetModuleFileNameA(nullptr, exe, MAX_PATH);
		if (length == 0 || length >= MAX_PATH) return false;
		std::string root(exe, length);
		for (int up = 0; up < 3; ++up)
		{
			const size_t cut = root.rfind('\\');
			if (cut == std::string::npos) return false;
			root.resize(cut);
		}
		const auto isFolder = [](const std::string &path) {
			const DWORD attributes = GetFileAttributesA(path.c_str());
			return attributes != INVALID_FILE_ATTRIBUTES && (attributes & FILE_ATTRIBUTE_DIRECTORY) != 0;
		};
		return isFolder(root + "\\mods\\modCustomPlayerCharacters") && isFolder(root + "\\dlc\\dlcCustomPlayerCharacters");
	}

	// Co-op session settings from the launcher (Play-LAN.ps1): W3LAN_SESSION_ROLE host|join,
	// W3LAN_SESSION_SAVE the host's save this player loads (a save file's base name),
	// W3LAN_SESSION_HOST the host's player name, and WO_USERNAME this player's ("player"); cpc: "1" with Custom Player Characters installed.
	// Anything malformed reads as empty.
	static std::string SessionSetting(const std::string &key)
	{
		if (key == "cpc") return CustomPlayerCharactersInstalled() ? "1" : "";
		const char *variable = key == "role" ? "W3LAN_SESSION_ROLE" : key == "save" ? "W3LAN_SESSION_SAVE" : key == "host" ? "W3LAN_SESSION_HOST" : key == "player" ? "WO_USERNAME" : nullptr;
		if (!variable) return "";
		char value[128]{};
		const DWORD length = GetEnvironmentVariableA(variable, value, sizeof(value));
		if (length == 0 || length >= sizeof(value)) return "";
		const std::string text(value, length);
		if (key == "role") return text == "host" || text == "join" ? text : "";
		const size_t maximum = key == "host" || key == "player" ? 16 : 120;
		if (text.size() > maximum) return "";
		for (char c : text)
		{
			const bool word = (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '_';
			if (!word && !(key == "save" && (c == '-' || c == '.'))) return "";
		}
		return text;
	}

	static void WO_SessionConfig(void *, void *frame, void *result)
	{
		WNB_String key{};
		WNB_ReadStringParameter(frame, &key);
		ReturnString(frame, result, SessionSetting(NarrowPayload(key)));
	}

	// Co-op lobby (coopLobby.ws): the host's server shares saves and the lobby over HTTP on the game
	// port + 1 (SaveShare.java, CoopLobby.java). Requests run on a worker thread so a slow or
	// missing host never stalls the game; scripts poll for the result.
	static std::wstring Widen(const std::string &text)
	{
		return std::wstring(text.begin(), text.end());
	}

	static bool SessionServer(std::string &host, INTERNET_PORT &port)
	{
		char ip[64]{};
		char gamePort[16]{};
		const DWORD ipLength = GetEnvironmentVariableA("WO_SERVER_IP", ip, sizeof(ip));
		const DWORD portLength = GetEnvironmentVariableA("WO_SERVER_PORT", gamePort, sizeof(gamePort));
		if (ipLength == 0 || ipLength >= sizeof(ip) || portLength == 0 || portLength >= sizeof(gamePort)) return false;
		for (DWORD i = 0; i < ipLength; ++i)
			if (!((ip[i] >= '0' && ip[i] <= '9') || ip[i] == '.')) return false;
		const int value = atoi(gamePort);
		if (value < 1 || value >= 65535) return false;
		host = ip;
		port = static_cast<INTERNET_PORT>(value + 1);
		return true;
	}

	// GET path from the host's session server; false when it cannot be reached or the reply breaks off.
	static bool SessionGet(const std::string &path, int &status, std::string &body)
	{
		std::string host;
		INTERNET_PORT port = 0;
		if (!SessionServer(host, port)) return false;
		HINTERNET session = WinHttpOpen(L"W3LAN", WINHTTP_ACCESS_TYPE_NO_PROXY, WINHTTP_NO_PROXY_NAME, WINHTTP_NO_PROXY_BYPASS, 0);
		if (!session) return false;
		WinHttpSetTimeouts(session, 2000, 2000, 5000, 60000);
		bool ok = false;
		HINTERNET connection = WinHttpConnect(session, Widen(host).c_str(), port, 0);
		HINTERNET request = connection ? WinHttpOpenRequest(connection, L"GET", Widen(path).c_str(), nullptr, WINHTTP_NO_REFERER, WINHTTP_DEFAULT_ACCEPT_TYPES, 0) : nullptr;
		if (request && WinHttpSendRequest(request, WINHTTP_NO_ADDITIONAL_HEADERS, 0, WINHTTP_NO_REQUEST_DATA, 0, 0, 0) && WinHttpReceiveResponse(request, nullptr))
		{
			DWORD code = 0;
			DWORD size = sizeof(code);
			WinHttpQueryHeaders(request, WINHTTP_QUERY_STATUS_CODE | WINHTTP_QUERY_FLAG_NUMBER, WINHTTP_HEADER_NAME_BY_INDEX, &code, &size, WINHTTP_NO_HEADER_INDEX);
			status = static_cast<int>(code);
			body.clear();
			ok = true;
			for (;;)
			{
				DWORD available = 0;
				if (!WinHttpQueryDataAvailable(request, &available)) { ok = false; break; }
				if (available == 0) break;
				std::string chunk(available, '\0');
				DWORD read = 0;
				if (!WinHttpReadData(request, &chunk[0], available, &read)) { ok = false; break; }
				body.append(chunk.data(), read);
				if (body.size() > 256u * 1024u * 1024u) { ok = false; break; }
			}
		}
		if (request) WinHttpCloseHandle(request);
		if (connection) WinHttpCloseHandle(connection);
		WinHttpCloseHandle(session);
		return ok;
	}

	static std::mutex g_lobbyMutex;
	static bool g_lobbyBusy = false;
	static std::deque<std::string> g_lobbyQueue; // requests waiting for the one in flight (kept in order)
	static std::string g_lobbyResult;            // "<status>\n<body>" or "error\n"; empty until a request completes
	static bool g_fetchBusy = false;
	static std::string g_fetchState = "idle";    // idle | busy | done | error <why>

	static bool SafeLobbyPath(const std::string &path)
	{
		if (path.rfind("/lobby", 0) != 0 || path.size() > 200) return false;
		for (char c : path)
			if (!((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '/' || c == '?' || c == '=' || c == '&' || c == '_' || c == '-' || c == '.')) return false;
		return true;
	}

	static bool SafeSaveName(const std::string &name)
	{
		if (name.empty() || name.size() > 120 || name[0] == '.' || name.find("..") != std::string::npos) return false;
		for (char c : name)
			if (!((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '_' || c == '-' || c == '.')) return false;
		return true;
	}

	// This player's co-op save folder (the profile's redirected Documents).
	static std::string SaveFolder()
	{
		char documents[MAX_PATH]{};
		DWORD length = GetEnvironmentVariableA("W3LAN_DOCUMENTS", documents, sizeof(documents));
		if (length == 0 || length >= sizeof(documents)) length = GetEnvironmentVariableA("W3T_DOCUMENTS", documents, sizeof(documents));
		if (length == 0 || length >= sizeof(documents)) return "";
		return std::string(documents, length) + "\\The Witcher 3\\gamesaves";
	}

	// "" when stored (or an optional file the host lacks), otherwise "error <why>"
	static std::string FetchSaveFile(const std::string &folder, const std::string &file, bool required)
	{
		int status = 0;
		std::string body;
		if (!SessionGet("/session/save/" + file, status, body)) return "error the host did not answer";
		if (status != 200) return required ? "error the host has no " + file : "";
		const std::string target = folder + "\\" + file;
		const std::string partial = target + ".download";
		{
			std::ofstream out(partial, std::ios::binary | std::ios::trunc);
			if (!out) return "error cannot write " + file;
			out.write(body.data(), static_cast<std::streamsize>(body.size()));
			if (!out) return "error cannot write " + file;
		}
		if (!MoveFileExA(partial.c_str(), target.c_str(), MOVEFILE_REPLACE_EXISTING)) return "error cannot store " + file;
		return "";
	}

	static void WO_LobbyRequest(void *, void *frame, void *result)
	{
		WNB_String text{};
		WNB_ReadStringParameter(frame, &text);
		const std::string path = NarrowPayload(text);
		bool queued = false;
		if (SafeLobbyPath(path))
		{
			std::lock_guard<std::mutex> lock(g_lobbyMutex);
			if (g_lobbyQueue.size() < 8)
			{
				g_lobbyQueue.push_back(path);
				queued = true;
			}
			if (!g_lobbyBusy)
			{
				g_lobbyBusy = true;
				// one worker runs the queued requests in order, then ends
				std::thread([] {
					for (;;)
					{
						std::string next;
						{
							std::lock_guard<std::mutex> take(g_lobbyMutex);
							if (g_lobbyQueue.empty()) { g_lobbyBusy = false; return; }
							next = g_lobbyQueue.front();
							g_lobbyQueue.pop_front();
						}
						int status = 0;
						std::string body;
						const bool ok = SessionGet(next, status, body);
						std::lock_guard<std::mutex> done(g_lobbyMutex);
						g_lobbyResult = ok ? std::to_string(status) + "\n" + body : std::string("error\n");
					}
				}).detach();
			}
		}
		WNB_ReturnBool(frame, result, queued);
	}

	// The last reply, lines joined by '|' (scripts have no newline escape): "200|host=...|state=...|"
	static void WO_LobbyResult(void *, void *frame, void *result)
	{
		std::string value;
		{
			std::lock_guard<std::mutex> lock(g_lobbyMutex);
			value.swap(g_lobbyResult);
		}
		value.erase(std::remove(value.begin(), value.end(), '\r'), value.end());
		std::replace(value.begin(), value.end(), '\n', '|');
		ReturnString(frame, result, value);
	}

	static void WO_LobbyFetchSave(void *, void *frame, void *result)
	{
		WNB_String text{};
		WNB_ReadStringParameter(frame, &text);
		const std::string name = NarrowPayload(text);
		const std::string folder = SaveFolder();
		bool started = false;
		if (SafeSaveName(name) && !folder.empty())
		{
			std::lock_guard<std::mutex> lock(g_lobbyMutex);
			if (!g_fetchBusy)
			{
				g_fetchBusy = true;
				g_fetchState = "busy";
				started = true;
				std::thread([name, folder] {
					std::string state = FetchSaveFile(folder, name + ".sav", true);
					if (state.empty()) FetchSaveFile(folder, name + ".png", false);   // the thumbnail is optional
					std::lock_guard<std::mutex> done(g_lobbyMutex);
					g_fetchState = state.empty() ? "done" : state;
					g_fetchBusy = false;
				}).detach();
			}
		}
		WNB_ReturnBool(frame, result, started);
	}

	static void WO_LobbyFetchState(void *, void *frame, void *result)
	{
		std::string value;
		{
			std::lock_guard<std::mutex> lock(g_lobbyMutex);
			value = g_fetchState;
		}
		ReturnString(frame, result, value);
	}

	// Per-player characters (coopCharacter.ws): a joining player's own character in the host's game,
	// one file per host in the co-op profile, "The Witcher 3\coop-characters\<host>.txt". Scripts
	// join lines with '|' (no newline escape); the file keeps one record per line.
	static std::string CharacterFile()
	{
		const std::string host = SessionSetting("host");
		const std::string saves = SaveFolder();
		if (host.empty() || saves.empty()) return "";
		const std::string folder = saves.substr(0, saves.rfind('\\')) + "\\coop-characters";
		CreateDirectoryA(folder.c_str(), nullptr);
		return folder + "\\" + host + ".txt";
	}

	static void WO_CharacterStore(void *, void *frame, void *result)
	{
		WNB_String text{};
		WNB_ReadStringParameter(frame, &text);
		std::string body = NarrowPayload(text);
		const std::string file = CharacterFile();
		bool stored = false;
		if (!file.empty() && !body.empty() && body.size() < 4u * 1024u * 1024u)
		{
			std::replace(body.begin(), body.end(), '|', '\n');
			const std::string partial = file + ".tmp";
			{
				std::ofstream out(partial, std::ios::binary | std::ios::trunc);
				out.write(body.data(), static_cast<std::streamsize>(body.size()));
				stored = static_cast<bool>(out);
			}
			// replace the old record only with a complete new one
			stored = stored && MoveFileExA(partial.c_str(), file.c_str(), MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH);
		}
		WNB_ReturnBool(frame, result, stored);
	}

	// The stored character, lines joined by '|'; "" when there is none.
	static void WO_CharacterLoad(void *, void *frame, void *result)
	{
		std::string body;
		const std::string file = CharacterFile();
		if (!file.empty())
		{
			std::ifstream in(file, std::ios::binary);
			if (in) body.assign(std::istreambuf_iterator<char>(in), std::istreambuf_iterator<char>());
		}
		body.erase(std::remove(body.begin(), body.end(), '\r'), body.end());
		std::replace(body.begin(), body.end(), '\n', '|');
		ReturnString(frame, result, body);
	}

	// Before a restore replaces the character: the stored record as it is now, in
	// coop-characters\backups\<host>-<time>.txt; the newest 10 are kept.
	static void WO_CharacterBackup(void *, void *frame, void *result)
	{
		const std::string file = CharacterFile();
		bool copied = false;
		if (!file.empty() && GetFileAttributesA(file.c_str()) != INVALID_FILE_ATTRIBUTES)
		{
			const std::string folder = file.substr(0, file.rfind('\\')) + "\\backups";
			const std::string host = SessionSetting("host");
			CreateDirectoryA(folder.c_str(), nullptr);
			SYSTEMTIME now{};
			GetLocalTime(&now);
			char stamp[32]{};
			sprintf_s(stamp, sizeof(stamp), "%04u%02u%02u-%02u%02u%02u", now.wYear, now.wMonth, now.wDay, now.wHour, now.wMinute, now.wSecond);
			copied = CopyFileA(file.c_str(), (folder + "\\" + host + "-" + stamp + ".txt").c_str(), FALSE) != 0;
			// the names sort by time: drop all but the newest 10
			std::vector<std::string> names;
			WIN32_FIND_DATAA found{};
			HANDLE search = FindFirstFileA((folder + "\\" + host + "-*.txt").c_str(), &found);
			if (search != INVALID_HANDLE_VALUE)
			{
				do { names.push_back(found.cFileName); } while (FindNextFileA(search, &found));
				FindClose(search);
			}
			std::sort(names.begin(), names.end());
			for (size_t i = 0; i + 10 < names.size(); ++i) DeleteFileA((folder + "\\" + names[i]).c_str());
		}
		WNB_ReturnBool(frame, result, copied);
	}

	// A line for the player's log (WitcherOnline_<name>.log): what the co-op scripts did.
	static void WO_Log(void *, void *frame, void *result)
	{
		WNB_String text{};
		WNB_ReadStringParameter(frame, &text);
		std::string line = NarrowPayload(text);
		if (line.size() > 2000) line.resize(2000);
		if (!line.empty()) DebugLog("coop " + line);
		WNB_ReturnBool(frame, result, !line.empty());
	}

	// A game name (item, recipe, ability) from text: scripts cannot convert a string to a name.
	static void WO_ToName(void *, void *frame, void *result)
	{
		WNB_String text{};
		WNB_ReadStringParameter(frame, &text);
		ReturnName(frame, result, NarrowPayload(text));
	}

	static void WO_SCInstance(void *, void *frame, void *result)
	{
		static const std::string nonce = [] {
			unsigned char bytes[16]{};
			if (BCryptGenRandom(nullptr, bytes, sizeof(bytes), BCRYPT_USE_SYSTEM_PREFERRED_RNG) != 0) return std::string();
			static const char hex[] = "0123456789abcdef";
			std::string value;
			for (unsigned char byte : bytes) { value += hex[byte >> 4]; value += hex[byte & 15]; }
			return value;
		}();
		static std::atomic<std::uint64_t> serial{0};
		const std::uint64_t next = serial.fetch_add(1) + 1;
		ReturnString(frame, result, CampaignSetting("enabled") == "1" && !nonce.empty() && next != 0 ? nonce + "-" + std::to_string(next) : "");
	}

	static void WO_Send(void *, void *frame, void *result)
	{
		WNB_String text{};
		const int size = WNB_ReadStringParameter(frame, &text);

		bool queued = false;

		if (!g_connected.load())
		{
			WNB_ReturnBool(frame, result, false);
			return;
		}

		if (size > 0)
		{
			std::string payload = NarrowPayload(text);
			if (!payload.empty())
			{
				std::lock_guard<std::mutex> lock(g_queueMutex);
				const int slot = OutboundRealtimeSlot(payload);

				if (slot >= 0)
				{
					g_outboundRealtime[slot] = std::move(payload);
					g_outboundRealtimePending[slot] = true;
				}
				else
				{
					if (g_outbound.size() >= kMaxQueueDepth)
						g_outbound.pop_front();
					g_outbound.push_back(std::move(payload));
				}

				queued = true;
			}
		}

		WNB_ReturnBool(frame, result, queued);
	}

	static constexpr ULONGLONG kWoTransportIntervalMs = 20;
	static constexpr ULONGLONG kWoGather1IntervalMs = 50;
	static constexpr ULONGLONG kWoGather2IntervalMs = 500;
	static constexpr ULONGLONG kWoGather3IntervalMs = 100;
	static constexpr ULONGLONG kWoGather4IntervalMs = 50;

	static ULONGLONG g_woNextTransportMs = 0;
	static ULONGLONG g_woNextGather1Ms = 0;
	static ULONGLONG g_woNextGather2Ms = 0;
	static ULONGLONG g_woNextGather3Ms = 0;
	static ULONGLONG g_woNextGather4Ms = 0;
	static bool g_woTickWasConnected = false;

	static void ResetWoTickSchedule()
	{
		g_woNextTransportMs = 0;
		g_woNextGather1Ms = 0;
		g_woNextGather2Ms = 0;
		g_woNextGather3Ms = 0;
		g_woNextGather4Ms = 0;
	}

	static bool WoTickDue(ULONGLONG now, ULONGLONG &next, ULONGLONG interval)
	{
		if (next == 0)
		{
			next = now + interval;
			return true;
		}

		if (now < next)
			return false;

		if ((now - next) > interval * 8ULL)
		{
			next = now + interval;
		}
		else
		{
			do
			{
				next += interval;
			} while (next <= now);
		}

		return true;
	}

	static void WO_Tick(void *, void *frame, void *result)
	{
		int mask = 0;
		const bool connected = g_connected.load();

		if (!connected)
		{
			ResetWoTickSchedule();
			g_woTickWasConnected = false;
		}
		else
		{
			if (!g_woTickWasConnected)
			{
				ResetWoTickSchedule();
				g_woTickWasConnected = true;
			}

			const ULONGLONG now = GetTickCount64();

			if (WoTickDue(now, g_woNextTransportMs, kWoTransportIntervalMs))
				mask += 1;
			if (WoTickDue(now, g_woNextGather1Ms, kWoGather1IntervalMs))
				mask += 2;
			if (WoTickDue(now, g_woNextGather2Ms, kWoGather2IntervalMs))
				mask += 4;
			if (WoTickDue(now, g_woNextGather3Ms, kWoGather3IntervalMs))
				mask += 8;
			if (WoTickDue(now, g_woNextGather4Ms, kWoGather4IntervalMs))
				mask += 16;
		}

		WNB_ReturnInt(frame, result, mask);
	}

	static void WO_Poll(void *, void *frame, void *result)
	{
		int opcode = -1;

		{
			std::lock_guard<std::mutex> lock(g_queueMutex);
			if (!g_inbound.empty())
			{
				g_current = std::move(g_inbound.front());
				if (IsReplaceableInbound(g_current.opcode))
					g_inboundReplaceable.erase(InboundKey(g_current));
				g_inbound.pop_front();
				opcode = static_cast<int>(g_current.opcode);
			}
			else
			{
				g_current = InboundMessage();
			}
		}

		WNB_ReturnInt(frame, result, opcode);
	}

	static void WO_Str(void *, void *frame, void *result)
	{
		const int index = WNB_ReadIntParameter(frame);

		if (index == -1)
		{
			ReturnString(frame, result, g_current.sender);
			return;
		}
		if (index == -2)
		{
			ReturnString(frame, result, std::to_string(g_current.playerId));
			return;
		}
		if (index == -3)
		{
			ReturnString(frame, result, std::to_string(g_current.fields.size()));
			return;
		}
		if (index == -4)
		{
			std::string localName;
			{
				std::lock_guard<std::mutex> lock(g_stateMutex);
				localName = g_username;
			}
			ReturnString(frame, result, localName);
			return;
		}
		if (index == -5)
		{
			int localId = 0;
			{
				std::lock_guard<std::mutex> lock(g_stateMutex);
				localId = g_localId;
			}
			ReturnString(frame, result, std::to_string(localId));
			return;
		}

		ReturnString(frame, result, CurrentField(index));
	}

	static void WO_NameAt(void *, void *frame, void *result)
	{
		const int index = WNB_ReadIntParameter(frame);

		if (index == -1)
		{
			ReturnName(frame, result, g_current.sender);
			return;
		}

		ReturnName(frame, result, CurrentField(index));
	}

	bool RegisterNatives()
	{
		if (g_registrationAttempted.exchange(true))
			return g_registrationSucceeded.load();

		const uint32_t apiVersion = WNB_GetApiVersion();
		if (apiVersion < WNB_API_VERSION)
		{
			DebugLog("WitcherNativeBridge API is too old: found " + std::to_string(apiVersion) + ", need " + std::to_string(WNB_API_VERSION));
			return false;
		}

		g_utf8Strings = IsRemasteredHost();
		DebugLog(std::string("script string encoding: ") + (g_utf8Strings ? "UTF-8 (Remastered)" : "UTF-16 (Next-Gen)"));

		struct NativeRegistration
		{
			const char *name;
			WNB_NativeImplementation implementation;
		};

		const NativeRegistration registrations[] = {
		    {"WO_Send", &WO_Send}, {"WO_Poll", &WO_Poll}, {"WO_Tick", &WO_Tick}, {"WO_Str", &WO_Str}, {"WO_NameAt", &WO_NameAt},
		    {"WO_FactsBaseline", &WO_FactsBaseline}, {"WO_FactsPage", &WO_FactsPage},
		    {"WO_SCConfig", &WO_SCConfig},
		    {"WO_SessionConfig", &WO_SessionConfig},
		    {"WO_LobbyRequest", &WO_LobbyRequest}, {"WO_LobbyResult", &WO_LobbyResult},
		    {"WO_LobbyFetchSave", &WO_LobbyFetchSave}, {"WO_LobbyFetchState", &WO_LobbyFetchState},
		    {"WO_CharacterStore", &WO_CharacterStore}, {"WO_CharacterLoad", &WO_CharacterLoad}, {"WO_ToName", &WO_ToName},
		    {"WO_CharacterBackup", &WO_CharacterBackup}, {"WO_Log", &WO_Log},
		    {"WO_SCInstance", &WO_SCInstance},
		    {"WO_SCResetFacts", &WO_SCResetFacts}, {"WO_SCWatchFact", &WO_SCWatchFact},
		    {"WO_SCReadFactChange", &WO_SCReadFactChange}, {"WO_SCAckFactChange", &WO_SCAckFactChange},
		    {"WO_SCBeginRemoteFact", &WO_SCBeginRemoteFact}, {"WO_SCEndRemoteFact", &WO_SCEndRemoteFact},
		};

		int registeredCount = 0;
		bool success = true;

		for (const NativeRegistration &registration : registrations)
		{
			if (WNB_RegisterNative(registration.name, registration.implementation))
			{
				++registeredCount;
				continue;
			}

			DebugLog(std::string("failed to register native through WitcherNativeBridge: ") + registration.name);
			success = false;
		}

		g_registrationSucceeded.store(success);

		DebugLog("WitcherNativeBridge API version=" + std::to_string(apiVersion) + " registered WitcherOnline natives=" + std::to_string(registeredCount) + "/" + std::to_string(sizeof(registrations) / sizeof(registrations[0])));

		return success;
	}

	bool IsConnected()
	{
		return g_connected.load();
	}
} // namespace wo_native
