# ABSTRACT: ANSI X3.64/ECMA-48/ISO/IEC 6429/DEC-VT stream parser

unit module Terminal::ANSIParser:auth<zef:japhb>:ver<0.0.4>;


enum DecodeState < Ground Escape Escape_Intermediate
                   CSI_Entry CSI_Param CSI_Intermediate CSI_Ignore
                   DCS_Entry DCS_Param DCS_Intermediate DCS_Passthrough DCS_Ignore
                   OSC_String SOS_String PM_String APC_String >;

class Sequence {
    has $.sequence is required;

    # Handle both buf8 (raw bytes) and buf32 (codepoints)
    method Str { $!sequence ~~ buf8 ?? $!sequence.decode
                                    !! $!sequence.map({ chr($_) }).join }
}

class String is Sequence {
    has $.string is required;

    # Handle both buf8 (raw bytes) and buf32 (codepoints)
    method Str { $!string ~~ buf8 ?? $!string.decode
                                  !! $!string.map({ chr($_) }).join }
}

class Ignored      is Sequence { }
class Incomplete   is Sequence { }
class SimpleEscape is Sequence { }
class CSI          is Sequence { }
class DCS          is String   { }
class OSC          is String   { }
class SOS          is String   { }
class PM           is String   { }
class APC          is String   { }


