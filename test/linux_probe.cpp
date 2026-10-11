// Drives one flavour's shared library over UCI, on Linux.
//
// This is the counterpart of pkgs/multistockfish_variant/test/shim_test.cpp for
// the shipped .so files rather than for sources compiled into the test: that
// one tests the shim's own guarantees in depth (private I/O, restart, a full
// pipe), this one is a thin probe whose job is to prove each of the three
// libraries links, loads and computes. Compile it once per flavour, with that
// flavour's symbol prefix in -DPROBE_SYMBOLS, and link its .so.
//
// It asks for `go perft 3` rather than a search: perft needs no evaluation and
// no net to produce a number, and the node count it prints is one anyone can
// check by hand. That is true of the engine as a whole but not of any single
// build: Stockfish still verifies its net before walking the tree, so a flavour
// built without one stops there. Hence the optional second argument -- pass a
// .nnue to load and it is set as EvalFile first. light carries its own net
// inside itself and variant has no net at all, so neither needs one.
//
// chess (the latestNoNNUE build) cannot be taken past the handshake on Linux at
// all, and a depth of 0 says so: Stockfish loads a net from a file through
// shm.h's system-wide shared allocation, and on Linux -- the one platform where
// that path is both compiled in and able to run, see the note in
// test/run_linux_test.sh -- it deadlocks. At depth 0 the probe stops after the
// handshake, so what it proves is that the library loads, exports the symbols
// the Dart side looks up and speaks UCI.
//
// Diagnostics go to stderr; stdout is left alone, so a caller can assert on it
// being empty the way pkgs/multistockfish_variant/test/run_shim_test.sh does.
//
// Usage: probe [perft-depth] [eval-file]

#include <chrono>
#include <condition_variable>
#include <cstdio>
#include <cstdlib>
#include <fstream>
#include <mutex>
#include <string>
#include <sys/types.h>
#include <thread>

// The symbol prefix is taken as an argument rather than derived from a flavour
// name, because the three packages do not follow one pattern: light and variant
// export `stockfish_light_*` and `stockfish_variant_*`, while chess exports
// plain `stockfish_*` with no infix at all. (Same asymmetry as
// pkgs/multistockfish/lib/src/bindings.dart, whose symbolPrefix is null for
// chess and set for the other two -- this is the boundary between the plugin
// and the engine, and the plugin's names are the real ones.)
#ifndef PROBE_SYMBOLS
#error "compile with -DPROBE_SYMBOLS=stockfish|stockfish_light|stockfish_variant"
#endif

#define PROBE_JOIN_(a, b) a##b
#define PROBE_JOIN(a, b) PROBE_JOIN_(a, b)
#define SF(fn) PROBE_JOIN(PROBE_SYMBOLS, PROBE_JOIN(_, fn))

#define PROBE_STRINGIZE_(x) #x
#define PROBE_STRINGIZE(x) PROBE_STRINGIZE_(x)
#define PROBE_FLAVOUR_NAME PROBE_STRINGIZE(PROBE_SYMBOLS)

extern "C" {
int SF(init)();
int SF(main)();
ssize_t SF(stdin_write)(char *data);
char *SF(stdout_read)();
}

static int g_failures = 0;

static void check(bool ok, const char *what)
{
  fprintf(stderr, "%s %s\n", ok ? "  ok  " : "  FAIL", what);
  if (!ok)
    g_failures++;
}

static std::mutex g_mutex;
static std::condition_variable g_cv;
static std::string g_output;

static void reader_thread()
{
  while (true)
  {
    char *line = SF(stdout_read)();
    if (line == nullptr)
      return;
    {
      std::lock_guard<std::mutex> lock(g_mutex);
      g_output += line;
    }
    g_cv.notify_all();
  }
}

static bool wait_for(const char *needle, int timeout_ms = 30000)
{
  std::unique_lock<std::mutex> lock(g_mutex);
  return g_cv.wait_for(lock, std::chrono::milliseconds(timeout_ms), [&] {
    return g_output.find(needle) != std::string::npos;
  });
}

static ssize_t send(const char *command)
{
  // Mirrors how Dart calls it: a mutable buffer the shim may consume. Sized for
  // a whole UCI command line, which is routinely hundreds of bytes long once a
  // position or an EvalFile path is in it.
  char buf[8192];
  snprintf(buf, sizeof(buf), "%s", command);
  return SF(stdin_write)(buf);
}

int main(int argc, char **argv)
{
  // The depth is overridable so that a caller wanting the node count for a
  // deeper perft (the xiangqi rules work does) can ask for one; 3 keeps the
  // default run to a second or two.
  const int perft_depth = argc > 1 ? atoi(argv[1]) : 3;

  // Failing here rather than after the wait below: an engine that cannot find
  // its net says nothing at all on stdout, so a path we got wrong would be
  // indistinguishable from a hang.
  if (argc > 2 && !std::ifstream(argv[2]).good())
  {
    fprintf(stderr, "FAIL: the eval file %s is not readable\n", argv[2]);
    return 1;
  }

  fprintf(stderr, "\n== %s ==\n", PROBE_FLAVOUR_NAME);
  check(SF(init)() == 0, "init succeeds");

  std::thread reader(reader_thread);
  std::thread engine([] { SF(main)(); });

  check(send("uci\n") > 0, "uci accepted");
  check(wait_for("uciok"), "engine answers uciok");

  if (argc > 2)
  {
    char command[8192];
    snprintf(command, sizeof(command), "setoption name EvalFile value %s\n", argv[2]);
    check(send(command) > 0, "setoption EvalFile accepted");
  }

  // setoption has no acknowledgement of its own, so isready doubles as the sync
  // point: by the time readyok arrives the option has been applied, and one the
  // engine did not recognise would have been rejected in the output we hold.
  check(send("isready\n") > 0, "isready accepted");
  check(wait_for("readyok"), "engine answers readyok");
  {
    std::lock_guard<std::mutex> lock(g_mutex);
    check(g_output.find("No such option") == std::string::npos,
          "the engine understands every option it was sent");
  }

  if (perft_depth > 0)
  {
    char command[64];
    snprintf(command, sizeof(command), "go perft %d\n", perft_depth);
    check(send(command) > 0, "perft accepted");
    check(wait_for("Nodes searched"), "engine finishes the perft");
  }
  else
  {
    fprintf(stderr, "  --   no perft asked for (depth 0), so nothing that needs a net\n");
  }

  // Whatever it printed is worth having in the log: this is where a rules
  // implementation gets its reference node counts from.
  {
    std::lock_guard<std::mutex> lock(g_mutex);
    fprintf(stderr, "%s", g_output.c_str());
  }

  check(send("quit\n") > 0, "quit accepted");
  engine.join();
  reader.join();

  fprintf(stderr, "%s: %d failure(s)\n", g_failures == 0 ? "PASS" : "FAIL", g_failures);
  return g_failures == 0 ? 0 : 1;
}
