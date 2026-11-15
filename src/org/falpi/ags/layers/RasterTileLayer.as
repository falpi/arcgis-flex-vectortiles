package org.falpi.ags.layers
{
    import org.falpi.ags.layers.supportClasses.RasterContent;
    import org.falpi.ags.layers.supportClasses.tile_internal;

    use namespace tile_internal;

    /**
     * A basemap layer of image tiles, drawn by the tile engine of this library:
     * <ul>
     * <li><code>format="esri"</code> (default): an ArcGIS MapServer, whose levels, extent and copyright are read
     * from its metadata, as ArcGISTiledMapServiceLayer does;</li>
     * <li><code>format="tiled"</code>: a URL template with <code>{level}</code>, <code>{row}</code>,
     * <code>{col}</code> and <code>{subDomain}</code> (to write in MXML through a binding or as
     * <code>\{level\}</code>), with the standard Web Mercator levels and no metadata, as WebTiledLayer does.</li>
     * </ul>
     *
     * <p>Proxy, token, proxyTiles, transport and updateMapLods work as for the vector layers. Beyond maxLevel the
     * tiles of the last level are enlarged.</p>
     */
    public class RasterTileLayer extends AbstractTileLayer
    {
        public static const FORMAT_ESRI:String = RasterContent.FORMAT_ESRI;
        public static const FORMAT_TILED:String = RasterContent.FORMAT_TILED;

        private var m_raster:RasterContent;

        public function RasterTileLayer(url:String = null, proxyURL:String = null, token:String = null)
        {
            super(url, proxyURL, token);
            m_raster = new RasterContent();
            setContent(m_raster);
        }

        [Inspectable(enumeration="esri,tiled", defaultValue="esri")]
        /** "esri" (ArcGIS MapServer, default) or "tiled" (URL template). */
        public function get format():String
        {
            return m_raster.format;
        }

        public function set format(value:String):void
        {
            if (m_raster.format != value)
            {
                m_raster.format = value;
                invalidateContent();
            }
        }

        /** Sub-domains that replace {subDomain} in a "tiled" template, one per row in turn. */
        public function get subDomains():Array
        {
            return m_raster.subDomains;
        }

        public function set subDomains(value:Array):void
        {
            m_raster.subDomains = value;
            invalidateContent();
        }

        /** Servers that the tiles of an "esri" layer are asked to, one per row in turn (as ArcGISTiledMapServiceLayer). */
        public function get tileServers():Array
        {
            return m_raster.tileServers;
        }

        public function set tileServers(value:Array):void
        {
            m_raster.tileServers = value;
            invalidateContent();
        }

        /**
         * Last level. "esri": the levels of the service beyond it are dropped (services often declare more levels
         * than they have tiles for). "tiled": the levels are 0 to maxLevel (default 19).
         */
        public function get maxLevel():Number
        {
            return m_raster.maxLevel;
        }

        public function set maxLevel(value:Number):void
        {
            m_raster.maxLevel = value;
            invalidateContent();
        }

        /**
         * Whether a tile that does not exist is replaced by the part of a tile of a lower level that covers it,
         * enlarged (default true), as the resampling of the ArcGIS Maps SDK for JavaScript. "esri": the services
         * with the Tilemap capability say which tiles exist, so their "Map data not yet available" images are
         * never shown. Every format: a tile that cannot be loaded is replaced the same way.
         */
        public function get resampling():Boolean
        {
            return m_raster.resampling;
        }

        public function set resampling(value:Boolean):void
        {
            if (m_raster.resampling != value)
            {
                m_raster.resampling = value;
                invalidateContent();
            }
        }
    }
}