# Builds an ANSI parser state machine and returns it
sub make-ansi-parser(:&emit-item!,
                     Bool:D :$dec-pedantic = False,
                     Bool:D :$raw-bytes    = $dec-pedantic) is export {
    my $state        = Ground;
    my $string-type  = String;
    my $seq-buf-type = $raw-bytes ?? buf8 !! buf32;
    my $str-buf-type = $seq-buf-type;
    my Buf $sequence = $seq-buf-type.new;
    my Buf $string;

    my @actions;
    my @default;


    # Action helpers

    # Ignore a byte, by emitting it by itself as an Ignored Sequence
    my sub ignore-byte($byte) {
        emit-item(Ignored.new(:sequence($seq-buf-type.new($byte))))
    }

    # Send an entire sequence (including current byte) as ignored, reset
    # sequence state, and return to Ground state
    my sub ignore-sequence($byte) {
        $sequence.push($byte);
        emit-item(Ignored.new(:$sequence));
        $sequence = $seq-buf-type.new;
        $state = Ground;
    }

    # Flush previous sequence if any by emitting it as Incomplete, then start a
    # new sequence with given byte (or signal end of input by emitting an
    # undefined "byte") and enter new-state
    my sub flush-to-state($byte, $new-state) {
        if $sequence.elems {
            # XXXX: Should bare ESC be considered Incomplete?
            emit-item(Incomplete.new(:$sequence));
            $sequence = $seq-buf-type.new;
        }
        $byte.defined ?? $sequence.push($byte)
                      !! emit-item($byte);
        $state = $new-state;
    }

    # Use the given byte to finish the current sequence, emitting it as type,
    # start a new empty sequence, and enter Ground state
    my sub finish-sequence($byte, $type) {
        $sequence.push($byte);
        emit-item($type.new(:$sequence));
        $sequence = $seq-buf-type.new;
        $state = Ground;
    }

    # Start recording a "string" of a particular type
    my sub start-string($type) {
        $string-type = $type;
        $string      = $str-buf-type.new;
    }

    # Buffer a byte into the current "string"
    my sub buffer-string($byte) {
        $string.push($byte);
    }

    # Handle ST (String Terminator) byte, depending on current string buffer:
    # If the string buffer is defined, emit a typed String and clear the
    # buffer; elsif there is a non-empty sequence, add the ST byte and send
    # the sequence as Ignored; else emit the ST byte on its own.  In any case,
    # start a new sequence and drop to the Ground state.
    my sub handle-st($st) {
        if $string.defined {
            emit-item($string-type.new(:$sequence, :$string));
            $string-type = String;
            $string      = Nil;
        }
        elsif $sequence.elems {
            $sequence.push($st);
            emit-item(Ignored.new(:$sequence));
        }
        else {
            emit-item($st);
        }

        $sequence = $seq-buf-type.new;
        $state    = Ground;
    }


    # Action definitions (reduces closure explosion for oft-reused actions)
    my &emit-to-ground  := { emit-item($_); $state = Ground                    };
    my &flush-to-escape := { flush-to-state($_, Escape)                        };
    my &flush-to-csi    := { flush-to-state($_, CSI_Entry)                     };
    my &flush-to-dcs    := { flush-to-state($_, DCS_Entry)                     };
    my &flush-to-sos    := { flush-to-state($_, SOS_String); start-string(SOS) };
    my &flush-to-osc    := { flush-to-state($_, OSC_String); start-string(OSC) };
    my &flush-to-pm     := { flush-to-state($_, PM_String);  start-string(PM)  };
    my &flush-to-apc    := { flush-to-state($_, APC_String); start-string(APC) };
    my &record-to-esc-i := { $sequence.push($_); $state = Escape_Intermediate  };
    my &record-to-csi-p := { $sequence.push($_); $state = CSI_Param            };
    my &record-to-csi-i := { $sequence.push($_); $state = CSI_Intermediate     };
    my &record-to-csi-x := { $sequence.push($_); $state = CSI_Ignore           };
    my &record-to-dcs-p := { $sequence.push($_); $state = DCS_Param            };
    my &record-to-dcs-i := { $sequence.push($_); $state = DCS_Intermediate     };
    my &record-to-dcs-x := { $sequence.push($_); $state = DCS_Ignore           };
    my &record-to-dcs-s := { $sequence.push($_); $state = DCS_Passthrough; start-string(DCS) };
    my &finish-escape   := { finish-sequence($_, SimpleEscape)        };
    my &finish-csi      := { finish-sequence($_, CSI)                 };


    ### MULTI-STATE ACTIONS

    # Actions that apply in every DecodeState
    for DecodeState.enums.values -> $id {
        my $dispatch = @actions[$id] = [];

        $dispatch[$_] := &emit-to-ground
            for flat 0x18, 0x1A, 0x80..0x8F, 0x91..0x97, 0x99, 0x9A;

        $dispatch[0x1B] := &flush-to-escape;
        $dispatch[0x90] := &flush-to-dcs;
        $dispatch[0x98] := &flush-to-sos;
        $dispatch[0x9B] := &flush-to-csi;
        $dispatch[0x9C] := &handle-st;
        $dispatch[0x9D] := &flush-to-osc;
        $dispatch[0x9E] := &flush-to-pm;
        $dispatch[0x9F] := &flush-to-apc;
    }

    # States that emit most C0 controls immediately
    for Ground, Escape, Escape_Intermediate, CSI_Entry, CSI_Param,
        CSI_Intermediate, CSI_Ignore -> $id {
        my $dispatch = @actions[$id];

        $dispatch[$_] := &emit-item
            for flat 0x00..0x17, 0x19, 0x1C..0x1F;
    }

    # States that ignore most C0 controls
    for DCS_Entry, DCS_Param, DCS_Intermediate, OSC_String -> $id {
        my $dispatch = @actions[$id];

        $dispatch[$_] := &ignore-byte
            for flat 0x00..0x17, 0x19, 0x1C..0x1F;
    }

    # States that ignore 0x7F
    for Escape, Escape_Intermediate, CSI_Entry, CSI_Param, CSI_Intermediate,
        CSI_Ignore, DCS_Entry, DCS_Param, DCS_Intermediate, DCS_Passthrough {
        @actions[$_][0x7F] := &ignore-byte;
    }


    ### PER-STATE ACTIONS

    # The following states use only default or multi-state behaviors:
    #   Ground
    #   DCS_Passthrough
    #   DCS_Ignore
    #   OSC_String (in $dec-pedantic mode)
    #   SOS_String
    #   PM_String
    #   APC_String

    # Escape state actions
    my $dispatch     = @actions[Escape];
    $dispatch[$_]   := &record-to-esc-i for 0x20..0x2F;
    $dispatch[0x5B] := { $sequence.push($_); $state = CSI_Entry  };
    $dispatch[0x50] := { $sequence.push($_); $state = DCS_Entry  };
    $dispatch[0x58] := { $sequence.push($_); $state = SOS_String; start-string(SOS) };
    $dispatch[0x5D] := { $sequence.push($_); $state = OSC_String; start-string(OSC) };
    $dispatch[0x5E] := { $sequence.push($_); $state = PM_String;  start-string(PM)  };
    $dispatch[0x5F] := { $sequence.push($_); $state = APC_String; start-string(APC) };

    # Escape_Intermediate state actions
    $dispatch        = @actions[Escape_Intermediate];
    $dispatch[$_]   := &record-to-esc-i for 0x20..0x2F;

    # CSI_Entry state actions
    $dispatch        = @actions[CSI_Entry];
    $dispatch[$_]   := &record-to-csi-i for 0x20..0x2F;
    $dispatch[$_]   := &record-to-csi-p for flat 0x30..0x39, 0x3B..0x3F;
    $dispatch[0x3A] := &record-to-csi-x;

    # CSI_Param state actions
    $dispatch        = @actions[CSI_Param];
    $dispatch[$_]   := &record-to-csi-i for 0x20..0x2F;
    $dispatch[$_]   := &record-to-csi-p for flat 0x30..0x39, 0x3B;
    $dispatch[$_]   := &record-to-csi-x for flat 0x3A, 0x3C..0x3F;

    # CSI_Intermediate state actions
    $dispatch        = @actions[CSI_Intermediate];
    $dispatch[$_]   := &record-to-csi-i for 0x20..0x2F;
    $dispatch[$_]   := &record-to-csi-x for 0x30..0x3F;

    # CSI_Ignore state actions
    $dispatch        = @actions[CSI_Ignore];
    $dispatch[$_]   := &record-to-csi-x for 0x20..0x3F;

    # DCS_Entry state actions
    $dispatch        = @actions[DCS_Entry];
    $dispatch[$_]   := &record-to-dcs-i for 0x20..0x2F;
    $dispatch[$_]   := &record-to-dcs-p for flat 0x30..0x39, 0x3B..0x3F;
    $dispatch[0x3A] := &record-to-dcs-x;

    # DCS_Param state actions
    $dispatch        = @actions[DCS_Param];
    $dispatch[$_]   := &record-to-dcs-i for 0x20..0x2F;
    $dispatch[$_]   := &record-to-dcs-p for flat 0x30..0x39, 0x3B;
    $dispatch[$_]   := &record-to-dcs-x for flat 0x3A, 0x3C..0x3F;

    # DCS_Intermediate state actions
    $dispatch        = @actions[DCS_Intermediate];
    $dispatch[$_]   := &record-to-dcs-i for 0x20..0x2F;
    $dispatch[$_]   := &record-to-dcs-x for 0x30..0x3F;

    # OSC_String state actions
    if !$dec-pedantic {
        # A real (physical) DEC VT terminal would ignore BEL in OSC.  However,
        # in xterm and other terminal emulators BEL can also terminate OSC
        # and some applications depend on this behavior.  So unless forcing
        # DEC pedantry, recognize the BEL behavior.  For more details, see the
        # discussion near the top of:
        #     https://invisible-island.net/xterm/ctlseqs/ctlseqs.html#h3-Operating-System-Commands

        $dispatch        = @actions[OSC_String];
        $dispatch[0x07] := &handle-st;
    }


    ### DEFAULT ACTIONS

    # Make sure any actions set for 0x21..0x7E are also set for 0xA1..0xFE
    for @actions -> $dispatch {
        for 0x21..0x7E -> $byte {
            $dispatch[$byte + 0x80] := $dispatch[$byte] if $dispatch[$byte];
        }
    }


    # Default actions
    @default[Ground]              := &emit-item;
    @default[Escape]              := &finish-escape;
    @default[Escape_Intermediate] := &finish-escape;
    @default[CSI_Entry]           := &finish-csi;
    @default[CSI_Param]           := &finish-csi;
    @default[CSI_Intermediate]    := &finish-csi;
    @default[CSI_Ignore]          := &ignore-sequence;
    @default[DCS_Entry]           := &record-to-dcs-s;
    @default[DCS_Param]           := &record-to-dcs-s;
    @default[DCS_Intermediate]    := &record-to-dcs-s;
    @default[DCS_Passthrough]     := &buffer-string;
    @default[DCS_Ignore]          := &record-to-dcs-x;
    @default[OSC_String]          := &buffer-string;
    @default[SOS_String]          := &buffer-string;
    @default[PM_String]           := &buffer-string;
    @default[APC_String]          := &buffer-string;


    # Return generated parser step closure
    sub ansi-parse-byte($byte) {
        $byte.defined ?? (@actions[$state][$byte] || @default[$state])($byte)
                      !! flush-to-state($byte, Ground);
    }
}


