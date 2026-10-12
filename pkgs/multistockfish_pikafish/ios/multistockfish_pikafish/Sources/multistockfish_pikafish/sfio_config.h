/*
  The C++ namespace this package's engine is compiled into.

  sfio.h and sfio.cpp are byte-identical across every native package; this file
  is the only thing that differs between them. Each flavour therefore gets its
  own pair of streams, which is what lets two of them be resident in one process
  without sharing a channel.

  Note that this names the *engine's* namespace, which the vendoring step
  renamed from `Stockfish` to `Pikafish` -- not the shim's own namespace, which
  is `MultiStockfishPikafish` and lives in stockfish_pikafish.cpp.
*/

#ifndef SFIO_CONFIG_H_INCLUDED
#define SFIO_CONFIG_H_INCLUDED

#define SFIO_NAMESPACE Pikafish

#endif  // #ifndef SFIO_CONFIG_H_INCLUDED
