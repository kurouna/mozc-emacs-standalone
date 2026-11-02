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
#include <iostream>
#include <memory>
#include <string>
#include <vector>

#include "absl/container/flat_hash_map.h"
#include "absl/flags/flag.h"
#include "absl/strings/str_format.h"
#include "absl/strings/str_join.h"
#include "absl/strings/string_view.h"
#include "base/init_mozc.h"
#include "base/version.h"
#include "config/config_handler.h"
#include "engine/engine_factory.h"
#include "protocol/commands.pb.h"
#include "session/session_handler.h"
#include "unix/emacs/mozc_emacs_helper_lib.h"

#ifdef _WIN32
#include <fcntl.h>
#include <io.h>
#endif  // _WIN32

ABSL_FLAG(bool, suppress_stderr, false, "Discards all the output to stderr.");

namespace mozc::emacs {
namespace {

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

void ProcessLoop(SessionHandler& handler) {
  // The emacs protocol carries 32-bit session ids, while SessionHandler uses
  // 64-bit ones.  Map small sequential ids to the engine's ids.
  absl::flat_hash_map<uint32_t, uint64_t> sessions;
  uint32_t next_session_id = 1;
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
        if (!handler.EvalCommand(&command)) {
          ErrorExit(kErrSessionError, "Session failed");
        }
        session_id = next_session_id++;
        sessions[session_id] = command.output().id();
        {
          // Windows sessions start in DIRECT mode; mozc.el expects the
          // session to be active like on Linux, so turn it on.
          commands::Command on;
          on.mutable_input()->set_type(commands::Input::SEND_KEY);
          on.mutable_input()->set_id(command.output().id());
          on.mutable_input()->mutable_key()->set_special_key(
              commands::KeyEvent::ON);
          handler.EvalCommand(&on);
        }
        command.clear_output();
        break;
      case commands::Input::DELETE_SESSION:
        if (auto it = sessions.find(session_id); it != sessions.end()) {
          command.mutable_input()->set_id(it->second);
          handler.EvalCommand(&command);
          sessions.erase(it);
        }
        command.clear_output();
        break;
      case commands::Input::SEND_KEY:
        if (auto it = sessions.find(session_id); it != sessions.end()) {
          command.mutable_input()->set_id(it->second);
        } else {
          ErrorExit(kErrSessionError, "Unknown session");
        }
        if (!handler.EvalCommand(&command)) {
          ErrorExit(kErrSessionError, "Session failed");
        }
        break;
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
  mozc::InitMozc(argv[0], &argc, &argv);
#ifdef _WIN32
  // Emacs talks UTF-8 over pipes; avoid CRLF translation.
  _setmode(_fileno(stdin), _O_BINARY);
  _setmode(_fileno(stdout), _O_BINARY);
  constexpr char kNullDevice[] = "NUL";
#else   // _WIN32
  constexpr char kNullDevice[] = "/dev/null";
#endif  // _WIN32
  if (absl::GetFlag(FLAGS_suppress_stderr)) {
    if (!freopen(kNullDevice, "a", stderr)) {
      mozc::emacs::ErrorExit(mozc::emacs::kErrFileError,
                             "freopen for stderr failed");
    }
  }

  mozc::SessionHandler handler(mozc::EngineFactory::Create().value());
  mozc::emacs::PrintGreetingMessage();
  mozc::emacs::ProcessLoop(handler);
  return 0;
}
