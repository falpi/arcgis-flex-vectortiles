package org.falpi.ags.layers.vectorTiles.labels
{
    /** The glyphs loaded so far for one font stack. */
    public final class FontStack
    {
        public static const LOADING:int = 1;
        public static const LOADED:int = 2;
        public static const FAILED:int = 3;

        public var key:String;
        public var names:Array;
        /** Code point -> Glyph. */
        public var glyphs:Object = {};
        /** Range start (multiple of 256) -> state. */
        public var ranges:Object = {};
        /** Set when the server does not serve the combined stack and only the first font is requested. */
        public var firstOnly:Boolean = false;

        public function FontStack(names:Array)
        {
            this.names = names;
            this.key = names.join(",");
        }
    }
}