=begin pod

=head1 NAME

Terminal::ANSIParser - ANSI/VT stream parser


=head1 SYNOPSIS

=begin code :lang<raku>

use Terminal::ANSIParser;

my @parsed;

# Default: Assume UTF-8 decoded inputs, thus working with codepoints
my &parse-codepoint := make-ansi-parser(emit-item => { @parsed.push: $_ });
parse-codepoint($_) for $input-buffer.list;

# Raw bytes: Assume raw byte stream input, for pre-Unicode terminal emulation
my &parse-byte := make-ansi-parser(emit-item => { @parsed.push: $_ },
                                   :raw-bytes);
parse-byte($_) for $input-buffer.list;

# DEC Pedantic: Ignore xterm extensions, forcing pure DEC VT compatibility
#               (implies :raw-bytes as well)
my &parse-pedantic := make-ansi-parser(emit-item => { @parsed.push: $_ },
                                       :dec-pedantic);
parse-pedantic($_) for $input-buffer.list;

=end code


=head1 DESCRIPTION

C<Terminal::ANSIParser> is a general parser for ANSI/VT escape codes, as
defined by the related specs ANSI X3.64, ECMA-48, ISO/IEC 6429, and of course
the actual physical DEC VT terminals generally considered the standard for
escape code behavior.

