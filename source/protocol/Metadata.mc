import Toybox.Lang;

//! Tesla's canonical metadata serialisation.
//!
//! Both peers hash the same metadata string to bind a command to its context
//! (which car, which domain, which counter). See "Metadata serialization" in
//! Tesla's protocol.md: each item is tag || length || value, items are sorted
//! by tag ascending, and the string is terminated with 0xFF.
module Metadata {
    const TAG_SIGNATURE_TYPE = 0;
    const TAG_DOMAIN = 1;
    const TAG_PERSONALIZATION = 2;
    const TAG_EPOCH = 3;
    const TAG_EXPIRES_AT = 4;
    const TAG_COUNTER = 5;
    const TAG_CHALLENGE = 6;
    const TAG_FLAGS = 7;
    const TAG_REQUEST_HASH = 8;
    const TAG_FAULT = 9;
    const TAG_END = 255;

    //! Integer metadata values are four-byte big-endian, regardless of how the
    //! same value is encoded on the protobuf wire.
    function be32(value as Number) as ByteArray {
        return [
            (value >> 24) & 0xFF,
            (value >> 16) & 0xFF,
            (value >> 8) & 0xFF,
            value & 0xFF
        ]b;
    }

    //! Enum metadata values are a single byte.
    function byte(value as Number) as ByteArray {
        return [value & 0xFF]b;
    }

    //! items is an array of [tag as Number, value as ByteArray] pairs.
    function serialize(items as Array) as ByteArray {
        var sorted = sortByTag(items);
        var out = []b;
        for (var i = 0; i < sorted.size(); i++) {
            var item = sorted[i] as Array;
            var value = item[1] as ByteArray;
            out.add(item[0] as Number);
            out.add(value.size());
            out.addAll(value);
        }
        out.add(TAG_END);
        return out;
    }

    //! Selection sort into a fresh array. These sets hold at most seven
    //! items, so the simplest approach is also the right one. Note that
    //! Array.addAll mutates in place and returns nothing, so building the
    //! result by slicing and chaining is not an option here.
    function sortByTag(items as Array) as Array {
        var remaining = items.slice(0, null);
        var sorted = [];
        while (remaining.size() > 0) {
            var lowest = 0;
            for (var i = 1; i < remaining.size(); i++) {
                if (((remaining[i] as Array)[0] as Number) < ((remaining[lowest] as Array)[0] as Number)) {
                    lowest = i;
                }
            }
            sorted.add(remaining[lowest]);
            var next = remaining.slice(0, lowest);
            next.addAll(remaining.slice(lowest + 1, null));
            remaining = next;
        }
        return sorted;
    }
}
