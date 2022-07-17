[![Actions Status](https://github.com/japhb/Terminal-ANSIParser/workflows/test/badge.svg)](https://github.com/japhb/Terminal-ANSIParser/actions)

NAME
====

Terminal::ANSIParser - ANSI/VT stream parser

SYNOPSIS
========

```raku
use Terminal::ANSIParser;

my @parsed;

# Default: Assume UTF-8 decoded inputs, thus working with codepoints
my &parse-codepoint := make-ansi-parser(emit-item => { @parsed.push: $_ });
parse-codepoint($_) for $input-buffer.list;

# Raw bytes: Assume raw byte stream input, for pre-Unicode terminal emulation
my &parse-byte := make-ansi-parser(emit-item => { @parsed.push: $_ },
                                   :raw-bytes);
parse-byte($_) for $input-buffer.list;
```

DESCRIPTION
===========

`Terminal::ANSIParser` is a general parser for ANSI/VT escape codes, as defined by the related specs ANSI X3.64, ECMA-48, ISO/IEC 6429, and of course the actual physical DEC VT terminals generally considered the standard for escape code behavior.

The basic `make-ansi-parser()` routine builds and returns a codepoint-by-codepoint (or byte-by-byte, if the `:raw-bytes` option is True) table-based binary parsing state machine, based on (and extended from) the error-recovering state machine built from observed DEC VT behavior described at [https://vt100.net/emu/dec_ansi_parser](https://vt100.net/emu/dec_ansi_parser).

Each time the parser determines that it has parsed enough input, it emits a token representing the parsed data, which can take one of the following forms:

  * A plain codepoint (or byte if `:raw-bytes` is True), for passed through data when no escape sequence is active

  * A `Terminal::ANSIParser::Sequence` object, if an escape sequence is parsed

  * A `Terminal::ANSIParser::String` object, if a control string is parsed

A few `Sequence` subclasses exist for separate cases:

  * `Ignored`: invalid sequences that the parser decides should be ignored

  * `Incomplete`: sequences that were cut off by the start of another sequence or the end of the input data (see [End of Input](End of Input) below)

  * `SimpleEscape`: simple escape sequences such as function key codes

  * `CSI`: parameterized sequences beginning with `CSI` (`ESC [`)

Likewise, `String` has its own subclasses:

  * `DCS`: Device Control Strings

  * `OSC`: Operating System Commands

  * `SOS`: Strings beginning with a general Start Of String indicator

  * `PM`: Privacy Message (NOTE: NOT A SECURE FUNCTION)

  * `APC`: Application Program Command

End of Input
------------

End of input can be signaled by parsing an undefined "codepoint"/"byte"; any partial sequence in progress will be flushed as `Incomplete`, and the undefined marker will be emitted as well, so that downstream consumers are also notified that input is complete.

AUTHOR
======

Geoffrey Broadwell <gjb@sonic.net>

COPYRIGHT AND LICENSE
=====================

Copyright 2021-2022 Geoffrey Broadwell

This library is free software; you can redistribute it and/or modify it under the Artistic License 2.0.

