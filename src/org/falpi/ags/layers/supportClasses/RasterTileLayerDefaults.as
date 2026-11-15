package org.falpi.ags.layers.supportClasses
{
    /**
     * Defaults of the raster basemaps (RasterTileLayer.defaults): those of every tile layer (see TileLayerDefaults),
     * here for the raster basemaps only, and the settings of the raster basemaps.
     */
    public class RasterTileLayerDefaults extends TileLayerDefaults
    {
        public function RasterTileLayerDefaults()
        {
            super({resampling: true});
        }

        /** Whether a missing tile shows the enlarged part of a tile of a lower level (library: true). */
        public function get resampling():Boolean
        {
            return getValue("resampling") == true;
        }

        public function set resampling(value:Boolean):void
        {
            store("resampling", value);
        }
    }
}
