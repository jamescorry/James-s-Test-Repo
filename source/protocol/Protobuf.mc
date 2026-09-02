import Toybox.Lang;

//! Minimal proto3 wire-format codec.
//!
//! Tesla's protobuf definitions run to thousands of lines when generated, which
//! is more than a Connect IQ app can afford to keep resident. This codec works
//! directly on the wire format instead: messages are built field by field from
//! the tag numbers in Tesla's .proto files, and parsed into a flat dictionary.
module Protobuf {
    const WIRE_VARINT = 0;
    const WIRE_FIXED64 = 1;
    const WIRE_LEN = 2;
    const WIRE_FIXED32 = 5;

    //! Encode an unsigned value as a base-128 varint.
    function varint(value as Number or Long) as ByteArray {
        var out = []b;
        var v = value.toLong() & 0xFFFFFFFFl;
        do {
            var b = (v & 0x7Fl).toNumber();
            v = v >> 7;
            if (v != 0) {
                b = b | 0x80;
            }
            out.add(b);
        } while (v != 0);
        return out;
    }

    //! The tag byte(s) preceding a field: (fieldNumber << 3) | wireType.
    function tag(field as Number, wireType as Number) as ByteArray {
        return varint(field * 8 + wireType);
    }

    //! A varint field. proto3 omits fields at their default value, and the
    //! vehicle expects that omission, so zero values encode to nothing.
    function uint(field as Number, value as Number) as ByteArray {
        if (value == 0) {
            return []b;
        }
        var out = tag(field, WIRE_VARINT);
        out.addAll(varint(value));
        return out;
    }

    //! A varint field that is written even when zero. Needed where zero is a
    //! meaningful enum value rather than an absent field - RKE_ACTION_UNLOCK
    //! and INFORMATION_REQUEST_TYPE_GET_STATUS are both 0.
    function uintAlways(field as Number, value as Number) as ByteArray {
        var out = tag(field, WIRE_VARINT);
        out.addAll(varint(value));
        return out;
    }

    //! A length-delimited field: bytes, strings and nested messages.
    function bytes(field as Number, value as ByteArray) as ByteArray {
        if (value == null || value.size() == 0) {
            return []b;
        }
        var out = tag(field, WIRE_LEN);
        out.addAll(varint(value.size()));
        out.addAll(value);
        return out;
    }

    //! A fixed32 field. Little-endian on the wire, unlike the big-endian
    //! encoding Tesla uses for the same values inside signed metadata.
    function fixed32(field as Number, value as Number) as ByteArray {
        var out = tag(field, WIRE_FIXED32);
        out.add(value & 0xFF);
        out.add((value >> 8) & 0xFF);
        out.add((value >> 16) & 0xFF);
        out.add((value >> 24) & 0xFF);
        return out;
    }

    //! Parse a message into { fieldNumber => value }.
    //!
    //! Varints become Long, length-delimited fields become ByteArray, fixed32
    //! becomes Number. Repeated fields keep the last occurrence; none of the
    //! messages this app exchanges use repeated fields.
    function decode(data as ByteArray) as Dictionary {
        var out = {};
        var i = 0;
        var n = data.size();
        while (i < n) {
            var header = readVarint(data, i);
            if (header == null) {
                break;
            }
            var field = (header[0] >> 3).toNumber();
            var wireType = (header[0] & 0x07l).toNumber();
            i = header[1];

            if (wireType == WIRE_VARINT) {
                var v = readVarint(data, i);
                if (v == null) {
                    break;
                }
                out.put(field, v[0]);
                i = v[1];
            } else if (wireType == WIRE_LEN) {
                var lengthField = readVarint(data, i);
                if (lengthField == null) {
                    break;
                }
                var length = lengthField[0].toNumber();
                i = lengthField[1];
                if (length < 0 || i + length > n) {
                    break;
                }
                out.put(field, data.slice(i, i + length));
                i += length;
            } else if (wireType == WIRE_FIXED32) {
                if (i + 4 > n) {
                    break;
                }
                out.put(field, data[i] | (data[i + 1] << 8) | (data[i + 2] << 16) | (data[i + 3] << 24));
                i += 4;
            } else if (wireType == WIRE_FIXED64) {
                if (i + 8 > n) {
                    break;
                }
                out.put(field, data.slice(i, i + 8));
                i += 8;
            } else {
                // Groups are deprecated and unused here; a message containing
                // one is malformed as far as this client is concerned.
                break;
            }
        }
        return out;
    }

    //! Read one varint. Returns [value as Long, nextOffset] or null if the
    //! buffer ends mid-value.
    function readVarint(data as ByteArray, offset as Number) as Array? {
        var result = 0l;
        var shift = 0;
        var i = offset;
        var n = data.size();
        while (i < n && shift <= 56) {
            var b = data[i];
            result = result | ((b & 0x7F).toLong() << shift);
            i++;
            if ((b & 0x80) == 0) {
                return [result, i];
            }
            shift += 7;
        }
        return null;
    }

    //! Read a nested message field, returning an empty dictionary when absent.
    function submessage(parent as Dictionary, field as Number) as Dictionary {
        var raw = parent.get(field);
        if (raw instanceof ByteArray) {
            return decode(raw);
        }
        return {};
    }
}