The basic C<make-ansi-parser()> routine builds and returns a
codepoint-by-codepoint (or byte-by-byte, if the C<:raw-bytes> option is True)
table-based binary parsing state machine, based on (and extended from) the
error-recovering state machine built from observed DEC VT behavior described at
L<https://vt100.net/emu/dec_ansi_parser>.

Each time the parser determines that it has parsed enough input, it emits a
token representing the parsed data, which can take one of the following forms:

=item A plain codepoint (or byte if C<:raw-bytes> is True), for passed through
      data when no escape sequence is active

=item A C<Terminal::ANSIParser::Sequence> object, if an escape sequence is parsed

=item A C<Terminal::ANSIParser::String> object, if a control string is parsed

A few C<Sequence> subclasses exist for separate cases:

=item C<Ignored>: invalid sequences that the parser decides should be ignored

=item C<Incomplete>: sequences that were cut off by the start of another
      sequence or the end of the input data (see L<End of Input> below)

=item C<SimpleEscape>: simple escape sequences such as function key codes

=item C<CSI>: parameterized sequences beginning with C<CSI> (C<ESC [>)

Likewise, C<String> has its own subclasses:

=item C<DCS>: Device Control Strings

=item C<OSC>: Operating System Commands

=item C<SOS>: Strings beginning with a general Start Of String indicator

=item C<PM>: Privacy Message (NOTE: NOT A SECURE FUNCTION)

=item C<APC>: Application Program Command


=head2 End of Input

End of input can be signaled by parsing an undefined "codepoint"/"byte"; any
partial sequence in progress will be flushed as C<Incomplete>, and the
undefined marker will be emitted as well, so that downstream consumers are also
notified that input is complete.


=head1 AUTHOR

Geoffrey Broadwell <gjb@sonic.net>


=head1 COPYRIGHT AND LICENSE

Copyright 2021-2024 Geoffrey Broadwell

This library is free software; you can redistribute it and/or modify it under
the Artistic License 2.0.

=end pod
