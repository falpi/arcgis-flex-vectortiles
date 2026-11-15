package org.falpi.ags.layers.supportClasses
{
    /**
     * The drawn tiles that left the view (tileCacheSize of AbstractTileLayer), by key, within a budget of bytes:
     * the least recently seen are dropped first. A tile dropped is given to the release function.
     */
    public final class TileCache
    {
        private var m_tiles:Object = {};
        /** Keys of m_tiles, the least recently seen first. */
        private var m_order:Array = [];
        private var m_bytes:Number = 0;
        private var m_release:Function;

        /** @param release function(tile:Object):void, called for every tile dropped */
        public function TileCache(release:Function)
        {
            m_release = release;
        }

        /** Number of tiles kept. */
        public function get count():int
        {
            return m_order.length;
        }

        /** Bytes of the tiles kept. */
        public function get bytes():Number
        {
            return m_bytes;
        }

        /**
         * Keeps a tile of the given size, then drops the oldest ones beyond limit (bytes). False when it is not
         * kept: it does not fit, or a tile with that key is already there.
         */
        public function put(key:String, tile:Object, size:Number, limit:Number):Boolean
        {
            if (size > limit || m_tiles[key] != null)
            {
                return false;
            }
            tile.cachedBytes = size;
            m_tiles[key] = tile;
            m_order.push(key);
            m_bytes += size;
            trim(limit);
            return m_tiles[key] == tile;
        }

        /** The tile with that key, taken out of the cache (null when there is none). */
        public function take(key:String):Object
        {
            var tile:Object = m_tiles[key];
            if (tile == null)
            {
                return null;
            }
            delete m_tiles[key];
            var index:int = m_order.lastIndexOf(key);
            if (index >= 0)
            {
                m_order.splice(index, 1);
            }
            m_bytes -= tile.cachedBytes;
            return tile;
        }

        /** Drops the least recently seen tiles until the cache is within limit (bytes). */
        public function trim(limit:Number):void
        {
            while (m_order.length > 0 && m_bytes > limit)
            {
                var key:String = m_order.shift();
                var tile:Object = m_tiles[key];
                delete m_tiles[key];
                if (tile != null)
                {
                    m_bytes -= tile.cachedBytes;
                    m_release(tile);
                }
            }
            if (m_order.length == 0)
            {
                m_bytes = 0;
            }
        }

        /** Drops every tile. */
        public function flush():void
        {
            var tiles:Object = m_tiles;
            m_tiles = {};
            m_order = [];
            m_bytes = 0;
            for each (var tile:Object in tiles)
            {
                m_release(tile);
            }
        }
    }
}
