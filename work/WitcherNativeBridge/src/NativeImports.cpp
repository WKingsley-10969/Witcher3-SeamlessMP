#include "NativeImports.h"
#include "NativeBridge.h"
#include "FactOperationJournal.h"

#include <windows.h>
#include <iomanip>
#include <limits>
#include <locale>
#include <mutex>
#include <sstream>
#include <string>

namespace witcher_native_bridge::imports
{
	namespace
	{
		FactOperationJournal g_factOperations;
		std::mutex g_factOperationsMutex;

		bool FactOperationsEnabled()
		{
			char enabled[8]{};
			return GetEnvironmentVariableA("WO_SC_CAPTURE", enabled, sizeof(enabled)) == 1 && enabled[0] == '1';
		}

		std::string ReadUtf8(void* frame)
		{
			ScriptString input{};
			if (ReadStringParameter(frame, input) <= 0) return {};
			return ScriptStringToUtf8Lossy(input);
		}

		void FactOpsReset(void*, void* frame, void* result)
		{
			std::lock_guard<std::mutex> lock(g_factOperationsMutex);
			ReturnInt(frame, result, g_factOperations.Reset());
		}
		void FactOpsActive(void*, void* frame, void* result)
		{
			std::lock_guard<std::mutex> lock(g_factOperationsMutex);
			ReturnBool(frame, result, FactOperationsEnabled() && g_factOperations.Active() && g_factOperations.Error().empty());
		}
		void FactOpsBegin(void*, void* frame, void* result)
		{
			const std::string scope = ReadUtf8(frame);
			std::lock_guard<std::mutex> lock(g_factOperationsMutex);
			ReturnBool(frame, result, FactOperationsEnabled() && g_factOperations.Begin(scope));
		}
		void FactOpsWatch(void*, void* frame, void* result)
		{
			const std::string target = ReadUtf8(frame);
			std::lock_guard<std::mutex> lock(g_factOperationsMutex);
			ReturnBool(frame, result, FactOperationsEnabled() && g_factOperations.Watch(target));
		}
		void FactOpsEnd(void*, void* frame, void* result)
		{
			std::lock_guard<std::mutex> lock(g_factOperationsMutex);
			ReturnBool(frame, result, g_factOperations.End());
		}
		void FactOpsBeginRemote(void*, void* frame, void* result)
		{
			std::lock_guard<std::mutex> lock(g_factOperationsMutex);
			ReturnBool(frame, result, FactOperationsEnabled() && g_factOperations.BeginRemote());
		}
		void FactOpsEndRemote(void*, void* frame, void* result)
		{
			std::lock_guard<std::mutex> lock(g_factOperationsMutex);
			ReturnBool(frame, result, g_factOperations.EndRemote());
		}
		void FactOpsRecord(void*, void* frame, void* result)
		{
			const std::string kind = ReadUtf8(frame);
			const std::string target = ReadUtf8(frame);
			const int value = ReadIntParameter(frame);
			const int validFor = ReadIntParameter(frame);
			const bool telemetry = ReadBoolParameter(frame);
			const float observedAt = ReadFloatParameter(frame);
			std::lock_guard<std::mutex> lock(g_factOperationsMutex);
			ReturnBool(frame, result, FactOperationsEnabled() && g_factOperations.Record(kind, target, value, validFor, telemetry, observedAt));
		}
		void FactOpsPeek(void*, void* frame, void* result)
		{
			std::string text;
			{
				std::lock_guard<std::mutex> lock(g_factOperationsMutex);
				FactOperation operation;
				if (!FactOperationsEnabled()) text = "DISABLED";
				else if (!g_factOperations.Error().empty()) text = "ERROR " + g_factOperations.Error();
				else if (g_factOperations.Peek(operation)) {
					std::ostringstream out;
					out.imbue(std::locale::classic());
					out << std::setprecision(std::numeric_limits<float>::max_digits10)
						<< operation.generation << ' ' << operation.revision << ' ' << operation.scope << ' '
						<< operation.kind << ' ' << operation.target << ' ' << operation.value << ' '
						<< operation.validFor << ' ' << (operation.telemetry ? 1 : 0) << ' ' << operation.observedAt;
					text = out.str();
				}
			}
			const std::wstring wide(text.begin(), text.end());
			ReturnString(frame, result, wide.c_str(), wide.size());
		}
		void FactOpsAck(void*, void* frame, void* result)
		{
			const int generation = ReadIntParameter(frame);
			const int revision = ReadIntParameter(frame);
			std::lock_guard<std::mutex> lock(g_factOperationsMutex);
			ReturnBool(frame, result, FactOperationsEnabled() && g_factOperations.Error().empty() && g_factOperations.Ack(generation, revision));
		}
		void FactOpsStatus(void*, void* frame, void* result)
		{
			std::string status;
			{
				std::lock_guard<std::mutex> lock(g_factOperationsMutex);
				status = !FactOperationsEnabled() ? "DISABLED" : !g_factOperations.Error().empty() ? g_factOperations.Error()
					: g_factOperations.ApplyingRemote() ? "REMOTE" : g_factOperations.Active() ? "CAPTURING" : "IDLE";
			}
			const std::wstring wide(status.begin(), status.end());
			ReturnString(frame, result, wide.c_str(), wide.size());
		}
		struct NativeRegistration
		{
			const char* name;
			WNB_NativeImplementation implementation;
		};

