#!/usr/bin/env python3
"""Vendor a Pikafish source snapshot into this package, renamed and wired for the shim.

    tool/vendor_pikafish.py <extracted-tarball-root> [<engine-dir>]

`<extracted-tarball-root>` is the directory GitHub produces from
`https://github.com/official-pikafish/Pikafish/tarball/<tag>` once untarred, i.e.
a `Pikafish-Pikafish-<tag>/` holding `src/`. The destination defaults to
`ios/multistockfish_pikafish/Sources/multistockfish_pikafish/Pikafish-<sha>/`,
named after the commit rather than the tag, as `Fairy-Stockfish-2b5d9512` is in
multistockfish_variant.

Two things are done to upstream's sources, and nothing else:

1.  **The namespace is renamed.** Every flavour of this plugin is a separate
    library, and on iOS Swift Package Manager links them statically into one
    binary, so two flavours left in namespace `Stockfish` would be one set of
    symbols and an ODR violation. Pikafish's own sources say `Stockfish`; the
    other three packages carry a snapshot that was renamed the same way
    (`StockfishLight`, `FairyStockfish`). Only the two forms that are actually
    identifiers are touched -- `Stockfish::` and `namespace Stockfish` -- so the
    GPL notices, the comments and the `"the Pikafish developers"` string are
    left exactly as upstream wrote them.

2.  **Standard I/O is redirected onto the plugin's own streams.** The engine
    reads `std::cin` and writes `std::cout` in seven places; each is pointed at
    the `sfio::in()`/`sfio::out()` the shim binds to its pipe, and `misc.h`
    declares those two. This is the same edit multistockfish_variant carries,
    and the reason for it is the same: the process's descriptors are shared with
    the host application and with every other flavour.

Both edits are asserted before and after, so a Pikafish bump that moves one of
these lines fails here rather than at link time.
"""

import argparse
import re
import shutil
import sys
from pathlib import Path

# --------------------------------------------------------------------------
# 1. the namespace rename
# --------------------------------------------------------------------------

# Only these two. `Stockfish::` covers every qualified use (`std::hash<Stockfish::Ev>`,
# `Stockfish::UCIEngine`, ...); `namespace Stockfish` covers `namespace Stockfish {`
# and `namespace Stockfish::Ev` alike. Neither can occur in prose: the snapshot's
# only non-code mentions are `Stockfish is free software`, `Copyright (C)
# ... The Stockfish developers`, `the Pikafish developers`, a `// Since Stockfish
# does ...` comment and one github.com URL -- none of which contains `::` or the
# word `namespace`.
RENAME = [("Stockfish::", "Pikafish::"), ("namespace Stockfish", "namespace Pikafish")]

NEW_NAMESPACE = "Pikafish"

# --------------------------------------------------------------------------
# 2. the stdio redirect
# --------------------------------------------------------------------------

