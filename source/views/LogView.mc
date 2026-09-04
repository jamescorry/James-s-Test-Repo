import Toybox.Graphics;
import Toybox.Lang;
import Toybox.WatchUi;

//! The event log, newest at the bottom. Up and down scroll through it.
class LogView extends WatchUi.View {
    // How many lines from the end the view is scrolled back by.
    private var _scrollBack as Number = 0;
    private var _rowsShown as Number = 1;

    function initialize() {
        View.initialize();
    }

    function scrollUp() as Void {
        var max = DebugLog.lines().size() - _rowsShown;
        if (_scrollBack < max) {
            _scrollBack++;
            WatchUi.requestUpdate();
        }
    }

    function scrollDown() as Void {
        if (_scrollBack > 0) {
            _scrollBack--;
            WatchUi.requestUpdate();
        }
    }

    function onUpdate(dc as Dc) as Void {
        dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_BLACK);
        dc.clear();

        var width = dc.getWidth();
        var height = dc.getHeight();
        var font = Graphics.FONT_XTINY;
        var lineHeight = dc.getFontHeight(font);

        dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_TRANSPARENT);
        dc.drawText(
            width / 2,
            height * 0.12,
            Graphics.FONT_TINY,
            WatchUi.loadResource(Rez.Strings.LogTitle) as String,
            Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER
        );

        var lines = DebugLog.lines();
        if (lines.size() == 0) {
            dc.setColor(Graphics.COLOR_LT_GRAY, Graphics.COLOR_TRANSPARENT);
            dc.drawText(
                width / 2,
                height / 2,
                font,
                WatchUi.loadResource(Rez.Strings.LogEmpty) as String,
                Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER
            );
            return;
        }

        // Fill the band between the title and the bottom of a round screen.
        var top = (height * 0.22).toNumber();
        var bottom = (height * 0.88).toNumber();
        _rowsShown = (bottom - top) / lineHeight;
        if (_rowsShown < 1) {
            _rowsShown = 1;
        }
        if (_scrollBack > lines.size() - _rowsShown) {
            _scrollBack = lines.size() - _rowsShown;
        }
        if (_scrollBack < 0) {
            _scrollBack = 0;
        }

        var end = lines.size() - _scrollBack;
        var start = end - _rowsShown;
        if (start < 0) {
            start = 0;
        }

        // Left-aligned in a column narrow enough to clear the curve of the
        // screen on the rows nearest the top and bottom.
        var x = (width * 0.14).toNumber();
        var maxWidth = (width * 0.74).toNumber();
        var y = top;
        for (var i = start; i < end; i++) {
            var line = lines[i];
            dc.setColor(colourFor(line), Graphics.COLOR_TRANSPARENT);
            dc.drawText(x, y, font, fit(dc, line, font, maxWidth), Graphics.TEXT_JUSTIFY_LEFT);
            y += lineHeight;
        }

        if (_scrollBack > 0) {
            dc.setColor(Graphics.COLOR_DK_GRAY, Graphics.COLOR_TRANSPARENT);
            dc.drawText(
                width / 2,
                height * 0.93,
                font,
                "+" + _scrollBack.toString(),
                Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER
            );
        }
    }

    //! Red for anything that ended an attempt, green for a reply from the car.
    private function colourFor(line as String) as Number {
        if (line.find("!") != null) {
            return Graphics.COLOR_RED;
        }
        if (line.find("rx ") != null || line.find("car:") != null) {
            return Graphics.COLOR_GREEN;
        }
        return Graphics.COLOR_LT_GRAY;
    }

    private function fit(dc as Dc, text as String, font as Graphics.FontDefinition, maxWidth as Number) as String {
        if (dc.getTextWidthInPixels(text, font) <= maxWidth) {
            return text;
        }
        var length = text.length();
        while (length > 1) {
            length--;
            var shorter = (text.substring(0, length) as String) + "~";
            if (dc.getTextWidthInPixels(shorter, font) <= maxWidth) {
                return shorter;
            }
        }
        return text;
    }
}
