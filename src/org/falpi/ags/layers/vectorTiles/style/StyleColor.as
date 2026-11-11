package org.falpi.ags.layers.vectorTiles.style
{
    /** An RGBA color (r, g, b in 0..255, a in 0..1, not premultiplied). */
    public final class StyleColor
    {
        public static const TRANSPARENT:StyleColor = new StyleColor(0, 0, 0, 0);
        public static const BLACK:StyleColor = new StyleColor(0, 0, 0, 1);

        public var r:Number;
        public var g:Number;
        public var b:Number;
        public var a:Number;

        private static var s_cache:Object = {};

        private static const NAMED:Object = {
            transparent: "rgba(0,0,0,0)", black: "#000000", white: "#ffffff", red: "#ff0000", green: "#008000",
            blue: "#0000ff", yellow: "#ffff00", cyan: "#00ffff", aqua: "#00ffff", magenta: "#ff00ff",
            fuchsia: "#ff00ff", gray: "#808080", grey: "#808080", silver: "#c0c0c0", maroon: "#800000",
            olive: "#808000", lime: "#00ff00", teal: "#008080", navy: "#000080", purple: "#800080",
            orange: "#ffa500", brown: "#a52a2a", pink: "#ffc0cb", gold: "#ffd700", beige: "#f5f5dc",
            ivory: "#fffff0", khaki: "#f0e68c", tan: "#d2b48c", coral: "#ff7f50", salmon: "#fa8072",
            crimson: "#dc143c", indigo: "#4b0082", violet: "#ee82ee", orchid: "#da70d6", plum: "#dda0dd",
            turquoise: "#40e0d0", skyblue: "#87ceeb", steelblue: "#4682b4", royalblue: "#4169e1",
            darkblue: "#00008b", darkgreen: "#006400", darkred: "#8b0000", darkgray: "#a9a9a9",
            darkgrey: "#a9a9a9", lightgray: "#d3d3d3", lightgrey: "#d3d3d3", lightblue: "#add8e6",
            lightgreen: "#90ee90", lightyellow: "#ffffe0", whitesmoke: "#f5f5f5", gainsboro: "#dcdcdc",
            dimgray: "#696969", dimgrey: "#696969", slategray: "#708090", slategrey: "#708090",
            forestgreen: "#228b22", seagreen: "#2e8b57", limegreen: "#32cd32", yellowgreen: "#9acd32",
            sienna: "#a0522d", chocolate: "#d2691e", peru: "#cd853f", wheat: "#f5deb3", linen: "#faf0e6",
            snow: "#fffafa", azure: "#f0ffff", lavender: "#e6e6fa", tomato: "#ff6347", firebrick: "#b22222"
        };

        public function StyleColor(r:Number, g:Number, b:Number, a:Number = 1)
        {
            this.r = r;
            this.g = g;
            this.b = b;
            this.a = a;
        }

        /** 0xRRGGBB value usable with the Flash drawing API. */
        public function get rgb():uint
        {
            return (clamp255(r) << 16) | (clamp255(g) << 8) | clamp255(b);
        }

        /** 0xAARRGGBB value, with an optional extra opacity factor. */
        public function argb(opacity:Number = 1):uint
        {
            return (clamp255(a * opacity * 255) << 24) | rgb;
        }

        public static function interpolate(c0:StyleColor, c1:StyleColor, t:Number):StyleColor
        {
            // interpolate premultiplied to avoid dark fringes towards transparent
            var a:Number = c0.a + (c1.a - c0.a) * t;
            if (a <= 0)
            {
                return TRANSPARENT;
            }
            var r:Number = (c0.r * c0.a + (c1.r * c1.a - c0.r * c0.a) * t) / a;
            var g:Number = (c0.g * c0.a + (c1.g * c1.a - c0.g * c0.a) * t) / a;
            var b:Number = (c0.b * c0.a + (c1.b * c1.a - c0.b * c0.a) * t) / a;
            return new StyleColor(r, g, b, a);
        }

        /** Parses a CSS color string. Returns null when the string is not a color. */
        public static function parse(value:String):StyleColor
        {
            if (value == null)
            {
                return null;
            }
            var cached:* = s_cache[value];
            if (cached !== undefined)
            {
                return cached as StyleColor;
            }
            var color:StyleColor = doParse(value);
            s_cache[value] = color;
            return color;
        }

        private static function doParse(value:String):StyleColor
        {
            var s:String = value.replace(/\s+/g, "").toLowerCase();
            if (s.length == 0)
            {
                return null;
            }
            if (NAMED.hasOwnProperty(s))
            {
                s = NAMED[s];
            }
            if (s.charAt(0) == "#")
            {
                var hex:String = s.substr(1);
                if (!/^[0-9a-f]+$/.test(hex))
                {
                    return null;
                }
                if (hex.length == 3 || hex.length == 4)
                {
                    var r1:Number = parseInt(hex.charAt(0), 16) * 17;
                    var g1:Number = parseInt(hex.charAt(1), 16) * 17;
                    var b1:Number = parseInt(hex.charAt(2), 16) * 17;
                    var a1:Number = hex.length == 4 ? parseInt(hex.charAt(3), 16) * 17 / 255 : 1;
                    return new StyleColor(r1, g1, b1, a1);
                }
                if (hex.length == 6 || hex.length == 8)
                {
                    var n:uint = parseInt(hex.substr(0, 6), 16);
                    var a2:Number = hex.length == 8 ? parseInt(hex.substr(6, 2), 16) / 255 : 1;
                    return new StyleColor((n >> 16) & 0xff, (n >> 8) & 0xff, n & 0xff, a2);
                }
                return null;
            }
            var open:int = s.indexOf("(");
            var close:int = s.lastIndexOf(")");
            if (open > 0 && close > open)
            {
                var fn:String = s.substr(0, open);
                var args:Array = s.substring(open + 1, close).split(/[,\/]/);
                if ((fn == "rgb" || fn == "rgba") && args.length >= 3)
                {
                    return new StyleColor(channel(args[0]), channel(args[1]), channel(args[2]),
                        args.length > 3 ? alpha(args[3]) : 1);
                }
                if ((fn == "hsl" || fn == "hsla") && args.length >= 3)
                {
                    return fromHsl(parseFloat(args[0]), parseFloat(args[1]) / 100, parseFloat(args[2]) / 100,
                        args.length > 3 ? alpha(args[3]) : 1);
                }
            }
            return null;
        }

        private static function channel(s:String):Number
        {
            if (s.charAt(s.length - 1) == "%")
            {
                return parseFloat(s) * 2.55;
            }
            return parseFloat(s);
        }

        private static function alpha(s:String):Number
        {
            var v:Number = s.charAt(s.length - 1) == "%" ? parseFloat(s) / 100 : parseFloat(s);
            return isNaN(v) ? 1 : Math.max(0, Math.min(1, v));
        }

        public static function fromHsl(h:Number, s:Number, l:Number, a:Number = 1):StyleColor
        {
            h = (((h % 360) + 360) % 360) / 360;
            s = Math.max(0, Math.min(1, s));
            l = Math.max(0, Math.min(1, l));
            var m2:Number = l <= 0.5 ? l * (s + 1) : l + s - l * s;
            var m1:Number = l * 2 - m2;
            return new StyleColor(hue(m1, m2, h + 1 / 3) * 255, hue(m1, m2, h) * 255, hue(m1, m2, h - 1 / 3) * 255, a);
        }

        private static function hue(m1:Number, m2:Number, h:Number):Number
        {
            if (h < 0) h += 1;
            else if (h > 1) h -= 1;
            if (h * 6 < 1) return m1 + (m2 - m1) * h * 6;
            if (h * 2 < 1) return m2;
            if (h * 3 < 2) return m1 + (m2 - m1) * (2 / 3 - h) * 6;
            return m1;
        }

        private static function clamp255(v:Number):uint
        {
            return v <= 0 ? 0 : (v >= 255 ? 255 : uint(v + 0.5));
        }

        public function toString():String
        {
            return "rgba(" + clamp255(r) + "," + clamp255(g) + "," + clamp255(b) + "," + a + ")";
        }
    }
}