# path -> list of (exact old text, exact new text). Each old text must occur
# exactly once, so a drift in upstream is an error and not a silent half-patch.
PATCHES = {
    "src/misc.h": [
        (
            "std::ostream& operator<<(std::ostream&, SyncCout);\n"
            "\n"
            "#define sync_cout std::cout << IO_LOCK\n",
            "std::ostream& operator<<(std::ostream&, SyncCout);\n"
            "\n"
            "// multistockfish: this library's private I/O, defined in the plugin's\n"
            "// sfio.cpp alongside the shim. It replaces std::cin and std::cout so that\n"
            "// more than one flavour of the engine can be resident in a process without\n"
            "// sharing the standard descriptors, and so that the host application keeps\n"
            "// its own stdout. Declared here rather than included, so that the vendored\n"
            "// sources never reach into the plugin directory.\n"
            "namespace sfio {\n"
            "std::istream& in();\n"
            "std::ostream& out();\n"
            "}\n"
            "\n"
            "#define sync_cout sfio::out() << IO_LOCK\n",
        ),
    ],
    "src/misc.cpp": [
        (
            "    Logger() :\n"
            "        in(std::cin.rdbuf(), file.rdbuf()),\n"
            "        out(std::cout.rdbuf(), file.rdbuf()) {}\n",
            "    Logger() :\n"
            "        in(sfio::in().rdbuf(), file.rdbuf()),\n"
            "        out(sfio::out().rdbuf(), file.rdbuf()) {}\n",
        ),
        (
            "            std::cout.rdbuf(l.out.buf);\n"
            "            std::cin.rdbuf(l.in.buf);\n",
            "            sfio::out().rdbuf(l.out.buf);\n"
            "            sfio::in().rdbuf(l.in.buf);\n",
        ),
        (
            "            std::cin.rdbuf(&l.in);\n"
            "            std::cout.rdbuf(&l.out);\n",
            "            sfio::in().rdbuf(&l.in);\n"
            "            sfio::out().rdbuf(&l.out);\n",
        ),
        (
            "void sync_cout_start() { std::cout << IO_LOCK; }\n"
            "void sync_cout_end() { std::cout << IO_UNLOCK; }\n",
            "void sync_cout_start() { sfio::out() << IO_LOCK; }\n"
            "void sync_cout_end() { sfio::out() << IO_UNLOCK; }\n",
        ),
    ],
    "src/uci.cpp": [
        (
            '            std::cout << "info string " << line << \'\\n\';\n',
            '            sfio::out() << "info string " << line << \'\\n\';\n',
        ),
        (
            # A prefix of the line rather than the whole of it: it ends in a
            # `// Wait for an input or an end-of-file (EOF) indication` comment,
            # and a reworded comment is not a reason to fail the vendor step.
            "            && !getline(std::cin, cmd))",
            "            && !getline(sfio::in(), cmd))",
        ),
        (
            '        std::cout << " ponder " << ponder;\n'
            "    std::cout << sync_endl;\n",
            '        sfio::out() << " ponder " << ponder;\n'
            "    sfio::out() << sync_endl;\n",
        ),
    ],
}

# Kept from the snapshot's root. The rest (`.github`, `CONTRIBUTING.md`,
# `scripts/`, `tests/`) is dropped: `scripts/` is universal-binary tooling for
# architectures this plugin does not build, and `tests/perft.sh` is 8x8 chess
# positions inherited from Stockfish that no xiangqi engine can pass. Dropping
# them here means one less exclusion per build file, and the package README says
# so.
KEEP = ["AUTHORS", "CITATION.cff", "Copying.txt", "README.md", "Top CPU Contributors.txt"]

# --------------------------------------------------------------------------
# 3. the assertions
# --------------------------------------------------------------------------

# Whether the rename got everything is a lexical question, not a prose one: an
# occurrence of `Stockfish` is either code, which must have been renamed, or it
# is inside a comment, where it is the GPL notice upstream wrote and should stay
# exactly as it is. So the comments are removed and what is left is asked for
# `Stockfish`. This is why there is no list of "allowed" prose lines to keep in
# step with upstream: the rule is the rule, and a bump cannot quietly widen it.
BLOCK_COMMENT = re.compile(r"/\*.*?\*/", re.S)
LINE_COMMENT = re.compile(r"//[^\n]*")


def without_comments(text: str) -> str:
    """`text` with every comment replaced by nothing but its newlines.

    The newlines are kept so a line number reported against this still points at
    the line a text editor would. Deliberately crude -- a `//` inside a string
    literal is treated as a comment -- because every way it can be wrong can
    only make the check report a line that is in fact fine, never fail to report
    one that is not.
    """

    def blank(match: re.Match[str]) -> str:
        return "\n" * match.group(0).count("\n")

    return LINE_COMMENT.sub("", BLOCK_COMMENT.sub(blank, text))


def rename(text: str) -> str:
    for old, new in RENAME:
        text = text.replace(old, new)
    return text


