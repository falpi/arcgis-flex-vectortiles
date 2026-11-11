package org.falpi.ags.layers.vectorTiles.labels
{
    /** Lays out the glyphs of a label: line breaking, justification and anchoring. */
    public final class TextShaper
    {
        private static const Y_OFFSET:Number = -17;
        private static const MISSING_ADVANCE:Number = 6;

        /**
         * All lengths are in glyph units (24 per em).
         * @param maxWidth wrap width; 0 disables wrapping
         * @param anchor text-anchor value ("center", "top-left", ...)
         * @param justify text-justify value ("left", "center", "right", "auto")
         */
        public static function shape(text:String, stack:FontStack, maxWidth:Number, lineHeight:Number, spacing:Number,
                                     anchor:String, justify:String, offsetX:Number, offsetY:Number):Shaping
        {
            var shaping:Shaping = new Shaping();
            var horizontalAlign:Number = 0.5;
            var verticalAlign:Number = 0.5;
            if (anchor.indexOf("left") >= 0) horizontalAlign = 0;
            else if (anchor.indexOf("right") >= 0) horizontalAlign = 1;
            if (anchor.indexOf("top") >= 0) verticalAlign = 0;
            else if (anchor.indexOf("bottom") >= 0) verticalAlign = 1;
            var justification:Number = justify == "left" ? 0 : (justify == "right" ? 1 : (justify == "auto" ? horizontalAlign : 0.5));

            var lines:Array = breakLines(text, stack, maxWidth, spacing);
            var lineStarts:Array = [];
            var lineLengths:Array = [];
            var maxLength:Number = 0;
            var y:Number = Y_OFFSET;
            var count:int = 0;
            var i:int;
            for each (var line:String in lines)
            {
                var x:Number = 0;
                lineStarts.push(count);
                for (i = 0; i < line.length; i++)
                {
                    var glyph:Glyph = stack.glyphs[line.charCodeAt(i)] as Glyph;
                    if (glyph == null)
                    {
                        continue;
                    }
                    shaping.glyphs[count] = glyph;
                    shaping.xs[count] = x;
                    shaping.ys[count] = y;
                    count++;
                    x += glyph.advance + spacing;
                }
                var length:Number = x > 0 ? x - spacing : 0;
                lineLengths.push(length);
                if (length > maxLength)
                {
                    maxLength = length;
                }
                y += lineHeight;
            }
            lineStarts.push(count);
            if (count == 0)
            {
                return null;
            }
            var lineCount:int = lines.length;
            var shiftX:Number = (justification - horizontalAlign) * maxLength + offsetX;
            var shiftY:Number = (-verticalAlign * lineCount + 0.5) * lineHeight + offsetY;
            for (var l:int = 0; l < lineCount; l++)
            {
                var lineShift:Number = shiftX - lineLengths[l] * justification;
                for (i = lineStarts[l]; i < lineStarts[l + 1]; i++)
                {
                    shaping.xs[i] += lineShift;
                    shaping.ys[i] += shiftY;
                }
            }
            var height:Number = lineCount * lineHeight;
            shaping.width = maxLength;
            shaping.lineCount = lineCount;
            shaping.left = offsetX - horizontalAlign * maxLength;
            shaping.right = shaping.left + maxLength;
            shaping.top = offsetY - verticalAlign * height;
            shaping.bottom = shaping.top + height;
            return shaping;
        }

        private static function advanceOf(stack:FontStack, code:int):Number
        {
            var glyph:Glyph = stack.glyphs[code] as Glyph;
            return glyph != null ? glyph.advance : (code == 32 ? MISSING_ADVANCE : 0);
        }

        private static function measure(stack:FontStack, text:String, spacing:Number):Number
        {
            var width:Number = 0;
            for (var i:int = 0; i < text.length; i++)
            {
                width += advanceOf(stack, text.charCodeAt(i)) + spacing;
            }
            return width;
        }

        /** Splits the text in lines of similar length, none longer than maxWidth when possible. */
        private static function breakLines(text:String, stack:FontStack, maxWidth:Number, spacing:Number):Array
        {
            var result:Array = [];
            var paragraphs:Array = text.split(/\r?\n/);
            for each (var paragraph:String in paragraphs)
            {
                paragraph = paragraph.replace(/^\s+|\s+$/g, "");
                if (paragraph.length == 0)
                {
                    continue;
                }
                var total:Number = measure(stack, paragraph, spacing);
                if (maxWidth <= 0 || total <= maxWidth)
                {
                    result.push(paragraph);
                    continue;
                }
                var target:Number = total / Math.ceil(total / maxWidth);
                // break opportunities: after spaces and after hyphens / slashes
                var words:Array = paragraph.match(/[^\s\-\/]+[\-\/]*\s*|[\-\/]+\s*|\s+/g);
                if (words == null)
                {
                    result.push(paragraph);
                    continue;
                }
                var current:String = "";
                var currentWidth:Number = 0;
                for each (var word:String in words)
                {
                    var wordWidth:Number = measure(stack, word.replace(/\s+$/, ""), spacing);
                    if (current.length > 0 && currentWidth + wordWidth / 2 > target)
                    {
                        result.push(current.replace(/\s+$/, ""));
                        current = "";
                        currentWidth = 0;
                    }
                    current += word;
                    currentWidth += measure(stack, word, spacing);
                }
                if (current.replace(/\s+$/, "").length > 0)
                {
                    result.push(current.replace(/\s+$/, ""));
                }
            }
            return result;
        }
    }
}
