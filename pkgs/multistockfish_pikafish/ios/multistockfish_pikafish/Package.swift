// swift-tools-version: 5.9
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

// Mirrors the CocoaPods podspec's `pod_target_xcconfig`, which applies the same
// flags to OTHER_CPLUSPLUSFLAGS and OTHER_LDFLAGS.
//
// These are Pikafish's flags and not the other flavours'. `-DNNUE_EMBEDDING_OFF`
// and `-DUSE_PTHREADS` are absent because Pikafish has neither feature: it
// never embeds a net, and its Makefile has no such switches. `-DUSE_NEON=8`
// needs its value: Pikafish's nnue/simd.h tests `USE_NEON >= 8` to decide
// whether NEON is usable, so a bare `-DUSE_NEON` compiles and silently selects
// the portable path.
let baseFlags = [
    "-mdynamic-no-pic",
    "-DIS_64BIT",
    "-DUSE_POPCNT",
    // Not an optimisation -- the build does not finish without it. Pikafish
    // builds its NNUE feature-set lookup tables in constexpr lambdas, and
    // clang's default constexpr step budget (1,048,576) is not enough for the
    // 90x90x2 table in nnue/features/half_ka_v2_hm.h: clang reports "constexpr
    // evaluation hit maximum step limit" and fails the file. Xcode always
    // compiles with clang, so the flag is unconditional here. It is a ceiling
    // rather than a cost, so it is set well clear of the ~2M steps this tree
    // needs instead of just above it.
    "-fconstexpr-steps=10000000",
    // zstd's BMI2 decompression loops live in an .S file that upstream's
    // Makefile assembles and none of the build systems here compile: on x86-64
    // ELF, huf_decompress.cpp references those loops and would not link without
    // them. ZSTD_DISABLE_ASM switches the reference off, so the network file is
    // decompressed by zstd's C loop -- which is what this arm64 target would use
    // anyway -- once, when the net is loaded. See the CMake files for the longer
    // version of this note.
    "-DZSTD_DISABLE_ASM",
]
// Additional flags the podspec applies only to the Profile and Release
// xcconfigs (SPM only distinguishes debug/release; Xcode treats a
// Flutter "Profile" configuration as non-debug, so `.release` covers both).
let releaseFlags = [
    "-fno-exceptions",
    "-DNDEBUG",
    "-funroll-loops",
    "-O3",
    "-DUSE_NEON=8",
    "-flto=full",
]

let package = Package(
    name: "multistockfish_pikafish",
    platforms: [
        .iOS("13.0"),
    ],
    products: [
        .library(name: "multistockfish-pikafish", targets: ["multistockfish_pikafish"])
    ],
    dependencies: [
        .package(name: "FlutterFramework", path: "../FlutterFramework")
    ],
    targets: [
        .target(
            name: "multistockfish_pikafish",
            dependencies: [
                .product(name: "FlutterFramework", package: "FlutterFramework")
            ],
            exclude: [
                "Pikafish-532c3ff216/src/Makefile",
                // Defines the process's `main`, which the plugin and the app it
                // is linked into already have one of.
                "Pikafish-532c3ff216/src/main.cpp",
                // zstd's x86_64-only assembly decompressor, whose symbol is
                // switched off everywhere by -DZSTD_DISABLE_ASM (see baseFlags
                // above). Excluding it documents that and keeps SwiftPM from
                // having to decide what to do with an assembly file.
                "Pikafish-532c3ff216/src/external/decompress/huf_decompress_amd64.S",
                // The snapshot's root files, which the vendoring script keeps
                // for the licence trail. None of them is source.
                "Pikafish-532c3ff216/AUTHORS",
                "Pikafish-532c3ff216/CITATION.cff",
                "Pikafish-532c3ff216/Copying.txt",
                "Pikafish-532c3ff216/README.md",
                "Pikafish-532c3ff216/Top CPU Contributors.txt",
                // Dot-files (.gitignore, .clang-format, .git-blame-ignore-revs) are deliberately
                // NOT listed here: SwiftPM already skips hidden files when collecting target
                // contents, and `dart pub publish` strips them from the published archive - so
                // excluding them only makes Xcode warn "Invalid Exclude ...: File not found" for
                // every consumer that resolves this package from pub.dev.
            ],
            cSettings: [
                .headerSearchPath("include/multistockfish_pikafish"),
                .headerSearchPath("Pikafish-532c3ff216/src"),
                .unsafeFlags(baseFlags),
                .unsafeFlags(releaseFlags, .when(configuration: .release)),
            ],
            cxxSettings: [
                .headerSearchPath("include/multistockfish_pikafish"),
                .headerSearchPath("Pikafish-532c3ff216/src"),
                .unsafeFlags(baseFlags),
                .unsafeFlags(releaseFlags, .when(configuration: .release)),
            ],
            linkerSettings: [
                .unsafeFlags(baseFlags),
                .unsafeFlags(releaseFlags, .when(configuration: .release)),
            ]
        )
    ],
    cxxLanguageStandard: .cxx17
)

// Notes on settings intentionally NOT ported from the podspec's
// pod_target_xcconfig, since Package.swift has no equivalent knob:
// - DEFINES_MODULE = YES: SPM targets are always modules; no-op here.
// - EXCLUDED_ARCHS[sdk=iphonesimulator*] = i386: i386 simulator slices
//   aren't produced by modern Xcode toolchains for an iOS 13+ minimum
//   deployment target, so this exclusion is a no-op on current Xcode too.
