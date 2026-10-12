#
# To learn more about a Podspec see http://guides.cocoapods.org/syntax/podspec.html.
# Run `pod lib lint multistockfish_pikafish.podspec` to validate before publishing.
#
require 'yaml'

pubspec = YAML.load(File.read(File.join(__dir__, '../pubspec.yaml')))

Pod::Spec.new do |s|
  s.name             = 'multistockfish_pikafish'
  s.version          = pubspec['version']
  s.summary          = pubspec['description']
  s.homepage         = pubspec['homepage']
  s.license          = { :file => '../LICENSE', :type => 'GPL' }
  s.author           = { 'lichess.org' => 'contact@lichess.org' }
  s.source = { :git => pubspec['repository'], :tag => s.version.to_s }
  s.source_files = [
    'multistockfish_pikafish/Sources/multistockfish_pikafish/*.{c,cc,cpp,h,hpp}',
    'multistockfish_pikafish/Sources/multistockfish_pikafish/include/**/*.h',
    'multistockfish_pikafish/Sources/multistockfish_pikafish/Pikafish-532c3ff216/src/**/*',
  ]
  s.public_header_files = 'multistockfish_pikafish/Sources/multistockfish_pikafish/include/**/*.h'
  s.exclude_files = [
    'multistockfish_pikafish/Sources/multistockfish_pikafish/Pikafish-532c3ff216/src/Makefile',
    # Defines the process's `main`, which the plugin and the app it is linked
    # into already have one of.
    'multistockfish_pikafish/Sources/multistockfish_pikafish/Pikafish-532c3ff216/src/main.cpp',
    # zstd's x86_64-only assembly decompressor, whose symbol is switched off
    # everywhere by -DZSTD_DISABLE_ASM (see the xcconfig note below). Excluding it
    # documents that, and keeps the pod from compiling an assembly file for a
    # symbol nothing references.
    'multistockfish_pikafish/Sources/multistockfish_pikafish/Pikafish-532c3ff216/src/external/decompress/huf_decompress_amd64.S',
  ]
  s.dependency 'Flutter'
  s.platform = :ios, '12.0'
  s.swift_version = '5.0'

  # These are Pikafish's flags and not the other flavours'. Two of the ones the
  # Stockfish podspecs carry are missing on purpose: `NNUE_EMBEDDING_OFF` and
  # `USE_PTHREADS` name features Pikafish does not have -- it never embeds a net
  # (the app injects one with `setoption name EvalFile`), and its Makefile has
  # no NNUE_EMBEDDING or USE_PTHREADS switch at all, so defining either would be
  # a flag that means nothing to this code. `USE_NEON=8` does need its value:
  # Pikafish's nnue/simd.h tests `USE_NEON >= 8` to decide whether NEON is
  # usable, so a bare `-DUSE_NEON` compiles and silently selects the portable
  # path. Upstream's Makefile passes `-DUSE_NEON=$(arm_version)` for exactly
  # this reason.
  #
  # -fconstexpr-steps is not an optimisation -- the build does not finish without
  # it. Pikafish builds its NNUE feature-set lookup tables in constexpr lambdas,
  # and clang's default constexpr step budget (1,048,576) is not enough for the
  # 90x90x2 table in nnue/features/half_ka_v2_hm.h: clang reports "constexpr
  # evaluation hit maximum step limit" and fails the file. It is a ceiling rather
  # than a cost, so it is set well clear of the ~2M steps this tree needs instead
  # of just above it.
  #
  # ZSTD_DISABLE_ASM switches off zstd's BMI2 decompression loops, which live in
  # an .S file upstream's Makefile assembles and no build system here compiles.
  # On x86-64 ELF, huf_decompress.cpp references those loops and would not link
  # without them; here the network file is decompressed by zstd's C loop instead
  # -- what this arm64 target would use anyway -- once, when the net is loaded.
  s.pod_target_xcconfig = {
     # Flutter.framework does not contain a i386 slice.
    'DEFINES_MODULE' => 'YES', 'EXCLUDED_ARCHS[sdk=iphonesimulator*]' => 'i386',
    'CLANG_CXX_LANGUAGE_STANDARD' => 'c++17',
    'CLANG_CXX_LIBRARY' => 'libc++',
    'OTHER_CPLUSPLUSFLAGS' => '-std=c++17 -mdynamic-no-pic -DIS_64BIT -DUSE_POPCNT -fconstexpr-steps=10000000 -DZSTD_DISABLE_ASM',
    'OTHER_LDFLAGS' => '-std=c++17 -mdynamic-no-pic -DIS_64BIT -DUSE_POPCNT -fconstexpr-steps=10000000 -DZSTD_DISABLE_ASM',
    'OTHER_CPLUSPLUSFLAGS[config=Profile]' => '$(inherited) -fno-exceptions -DNDEBUG -funroll-loops -O3 -DUSE_NEON=8 -flto=full',
    'OTHER_LDFLAGS[config=Profile]' => '$(inherited) -fno-exceptions -DNDEBUG -funroll-loops -O3 -DUSE_NEON=8 -flto=full',
    'OTHER_CPLUSPLUSFLAGS[config=Release]' => '$(inherited) -fno-exceptions -DNDEBUG -funroll-loops -O3 -DUSE_NEON=8 -flto=full',
    'OTHER_LDFLAGS[config=Release]' => '$(inherited) -fno-exceptions -DNDEBUG -funroll-loops -O3 -DUSE_NEON=8 -flto=full',
  }
end
