package org.falpi.ags.layers
{
    import org.falpi.ags.layers.supportClasses.RasterContent;
    import org.falpi.ags.layers.supportClasses.RasterTileLayerDefaults;
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

        // ------------------------------------------------------------------
        // creation by code
        // ------------------------------------------------------------------

        /**
         * A layer of an ArcGIS MapServer (format "esri").
         * @param proxyURL proxy page; null: the defaults
         * @param proxyTiles true or false; null: the defaults
         */
        public static function fromMapServer(url:String, proxyURL:String = null, proxyTiles:Object = null):RasterTileLayer
        {
            var layer:RasterTileLayer = new RasterTileLayer(url, proxyURL);
            layer.format = FORMAT_ESRI;
            AbstractTileLayer.applyProxyTiles(layer, proxyTiles);
            return layer;
        }

        /**
         * A layer of a URL template with {level}, {row}, {col} and {subDomain} (format "tiled", as WebTiledLayer).
         * @param subDomains the values of {subDomain}, one per row in turn
         * @param proxyURL proxy page; null: the defaults
         * @param proxyTiles true or false; null: the defaults
         */
        public static function fromTemplate(template:String, subDomains:Array = null, proxyURL:String = null,
            proxyTiles:Object = null):RasterTileLayer
        {
            var layer:RasterTileLayer = new RasterTileLayer(template, proxyURL);
            layer.format = FORMAT_TILED;
            layer.subDomains = subDomains;
            AbstractTileLayer.applyProxyTiles(layer, proxyTiles);
            return layer;
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
         * The defaults of the raster basemaps (HybridTileLayer included, when it shows one): the settings of every
         * tile layer for the raster basemaps only, and resampling (see TileLayerDefaults).
         */
        public static function get defaults():RasterTileLayerDefaults
        {
            return RasterContent.DEFAULTS;
        }

        private var m_resampling:Boolean = true;
        private var m_resamplingSet:Boolean = false;

        /**
         * Whether a tile that does not exist is replaced by the part of a tile of a lower level that covers it,
         * enlarged (default true), as the resampling of the ArcGIS Maps SDK for JavaScript. "esri": the services
         * with the Tilemap capability say which tiles exist, so their "Map data not yet available" images are
         * never shown. Every format: a tile that cannot be loaded is replaced the same way. Not set:
         * RasterTileLayer.defaults. Reads the value in use.
         */
        public function get resampling():Boolean
        {
            if (m_resamplingSet)
            {
                return m_resampling;
            }
            var option:* = layerOption("resampling");
            return option is Boolean ? Boolean(option) : RasterContent.DEFAULTS.resampling;
        }

        public function set resampling(value:Boolean):void
        {
            var before:Boolean = resampling;
            m_resampling = value;
            m_resamplingSet = true;
            if (before != value)
            {
                invalidateContent();
            }
        }

        override protected function prepareContent():void
        {
            m_raster.resampling = resampling;
        }
    }
}
