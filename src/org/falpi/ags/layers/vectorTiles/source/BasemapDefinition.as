package org.falpi.ags.layers.vectorTiles.source
{
    import org.falpi.ags.layers.vectorTiles.style.Style;

    /** Everything needed to draw a vector basemap: the style and its resolved tile sources. */
    public final class BasemapDefinition
    {
        public var style:Style;
        /** URL the style document was loaded from. */
        public var styleURL:String;
        /** Source name -> TileSource (vector sources only). */
        public var sources:Object = {};
        public var copyright:String;
        /** Raw JSON of the Esri VectorTileServer, when the basemap comes from one. */
        public var esriService:Object;

        /** The first tile source, used as reference tile grid. */
        public function get primarySource():TileSource
        {
            if (style != null)
            {
                for (var i:int = 0; i < style.layers.length; i++)
                {
                    var source:TileSource = sources[style.layers[i].source] as TileSource;
                    if (source != null)
                    {
                        return source;
                    }
                }
            }
            for each (var any:TileSource in sources)
            {
                return any;
            }
            return null;
        }
    }
}
