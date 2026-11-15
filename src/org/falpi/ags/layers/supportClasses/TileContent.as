package org.falpi.ags.layers.supportClasses
{
    import com.esri.ags.SpatialReference;
    import com.esri.ags.geometry.Extent;
    import com.esri.ags.layers.supportClasses.TileInfo;

    import flash.display.DisplayObject;
    import flash.geom.Rectangle;

    import org.falpi.ags.layers.AbstractTileLayer;
    import org.falpi.ags.net.ResourceLoader;
    import org.falpi.ags.layers.supportClasses.tile_internal;
    import org.falpi.ags.utils.WebMercator;

    use namespace tile_internal;

    /**
     * What a tile layer shows: the part of an AbstractTileLayer that depends on the kind of tiles. The layer
     * integrates with the Map, keeps the tiles of the view, lays them out and spreads the work over the frames;
     * the content loads the basemap, describes its tile grid, loads and draws each tile and can add overlays
     * (the labels of the vector basemaps).
     *
     * <p>Not a Layer: a layer has one content at a time and can replace it (HybridTileLayer).</p>
     */
    public class TileContent
    {
        /** The layer the content is attached to (null when detached). */
        protected var host:AbstractTileLayer;

        // ------------------------------------------------------------------
        // set by the content when the basemap is loaded (see load)
        // ------------------------------------------------------------------

        /** Levels of detail given to the Map. */
        public var tileInfo:TileInfo;
        public var fullExtent:Extent;
        public var initialExtent:Extent;
        public var spatialReference:SpatialReference;
        /** Copyright of the basemap, null if it has none. */
        public var copyright:String;
        /**
         * Scale range declared by the basemap (0: no limit). The layer takes it as its minScale and maxScale when
         * the application set none, as ArcGISTiledMapServiceLayer does with the metadata of its service.
         */
        public var minScale:Number = 0;
        public var maxScale:Number = 0;
        /** Top left corner of the tile grid, in map units. */
        public var originX:Number = 0;
        public var originY:Number = 0;

        tile_internal function attach(layer:AbstractTileLayer):void
        {
            host = layer;
        }

        tile_internal function detach():void
        {
            unload();
            clear();
            host = null;
        }

        // ------------------------------------------------------------------
        // loading
        // ------------------------------------------------------------------

        /**
         * Loads the basemap from url with the loader of the layer (proxy, token, transport). When done the content
         * sets the fields above and calls host.contentReady(), or host.contentFailed(message).
         */
        public function load(loader:ResourceLoader, url:String):void
        {
        }

        /** Drops the basemap (requests, data). */
        public function unload():void
        {
        }

        /** Whether the basemap is loaded and tiles can be made. */
        public function get ready():Boolean
        {
            return false;
        }

        // ------------------------------------------------------------------
        // tile grid
        // ------------------------------------------------------------------

        /**
         * The level for a resolution (map units per pixel). The integer part chooses the tiles; the vector
         * basemaps use the fraction too (their styles change continuously with the zoom).
         */
        public function levelFor(resolution:Number):Number
        {
            return 0;
        }

        /** The level of the tiles to show for the level of the view: the deepest available when deeper. */
        public function tileLevel(level:int):int
        {
            return level;
        }

        /** Size of a tile in map units. */
        public function span(level:int):Number
        {
            return 0;
        }

        /** Tiles that exist at a level: x, y the first column and row, right and bottom the last ones (included). */
        public function tileRange(level:int):Rectangle
        {
            var last:int = Math.pow(2, level) - 1;
            return new Rectangle(0, 0, last, last);
        }

        /**
         * How many columns make the whole world at a level, when the map can repeat it across the antimeridian
         * (Map.wrapAround180); 0 when it cannot (a projection that does not wrap, or a grid that is not aligned
         * with the world).
         */
        public function worldColumns(level:int):int
        {
            return 0;
        }

        /**
         * The columns of the world for tiles of the given span (map units), for grids of Web Mercator or of
         * geographic coordinates whose first column starts at the antimeridian; 0 otherwise.
         */
        protected function worldColumnsOf(span:Number):int
        {
            var wkid:Number = spatialReference != null ? spatialReference.wkid : NaN;
            var width:Number;
            if (WebMercator.isWebMercator(wkid))
            {
                width = WebMercator.WORLD;
            }
            else if (wkid == 4326)
            {
                width = 360;
            }
            else
            {
                return 0;
            }
            if (!(span > 0) || Math.abs(originX + width / 2) > span * 1e-6)
            {
                return 0;
            }
            var columns:Number = Math.round(width / span);
            return columns >= 1 && Math.abs(columns * span - width) <= span * 1e-6 ? int(columns) : 0;
        }

        // ------------------------------------------------------------------
        // tiles
        // ------------------------------------------------------------------

        /**
         * Starts loading a new tile (an Object of the layer: key, z, x, y, column, size, span, mapX, mapY, zoom; the
         * content may add fields). x and y are the column and the row of the tile in the grid of the service;
         * column is its column in the view, which differs from x for the copies of the world shown across the
         * antimeridian (Map.wrapAround180); mapX, mapY are where it is shown. When it can be drawn the content
         * calls host.tileReady(tile).
         */
        public function createTile(tile:Object):void
        {
        }

        /** Draws a tile that is ready: the display object to show (null for nothing). */
        public function renderTile(tile:Object):DisplayObject
        {
            return null;
        }

        /**
         * Size in pixels of what renderTile returned when not scaled. The layer scales it to the size of the tile
         * in the view.
         */
        public function nativeSize(tile:Object):Number
        {
            return tile.size;
        }

        /**
         * The defaults of the kind of basemap of this content (RasterTileLayer.defaults, VectorTileLayer.defaults):
         * null, the defaults of every tile layer only.
         */
        public function get defaults():TileLayerDefaults
        {
            return null;
        }

        /**
         * A drawn tile left the view and is kept by the layer (tileCacheSize), to be shown again as it is: the
         * content drops what was needed only to draw it. releaseTile is called when it leaves the cache.
         */
        public function tileCached(tile:Object):void
        {
        }

        /** A tile is dropped: cancels its requests and frees what renderTile made. */
        public function releaseTile(tile:Object):void
        {
        }

        /** Drops the cached tile data. */
        public function clearData():void
        {
        }

        // ------------------------------------------------------------------
        // frames
        // ------------------------------------------------------------------

        /** At the start of a frame of work: true if the content used the frame (no tile is drawn in it). */
        public function frameStart(now:int):Boolean
        {
            return false;
        }

        /** Tiles were drawn in this frame. */
        public function tilesRendered():void
        {
        }

        /** A frame with no tile left to draw. */
        public function idle(now:int, loading:Boolean):void
        {
        }

        /** Whether the content still has work for the next frames. */
        public function get busy():Boolean
        {
            return false;
        }

        /** Whether the update can end once every tile of the view is drawn. */
        public function get settled():Boolean
        {
            return true;
        }

        /** Part of the timings of the update added by the content (as "labels placed ... , "), reset by resetStats. */
        public function get timings():String
        {
            return "";
        }

        public function resetStats():void
        {
        }

        // ------------------------------------------------------------------
        // view
        // ------------------------------------------------------------------

        /** The view changed (updateLayer): the tiles are laid out. */
        public function viewChanged():void
        {
        }

        /** The level of the tiles of the view changed. */
        public function levelChanged():void
        {
        }

        /** The tiles were laid out again for the current extent, without a new update. */
        public function rebased():void
        {
        }

        public function zoomStarted():void
        {
        }

        /** A step of the zoom animation: the content of the layer was scaled. */
        public function zoomUpdated():void
        {
        }

        public function panStarted():void
        {
        }

        /** The map was dragged: the tiles of the visible area are made. */
        public function panMoved():void
        {
        }

        /** Drops the overlays (the tiles are dropped by the layer). */
        public function clear():void
        {
        }

        /** refresh() of the layer: the tiles are loaded again. */
        public function refresh():void
        {
        }
    }
}
