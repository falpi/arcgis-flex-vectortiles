package org.falpi.ags.layers.vectorTiles.render
{
    import org.falpi.ags.layers.vectorTiles.mvt.VectorTile;

    /**
     * The data of one source for a display tile. When the display tile is
     * deeper than the data (overzoom) scale and offset select the sub-area.
     */
    public final class SourceTile
    {
        public var tile:VectorTile;
        /** 2^(display zoom - data zoom). */
        public var scale:Number = 1;
        /** Position of the display tile inside the data tile, in display tile units. */
        public var offsetX:Number = 0;
        public var offsetY:Number = 0;

        public function SourceTile(tile:VectorTile, scale:Number = 1, offsetX:Number = 0, offsetY:Number = 0)
        {
            this.tile = tile;
            this.scale = scale;
            this.offsetX = offsetX;
            this.offsetY = offsetY;
        }
    }
}
