// Copyright 2010-2021, Google Inc.
// Copyright 2026, elecxzy project
// All rights reserved.
//
// Redistribution and use in source and binary forms, with or without
// modification, are permitted provided that the following conditions are
// met:
//
//     * Redistributions of source code must retain the above copyright
// notice, this list of conditions and the following disclaimer.
//     * Redistributions in binary form must reproduce the above
// copyright notice, this list of conditions and the following disclaimer
// in the documentation and/or other materials provided with the
// distribution.
//     * Neither the name of Google Inc. nor the names of its
// contributors may be used to endorse or promote products derived from
// this software without specific prior written permission.
//
// THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS
// "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT
// LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR
// A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT
// OWNER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL,
// SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT
// LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE,
// DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY
// THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
// (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
// OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.

// mozc_emacs_helper compatible process with the Mozc engine linked in.
//
// Speaks the same S-expression protocol as unix/emacs/mozc_emacs_helper, but
// evaluates commands with an in-process SessionHandler instead of talking to
// mozc_server over IPC.

#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <iostream>
#include <memory>
#include <string>
#include <utility>
#include <vector>

#include "absl/container/flat_hash_map.h"
#include "absl/flags/flag.h"
#include "absl/flags/internal/parse.h"
#include "absl/status/status.h"
#include "absl/strings/ascii.h"
#include "absl/strings/match.h"
#include "absl/strings/str_cat.h"
#include "absl/strings/str_format.h"
#include "absl/strings/str_join.h"
#include "absl/strings/string_view.h"
#include "absl/synchronization/mutex.h"
#include "absl/time/clock.h"
#include "absl/time/time.h"
#include "base/file_util.h"
#include "base/init_mozc.h"
#include "base/system_util.h"
#include "base/version.h"
#include "config/config_handler.h"
#include "engine/engine_factory.h"
#include "engine/engine_interface.h"
#include "protocol/commands.pb.h"
#include "session/session_handler.h"
#include "unix/emacs/mozc_emacs_helper_lib.h"

#ifdef _WIN32
#include <fcntl.h>
#include <io.h>
// clang-format off
#include <windows.h>
#include <shellapi.h>  // for CommandLineToArgvW
// clang-format on

#include "base/win32/wide_char.h"
#endif  // _WIN32

ABSL_FLAG(bool, suppress_stderr, false, "Discards all the output to stderr.");
ABSL_FLAG(std::string, profile_dir, "",
          "Directory for the learning data, the user dictionary and the "
          "config, instead of %USERPROFILE%\\AppData\\LocalLow\\Mozc. "
          "Must be an absolute path; created if missing, but its parent "
          "must exist.");