def vendor(source_root: Path, dest: Path) -> list[str]:
    src = source_root / "src"
    if not src.is_dir():
        raise SystemExit(f"error: {source_root} has no src/ — is this an untarred Pikafish tarball?")

    if dest.exists():
        shutil.rmtree(dest)
    (dest / "src").mkdir(parents=True)

    for name in KEEP:
        shutil.copy2(source_root / name, dest / name)

    # src/universal/ is upstream's macOS universal-binary build: its entry_* files
    # call into per-arch `Stockfish_<arch>::main` namespaces that only exist there,
    # and nnue_embed.cpp defines a second `gEmbeddedNNUEData`. No normal build
    # compiles it -- every package here filters it out -- so it is not vendored.
    copied = 0
    for item in sorted(src.iterdir()):
        if item.name == "universal":
            continue
        target = dest / "src" / item.name
        if item.is_dir():
            shutil.copytree(item, target)
        else:
            shutil.copy2(item, target)
        copied += 1

    report = [f"vendored {copied} entries from {src} plus {len(KEEP)} root files"]

    # --- the rename -------------------------------------------------------
    touched = 0
    for path in sorted((dest / "src").rglob("*")):
        if path.suffix not in (".cpp", ".h"):
            continue
        text = path.read_text(encoding="utf-8")
        renamed = rename(text)
        if renamed != text:
            path.write_text(renamed, encoding="utf-8")
            touched += 1
    report.append(f"renamed the namespace to {NEW_NAMESPACE} in {touched} files")

    # --- the stdio redirect -----------------------------------------------
    for relative, edits in PATCHES.items():
        path = dest / relative
        text = path.read_text(encoding="utf-8")
        for old, new in edits:
            found = text.count(old)
            if found != 1:
                raise SystemExit(
                    f"error: {relative}: expected exactly one occurrence of\n---\n{old}---\n"
                    f"but found {found}. Upstream has moved this; update PATCHES."
                )
            text = text.replace(old, new)
        path.write_text(text, encoding="utf-8")
        report.append(f"patched {relative} ({len(edits)} edit(s))")

    # --- assertions -------------------------------------------------------
    problems = []
    prose: set[str] = set()
    for path in sorted((dest / "src").rglob("*")):
        if path.suffix not in (".cpp", ".h"):
            continue
        text = path.read_text(encoding="utf-8")
        for number, line in enumerate(without_comments(text).splitlines(), 1):
            if re.search(r"\bStockfish\b", line):
                problems.append(f"  {path.relative_to(dest)}:{number}: {line.strip()}")
        # The lowercase `stockfish` in the github.com URL is not an occurrence of
        # the namespace, so it is not what this is counting.
        prose.update(
            line.strip() for line in text.splitlines() if re.search(r"\bStockfish\b", line)
        )
    if problems:
        raise SystemExit(
            "error: `Stockfish` survives the rename outside a comment, i.e. in code.\n"
            "Each of these needs a RENAME rule:\n" + "\n".join(sorted(set(problems)))
        )
    report.append(
        f"asserted: no `Stockfish` in code; {len(prose)} distinct comment/notice lines"
        " still name it, which is upstream's text and is left alone"
    )
    report.extend(f"        {line}" for line in sorted(prose))

    # std::cerr is deliberately left alone: it is upstream's diagnostics, not
    # engine output, and nothing reads it. Anything else still naming std::cin or
    # std::cout would be a site this script missed -- a lone `std::cout` there
    # means the engine writes to the host process's stdout. Comments are
    # stripped first, because the files legitimately still discuss the streams
    # they no longer use.
    for relative in PATCHES:
        body = without_comments((dest / relative).read_text(encoding="utf-8"))
        leftovers = [
            line.strip()
            for line in body.splitlines()
            if "std::cin" in line or "std::cout" in line
        ]
        if leftovers:
            report.append(f"note: {relative} still names the standard streams in code:")
            report.extend(f"        {line}" for line in leftovers)

    return report


def main() -> int:
    here = Path(__file__).resolve().parent.parent
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("source_root", type=Path, help="untarred Pikafish-<tag>/ directory")
    parser.add_argument(
        "engine_dir",
        type=Path,
        nargs="?",
        default=here / "ios/multistockfish_pikafish/Sources/multistockfish_pikafish/Pikafish-532c3ff216",
    )
    args = parser.parse_args()

    if not args.source_root.is_dir():
        parser.error(f"{args.source_root} is not a directory")

    for line in vendor(args.source_root.resolve(), args.engine_dir.resolve()):
        print(line)

    print(f"\nengine in {args.engine_dir}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
