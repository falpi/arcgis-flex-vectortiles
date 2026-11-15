package org.falpi.ags.layers.supportClasses
{
    /**
     * Defaults of the tile layers, set once by the application at startup, before the layers are created.
     *
     * <p>There is one object for every tile layer, <code>AbstractTileLayer.defaults</code>, and one for each kind of
     * basemap, <code>RasterTileLayer.defaults</code> and <code>VectorTileLayer.defaults</code>, which add the
     * settings of their kind. A layer reads the object of the kind of basemap it shows (a HybridTileLayer the one
     * of the basemap in use): a setting not set there comes from <code>AbstractTileLayer.defaults</code>. Reading a
     * setting gives the value that a layer without its own value uses.</p>
     *
     * <p><code>AbstractTileLayer.defaults</code> starts with the defaults of the library; the objects of a kind
     * start with the shared settings not set, and with the defaults of the library for their own ones. Setting a
     * value to null (NaN for numbers), or <code>clear</code>, brings it back to how it started.</p>
     *
     * <listing version="3.0">
     * AbstractTileLayer.defaults.proxyURL = proxyPage;     // every tile layer
     * RasterTileLayer.defaults.transport = "flash";        // raster basemaps
     * VectorTileLayer.defaults.transport = "javascript";   // vector basemaps
     * </listing>
     */
    public class TileLayerDefaults
    {
        /** The object of every tile layer (AbstractTileLayer.defaults). */
        private static var s_shared:TileLayerDefaults;

        /** The object of every tile layer, with the defaults of the library. */
        public static function get shared():TileLayerDefaults
        {
            if (s_shared == null)
            {
                s_shared = new TileLayerDefaults({transport: "flash", proxyTiles: true, tileCacheSize: 64,
                    updateMapLods: false});
            }
            return s_shared;
        }

        private var m_initial:Object;
        private var m_values:Object;

        /** @param initial the values it starts with (and goes back to with clear) */
        public function TileLayerDefaults(initial:Object = null)
        {
            m_initial = initial != null ? initial : {};
            clear();
        }

        // ------------------------------------------------------------------
        // settings of every tile layer
        // ------------------------------------------------------------------

        /** Proxy page (null: none; an empty string in an object of a kind: none for that kind). */
        public function get proxyURL():String
        {
            return getValue("proxyURL") as String;
        }

        public function set proxyURL(value:String):void
        {
            store("proxyURL", value);
        }

        /** Token or API key (null: none). */
        public function get token():String
        {
            return getValue("token") as String;
        }

        public function set token(value:String):void
        {
            store("token", value);
        }

        [Inspectable(enumeration="flash,javascript")]
        /** Who makes the requests: "flash" or "javascript" (library: "flash"). */
        public function get transport():String
        {
            return getValue("transport") as String;
        }

        public function set transport(value:String):void
        {
            store("transport", value != null && value.length > 0 ? value : null);
        }

        /** Whether the tiles go through the proxy too (library: true). */
        public function get proxyTiles():Boolean
        {
            return getValue("proxyTiles") == true;
        }

        public function set proxyTiles(value:Boolean):void
        {
            store("proxyTiles", value);
        }

        /** Megabytes of memory for the tiles that left the view (library: 64). */
        public function get tileCacheSize():Number
        {
            var value:* = getValue("tileCacheSize");
            return value is Number ? Number(value) : NaN;
        }

        public function set tileCacheSize(value:Number):void
        {
            store("tileCacheSize", value);
        }

        /** Whether the Map takes the levels of the basemap shown (library: false). */
        public function get updateMapLods():Boolean
        {
            return getValue("updateMapLods") == true;
        }

        public function set updateMapLods(value:Boolean):void
        {
            store("updateMapLods", value);
        }

        // ------------------------------------------------------------------
        // values
        // ------------------------------------------------------------------

        /** Whether this object has a value for the setting (otherwise it comes from AbstractTileLayer.defaults). */
        public function isSet(name:String):Boolean
        {
            return m_values.hasOwnProperty(name);
        }

        /** Brings one setting (or all of them) back to how the object started. */
        public function clear(name:String = null):void
        {
            if (name == null)
            {
                m_values = {};
                for (var key:String in m_initial)
                {
                    m_values[key] = m_initial[key];
                }
            }
            else if (m_initial.hasOwnProperty(name))
            {
                m_values[name] = m_initial[name];
            }
            else
            {
                delete m_values[name];
            }
        }

        /**
         * The value of a setting: the one of this object, otherwise the one of AbstractTileLayer.defaults;
         * undefined when neither has one.
         */
        public function getValue(name:String):*
        {
            if (m_values.hasOwnProperty(name))
            {
                return m_values[name];
            }
            return this !== shared ? shared.getValue(name) : undefined;
        }

        /** Sets a value; null (NaN for numbers) brings the setting back to how the object started. */
        protected function store(name:String, value:*):void
        {
            if (value === null || value === undefined || (value is Number && isNaN(value)))
            {
                clear(name);
            }
            else
            {
                m_values[name] = value;
            }
        }
    }
}