namespace mozc::emacs {
namespace {

// mozc_server saves the learning data from its watchdog every minute, and
// whenever a session is deleted.  mozc.el deletes a session only when Mozc is
// turned off, and Emacs ends the helper without letting it return from main
// (quit-process sends CTRL_BREAK_EVENT; delete-process and exiting Emacs send
// CTRL_CLOSE_EVENT).  So the helper saves after commits and on every way out.
constexpr absl::Duration kSyncInterval = absl::Seconds(60);

// Serializes the engine between the main thread and the console control
// handler thread.  `g_engine` is the engine owned by the SessionHandler, and
// is cleared before the handler is destroyed.
ABSL_CONST_INIT absl::Mutex g_mutex(absl::kConstInit);
EngineInterface* g_engine ABSL_GUARDED_BY(g_mutex) = nullptr;

bool Eval(SessionHandler& handler, commands::Command& command) {
  absl::MutexLock lock(g_mutex);
  return handler.EvalCommand(&command);
}

// Starts saving the learning data in the background.  Cheap when nothing
// has been learned since the last save.
void StartSaving() {
  absl::MutexLock lock(g_mutex);
  if (g_engine != nullptr) {
    g_engine->Sync();
  }
}

// Saves the learning data and waits for it.
void SaveAndWait() {
  absl::MutexLock lock(g_mutex);
  if (g_engine != nullptr) {
    g_engine->Sync();
    g_engine->Wait();
  }
}

#ifdef _WIN32
BOOL WINAPI OnConsoleCtrl(DWORD) {
  SaveAndWait();
  return FALSE;  // The default handler ends the process.
}
#endif  // _WIN32

// Creates an engine session and turns it on.  Returns 0 on failure.
uint64_t CreateEngineSession(SessionHandler& handler) {
  commands::Command command;
  command.mutable_input()->set_type(commands::Input::CREATE_SESSION);
  if (!Eval(handler, command) || command.output().id() == 0) {
    return 0;
  }
  const uint64_t id = command.output().id();
  // Windows sessions start in DIRECT mode; mozc.el expects the session to be
  // active like on Linux, so turn it on.
  commands::Command on;
  on.mutable_input()->set_type(commands::Input::SEND_KEY);
  on.mutable_input()->set_id(id);
  on.mutable_input()->mutable_key()->set_special_key(commands::KeyEvent::ON);
  Eval(handler, on);
  return id;
}

void PrintGreetingMessage() {
  std::shared_ptr<const config::Config> config =
      config::ConfigHandler::GetSharedConfig();
  absl::string_view preedit_method = "unknown";
  switch (config->preedit_method()) {
    case config::Config::ROMAN:
      preedit_method = "roman";
      break;
    case config::Config::KANA:
      preedit_method = "kana";
      break;
  }

  absl::FPrintF(stdout,
                "((mozc-emacs-helper . t)(version . %s)"
                "(config . ((preedit-method . %s))))\n",
                QuoteString(Version::GetMozcVersion()), preedit_method);
  fflush(stdout);
}

// "C:\..." or "\\server\...".  A relative path would be resolved against
// whatever directory Emacs started the helper in, which mozc-user-dict.el
// cannot know.
bool IsAbsolutePath(absl::string_view path) {
#ifdef _WIN32
  auto is_sep = [](char c) { return c == '\\' || c == '/'; };
  return (path.size() >= 3 && absl::ascii_isalpha(path[0]) && path[1] == ':' &&
          is_sep(path[2])) ||
         (path.size() >= 2 && is_sep(path[0]) && is_sep(path[1]));
#else   // _WIN32
  return absl::StartsWith(path, "/");
#endif  // _WIN32
}

void ProcessLoop(SessionHandler& handler) {
  // The emacs protocol carries 32-bit session ids, while SessionHandler uses
  // 64-bit ones.  Map small sequential ids to the engine's ids.
  absl::flat_hash_map<uint32_t, uint64_t> sessions;
  uint32_t next_session_id = 1;
  absl::Time last_sync = absl::InfinitePast();
  commands::Command command;
  std::string line;

  while (std::getline(std::cin, line)) {
    if (!line.empty() && line.back() == '\r') {
      line.pop_back();
    }
    command.Clear();
    uint32_t event_id = 0;
    uint32_t session_id = 0;

    ParseInputLine(line, &event_id, &session_id, command.mutable_input());

    switch (command.input().type()) {
      case commands::Input::CREATE_SESSION:
        if (const uint64_t id = CreateEngineSession(handler); id != 0) {
          while (sessions.contains(next_session_id)) {
            ++next_session_id;
          }
          session_id = next_session_id++;
          sessions[session_id] = id;
        } else {
          ErrorExit(kErrSessionError, "Session failed");
        }
        break;
      case commands::Input::DELETE_SESSION:
        if (auto it = sessions.find(session_id); it != sessions.end()) {
          command.mutable_input()->set_id(it->second);
          Eval(handler, command);
          sessions.erase(it);
        }
        command.clear_output();
        break;
      case commands::Input::SEND_KEY: {
        auto it = sessions.find(session_id);
        if (it == sessions.end()) {
          // Start a session for an id this helper does not know, as
          // ClientPool::GetClient does, instead of ending the helper and
          // every other session with it.
          const uint64_t id = CreateEngineSession(handler);
          if (id == 0) {
            ErrorExit(kErrSessionError, "Session failed");
          }
          it = sessions.emplace(session_id, id).first;
        }
        command.mutable_input()->set_id(it->second);
        if (!Eval(handler, command)) {
          ErrorExit(kErrSessionError, "Session failed");
        }
        if (command.output().error_code() ==
            commands::Output::SESSION_FAILURE) {
          // SessionHandler drops the least recently used session beyond 64,
          // and mozc.el leaks one whenever a buffer or a minibuffer goes away
          // with Mozc on.  Start over in a new session, as client::Client
          // does against mozc_server.
          const uint64_t id = CreateEngineSession(handler);
          if (id == 0) {
            ErrorExit(kErrSessionError, "Session failed");
          }
          it->second = id;
          command.mutable_input()->set_id(id);
          command.clear_output();
          if (!Eval(handler, command)) {
            ErrorExit(kErrSessionError, "Session failed");
          }
        }
        if (command.output().has_result()) {
          if (const absl::Time now = absl::Now();
              now - last_sync >= kSyncInterval) {
            StartSaving();
            last_sync = now;
          }
        }
        break;
      }
      default:
        ErrorExit(kErrVoidFunction, "Unknown function");
    }

    RemoveUsageData(command.mutable_output());

    std::vector<std::string> buffer;
    PrintMessage(command.output(), &buffer);
    const std::string output = absl::StrJoin(buffer, "");
    absl::FPrintF(
        stdout, "((emacs-event-id . %u)(emacs-session-id . %u)(output . %s))\n",
        event_id, session_id, output);
    fflush(stdout);
  }
}

}  // namespace
}  // namespace mozc::emacs

