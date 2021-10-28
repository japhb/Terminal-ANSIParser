unit module Terminal::ANSIParser:auth<zef:japhb>:ver<0.0.1>;


=begin pod

=head1 NAME

Terminal::ANSIParser - ANSI/VT stream parser


=head1 SYNOPSIS

=begin code :lang<raku>

use Terminal::ANSIParser;

my @parsed;
my &parse-byte := make-ansi-parser(emit-item => { @parsed.push: $_ });
parse-byte($_) for $input-buffer;

=end code


=head1 DESCRIPTION

C<Terminal::ANSIParser> is a general parser for ANSI/VT escape codes, as
defined by the related specs ANSI X3.64, ECMA-48, ISO/IEC 6429, and of course
the actual physical DEC VT terminals generally considered the standard for
escape code behavior.

The basic C<make-ansi-parser()> routine builds and returns a byte-by-byte
table-based binary parsing state machine, based on (and extended from) the
error-recovering state machine built from observed DEC VT behavior described at
L<https://vt100.net/emu/dec_ansi_parser>.

Each time the parser determines that it has parsed enough bytes, it emits a
token representing the parsed data, which can take one of the following forms:

=item A plain byte, for passed through data when no escape sequence is active

=item A C<Terminal::ANSIParser::Sequence> object, if an escape sequence is parsed

=item A C<Terminal::ANSIParser::String> object, if a control string is parsed

A few C<Sequence> subclasses exist for separate cases:

=item C<Ignored>: invalid sequences that the parser decides should be ignored

=item C<Incomplete>: sequences that were cut off by the start of another sequence

=item C<SimpleEscape>: simple escape sequences such as function key codes

=item C<CSI>: parameterized sequences beginning with C<CSI> (C<ESC [>)

Likewise, C<String> has its own subclasses:

=item C<DCS>: Device Control Strings

=item C<OSC>: Operating System Commands

=item C<SOS>: Strings beginning with a general Start Of String indicator

=item C<PM>: Privacy Message (NOTE: NOT A SECURE FUNCTION)

=item C<APC>: Application Program Command


=head1 AUTHOR

Geoffrey Broadwell <gjb@sonic.net>


=head1 COPYRIGHT AND LICENSE

Copyright 2021 Geoffrey Broadwell

This library is free software; you can redistribute it and/or modify it under
the Artistic License 2.0.

=end pod
