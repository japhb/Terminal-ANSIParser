# ABSTRACT: ANSI X3.64/ECMA-48/ISO/IEC 6429/DEC-VT stream parser

unit module Terminal::ANSIParser:auth<zef:japhb>:ver<0.0.1>;


enum DecodeState < Ground Escape Escape_Intermediate
                   CSI_Entry CSI_Param CSI_Intermediate CSI_Ignore
                   DCS_Entry DCS_Param DCS_Intermediate DCS_Passthrough DCS_Ignore
                   OSC_String SOS_String PM_String APC_String >;

class Sequence {
    has $.sequence is required;

    method Str { $.sequence.decode }
}

class String is Sequence {
    has $.string is required;

    method Str { $.string.decode }
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
sub make-ansi-parser(:&emit-item!) is export {
    my $state          = Ground;
    my $string-type    = String;
    my buf8 $sequence .= new;
    my buf8 $string;

    my @actions;
    my @default;


    # Action helpers

    # Ignore a byte, by emitting it by itself as an Ignored Sequence
    my sub ignore-byte($byte) {
        emit-item(Ignored.new(:sequence(buf8.new($byte))))
    }

    # Send an entire sequence (including current byte) as ignored, reset
    # sequence state, and return to Ground state
    my sub ignore-sequence($byte) {
        $sequence.push($byte);
        emit-item(Ignored.new(:$sequence));
        $sequence .= new;
        $state = Ground;
    }

    # Flush previous sequence if any by emitting it as Incomplete, then start
    # a new sequence with given byte and enter new-state
    my sub flush-to-state($byte, $new-state) {
        if $sequence {
            # XXXX: Should bare ESC be considered Incomplete?
            emit-item(Incomplete.new(:$sequence));
            $sequence .= new;
        }
        $sequence.push($byte) if $byte.defined;
        $state = $new-state;
    }

    # Add the given byte to the current sequence and enter new-state
    my sub record-to-state($byte, $new-state) {
        $sequence.push($byte);
        $state = $new-state;
    }

    # Use the given byte to finish the current sequence, emitting it as type,
    # start a new empty sequence, and enter Ground state
    my sub finish-sequence($byte, $type) {
        $sequence.push($byte);
        emit-item($type.new(:$sequence));
        $sequence .= new;
        $state = Ground;
    }

    # Start recording a "string" of a particular type
    my sub start-string($type) {
        $string-type = $type;
        $string     .= new;
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
        elsif $sequence {
            $sequence.push($st);
            emit-item(Ignored.new(:$sequence));
        }
        else {
            emit-item($st);
        }

        $sequence .= new;
        $state     = Ground;
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
    my &record-to-esc-i := { record-to-state($_, Escape_Intermediate) };
    my &record-to-csi-p := { record-to-state($_, CSI_Param)           };
    my &record-to-csi-i := { record-to-state($_, CSI_Intermediate)    };
    my &record-to-csi-x := { record-to-state($_, CSI_Ignore)          };
    my &record-to-dcs-p := { record-to-state($_, DCS_Param)           };
    my &record-to-dcs-i := { record-to-state($_, DCS_Intermediate)    };
    my &record-to-dcs-x := { record-to-state($_, DCS_Ignore)          };
    my &record-to-dcs-s := { record-to-state($_, DCS_Passthrough); start-string(DCS) };
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
    for DCS_Entry, DCS_Param, DCS_Intermediate, DCS_Ignore, OSC_String -> $id {
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
    #   OSC_String
    #   SOS_String
    #   PM_String
    #   APC_String

    # Escape state actions
    my $dispatch     = @actions[Escape];
    $dispatch[$_]   := &record-to-esc-i for 0x20..0x2F;
    $dispatch[0x5B] := { record-to-state($_, CSI_Entry)  };
    $dispatch[0x50] := { record-to-state($_, DCS_Entry)  };
    $dispatch[0x58] := { record-to-state($_, SOS_String); start-string(SOS) };
    $dispatch[0x5D] := { record-to-state($_, OSC_String); start-string(OSC) };
    $dispatch[0x5E] := { record-to-state($_, PM_String);  start-string(PM)  };
    $dispatch[0x5F] := { record-to-state($_, APC_String); start-string(APC) };

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
      or the end of the input data (signaled by parsing an undefined "byte")

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