int main(int argc, char** argv) {
#ifdef _WIN32
  // The CRT decodes argv in the ANSI code page, while Mozc takes paths in
  // UTF-8.  Take the arguments from the wide command line instead, as
  // WinCommandLine in base/win32/winmain.h does (which needs WinMain).
  std::vector<std::string> args;
  if (int wargc = 0; wchar_t** wargv =
                         ::CommandLineToArgvW(::GetCommandLineW(), &wargc)) {
    for (int i = 0; i < wargc; ++i) {
      args.push_back(mozc::win32::WideToUtf8(wargv[i]));
    }
    ::LocalFree(wargv);
  }
  std::vector<char*> utf8_argv;
  for (std::string& arg : args) {
    utf8_argv.push_back(arg.data());
  }
  utf8_argv.push_back(nullptr);
  if (!args.empty()) {
    argc = static_cast<int>(args.size());
    argv = utf8_argv.data();
  }

  // Emacs talks UTF-8 over pipes; avoid CRLF translation.
  _setmode(_fileno(stdin), _O_BINARY);
  _setmode(_fileno(stdout), _O_BINARY);
  constexpr char kNullDevice[] = "NUL";
#else   // _WIN32
  constexpr char kNullDevice[] = "/dev/null";
#endif  // _WIN32

  // InitMozc resolves the profile directory (creating the default one) to
  // place its log file, so set the directory before it.  The flags are parsed
  // as InitMozc parses them, which it then does again.
  absl::flags_internal::ParseCommandLineImpl(
      argc, argv, absl::flags_internal::UsageFlagsAction::kIgnoreUsage,
      absl::flags_internal::OnUndefinedFlag::kIgnoreUndefined);
  if (const std::string dir = absl::GetFlag(FLAGS_profile_dir); !dir.empty()) {
    if (!mozc::emacs::IsAbsolutePath(dir)) {
      mozc::emacs::ErrorExit(
          mozc::emacs::kErrFileError,
          absl::StrCat("The profile directory must be an absolute path: ", dir));
    }
    mozc::FileUtil::CreateDirectory(dir).IgnoreError();
    if (!mozc::FileUtil::DirectoryExists(dir).ok()) {
      mozc::emacs::ErrorExit(
          mozc::emacs::kErrFileError,
          absl::StrCat("Cannot create the profile directory: ", dir));
    }
    mozc::SystemUtil::SetUserProfileDirectory(dir);
  }
  mozc::InitMozc(argv[0], &argc, &argv);
  if (absl::GetFlag(FLAGS_suppress_stderr)) {
    if (!freopen(kNullDevice, "a", stderr)) {
      mozc::emacs::ErrorExit(mozc::emacs::kErrFileError,
                             "freopen for stderr failed");
    }
  }

  std::unique_ptr<mozc::Engine> engine = mozc::EngineFactory::Create().value();
  {
    absl::MutexLock lock(mozc::emacs::g_mutex);
    mozc::emacs::g_engine = engine.get();
  }
  mozc::SessionHandler handler(std::move(engine));
  // ErrorExit() calls exit(), which does not destroy the handler.
  std::atexit(mozc::emacs::SaveAndWait);
#ifdef _WIN32
  ::SetConsoleCtrlHandler(mozc::emacs::OnConsoleCtrl, TRUE);
#endif  // _WIN32

  mozc::emacs::PrintGreetingMessage();
  mozc::emacs::ProcessLoop(handler);

  // Save before letting go of the engine: delete-process closes stdin and
  // then sends CTRL_CLOSE_EVENT, which must not end the process while the
  // handler is still saving as it is destroyed.
  mozc::emacs::SaveAndWait();
  absl::MutexLock lock(mozc::emacs::g_mutex);
  mozc::emacs::g_engine = nullptr;
  return 0;
}