		// WitcherScript declaration:
		// import function WNB_GetApiVersion() : int;
		void GetApiVersionNative(void*, void* frame, void* result)
		{
			ReturnInt(frame, result, static_cast<int>(WNB_GetApiVersion()));
		}

		// WitcherScript declaration:
		// import function WNB_StringToName(value : string) : name;
		void StringToNameNative(void*, void* frame, void* result)
		{
			ScriptString input{};
			const int readSize = ReadStringParameter(frame, input);

			if (readSize <= 0)
			{
				ReturnNameFromString(frame, result, L"");
				return;
			}

			const std::wstring value = ScriptStringToWide(input);
			ReturnNameFromString(frame, result, value.c_str());
		}
	} // namespace

	bool RegisterAll()
	{
		const NativeRegistration registrations[] = {
		    {"WNB_GetApiVersion", &GetApiVersionNative},
		    {"WNB_StringToName", &StringToNameNative},
		    {"WNB_FactOpsReset", &FactOpsReset}, {"WNB_FactOpsBegin", &FactOpsBegin},
		    {"WNB_FactOpsActive", &FactOpsActive},
		    {"WNB_FactOpsWatch", &FactOpsWatch}, {"WNB_FactOpsEnd", &FactOpsEnd},
		    {"WNB_FactOpsBeginRemote", &FactOpsBeginRemote}, {"WNB_FactOpsEndRemote", &FactOpsEndRemote},
		    {"WNB_FactOpsRecord", &FactOpsRecord}, {"WNB_FactOpsPeek", &FactOpsPeek},
		    {"WNB_FactOpsAck", &FactOpsAck}, {"WNB_FactOpsStatus", &FactOpsStatus},
		};

		bool success = true;
		int registeredCount = 0;

		for (const NativeRegistration& registration : registrations)
		{
			if (WNB_RegisterNative(registration.name, registration.implementation))
			{
				++registeredCount;
				DebugLog(std::string("built-in import queued: ") + registration.name + "=OK");
				continue;
			}

			DebugLog(std::string("built-in import queued: ") + registration.name + "=FAILED");
			success = false;
		}

		DebugLog("built-in imports queued=" + std::to_string(registeredCount) + "/" + std::to_string(sizeof(registrations) / sizeof(registrations[0])));
		return success;
	}
} // namespace witcher_native_bridge::imports
