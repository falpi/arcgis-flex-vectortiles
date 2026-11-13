package org.falpi.ags.layers.vectorTiles.render
{
    import org.falpi.ags.layers.vectorTiles.mvt.MvtFeature;
    import org.falpi.ags.layers.vectorTiles.style.StyleLayer;

    /**
     * A label or icon that a tile would like to show. Collected while the
     * tile is rendered; placed (or discarded) later by the SymbolPlacer.
     */
    public final class SymbolCandidate
    {
        public var layer:StyleLayer;
        public var feature:MvtFeature;
        /** True for symbol-placement "line". */
        public var alongLine:Boolean;
        /** Point placement: interleaved x,y anchors in tile pixels. */
        public var points:Vector.<Number>;
        /** Line placement: Array of Vector.&lt;Number&gt; polylines in tile pixels. */
        public var lines:Array;
        /** Layout computed by the placer on first use (valid for the tile zoom). */
        public var layout:Object;
        /**
         * Placement that last settled this point symbol for good (placed, or refused by a collision): a later
         * incremental placement of the same generation skips it.
         */
        public var settled:int = -1;
    }
}
