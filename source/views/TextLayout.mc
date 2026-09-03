import Toybox.Graphics;
import Toybox.Lang;

//! Text layout helpers.
//!
//! Dc.drawText draws a single line and does not wrap, so any string wider than
//! the screen simply runs off both edges. Round displays make it worse: the
//! usable width depends on how far from the centre you are drawing.
module TextLayout {
    //! Break text into lines that each fit within maxWidth.
    function wrap(
        dc as Dc,
        text as String,
        font as Graphics.FontType,
        maxWidth as Number
    ) as Array<String> {
        var words = splitOnSpaces(text);
        var lines = [] as Array<String>;
        var line = "";

        for (var i = 0; i < words.size(); i++) {
            var word = words[i];
            var candidate = line.equals("") ? word : line + " " + word;
            if (dc.getTextWidthInPixels(candidate, font) <= maxWidth) {
                line = candidate;
            } else {
                if (!line.equals("")) {
                    lines.add(line);
                }
                // A single word wider than maxWidth still goes on its own
                // line: breaking mid-word would be worse than overflowing.
                line = word;
            }
        }
        if (!line.equals("")) {
            lines.add(line);
        }
        return lines;
    }

    //! Draw text wrapped and centred on a point, growing evenly up and down.
    function drawCentered(
        dc as Dc,
        text as String,
        font as Graphics.FontType,
        centerX as Number,
        centerY as Number,
        maxWidth as Number
    ) as Void {
        var lines = wrap(dc, text, font, maxWidth);
        var lineHeight = dc.getFontHeight(font);
        var top = centerY - ((lines.size() - 1) * lineHeight) / 2;

        for (var i = 0; i < lines.size(); i++) {
            dc.drawText(
                centerX,
                top + i * lineHeight,
                font,
                lines[i],
                Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER
            );
        }
    }

    //! Monkey C's String has no split, so this does it with find/substring.
    //! Runs of spaces produce no empty words.
    function splitOnSpaces(text as String) as Array<String> {
        var words = [] as Array<String>;
        var rest = text;

        while (true) {
            var at = rest.find(" ");
            if (at == null) {
                break;
            }
            var word = rest.substring(0, at) as String;
            if (!word.equals("")) {
                words.add(word);
            }
            rest = rest.substring(at + 1, rest.length()) as String;
        }
        if (!rest.equals("")) {
            words.add(rest);
        }
        return words;
    }
}
