package org.falpi.ags.layers.supportClasses
{
    import com.esri.ags.SpatialReference;
    import com.esri.ags.geometry.MapPoint;
    import com.esri.ags.layers.supportClasses.LOD;
    import com.esri.ags.layers.supportClasses.TileInfo;

    import flash.display.Bitmap;
    import flash.display.BitmapData;
    import flash.display.DisplayObject;
    import flash.display.Loader;
    import flash.display.Sprite;
    import flash.events.Event;
    import flash.events.HTTPStatusEvent;
    import flash.events.IOErrorEvent;
    import flash.events.SecurityErrorEvent;
    import flash.geom.Point;
    import flash.geom.Rectangle;
    import flash.net.URLRequest;
    import flash.system.LoaderContext;
    import flash.utils.ByteArray;
    import flash.utils.getTimer;

    import org.falpi.ags.layers.AbstractTileLayer;
    import org.falpi.ags.net.ResourceLoader;
    import org.falpi.ags.net.ResourceRequest;
    import org.falpi.ags.layers.supportClasses.tile_internal;
    import org.falpi.ags.utils.ServiceJson;
    import org.falpi.ags.utils.WebMercator;

    use namespace tile_internal;

    /**
     * Raster basemaps (image tiles), in two formats:
     * <ul>
     * <li>"esri": an ArcGIS MapServer, whose levels, extent, copyright and tile servers are read from its metadata,
     * as ArcGISTiledMapServiceLayer does; tiles url/tile/{level}/{row}/{col}.</li>
     * <li>"tiled": a URL template ({level}, {row}, {col}, {subDomain}) with the standard Web Mercator levels, as
     * WebTiledLayer does, without metadata.</li>
     * </ul>
     *
     * <p>With the Flash transport the tiles are images loaded and shown by Flash (no crossdomain.xml needed, their
     * pixels cannot be read); with the javascript transport the page loads them and Flash decodes them (their pixels
     * can be read, for example by BitmapData.draw of the map). Beyond the last level the last one is enlarged, and
     * with resampling a tile that does not exist shows the enlarged part of a tile of a lower level.</p>
     */
    public class RasterContent extends TileContent
    {
        /** The defaults of the raster basemaps (RasterTileLayer.defaults). */
        public static const DEFAULTS:RasterTileLayerDefaults = new RasterTileLayerDefaults();

        override public function get defaults():TileLayerDefaults
        {
            return DEFAULTS;
        }

        public static const FORMAT_ESRI:String = "esri";
        public static const FORMAT_TILED:String = "tiled";

        /** Last level of the "tiled" format when maxLevel is not given (as WebTiledLayer). */
        private static const TILED_MAX_LEVEL:int = 19;

        // ------------------------------------------------------------------
        // settings
        // ------------------------------------------------------------------

        /** "esri" (default) or "tiled". */
        public var format:String = FORMAT_ESRI;
        /** Sub-domains that replace {subDomain} in a "tiled" template, one per row in turn. */
        public var subDomains:Array;
        /** Servers that the tiles of an "esri" layer are asked to, one per row in turn. */
        public var tileServers:Array;
        /**
         * Last level: "esri", the levels of the service beyond it are dropped (services often declare more levels
         * than they have tiles for); "tiled", the levels are 0 to maxLevel (default 19).
         */
        public var maxLevel:Number = NaN;
        /** Copyright used when the service gives none ("tiled" has none). */
        public var copyrightText:String;
        /**
         * Whether a tile that does not exist is replaced by the part of a tile of a lower level that covers it,
         * enlarged (default true). "esri": the services that declare the Tilemap capability say which tiles exist
         * (their missing tiles are images that read "Map data not yet available"); for every format a tile that
         * cannot be loaded (404, 400...) is replaced the same way.
         */
        public var resampling:Boolean = true;

        // ------------------------------------------------------------------
        // state
        // ------------------------------------------------------------------

        private var m_loader:ResourceLoader;
        private var m_ready:Boolean = false;
        /** Incremented at every load: answers of older requests are ignored. */
        private var m_generation:int = 0;
        /** The levels, finest last. */
        private var m_lods:Array;
        private var m_tileSize:Number = 256;
        /** Tile servers or templates, one per row in turn ({subDomain} already replaced). */
        private var m_servers:Array;
        /** The query of the service URL ("esri"), kept on the tiles. */
        private var m_query:String;
        /** Timestamp added to the tiles after refresh(), so that they are not taken from the cache. */
        private var m_refreshTS:Number = NaN;
        /** URL of the service ("esri"), for its tilemap. */
        private var m_path:String;
        /** Whether the service says which tiles exist (Tilemap capability). */
        private var m_tilemap:Boolean = false;
        /**
         * Blocks of the tilemap: "level/top/left" -> {pending, waiting: [Function], data: Array (null when it
         * could not be read), top, left, width, height}.
         */
        private var m_blocks:Object = {};
        /** Tiles of a lower level whose parts are shown in place of missing tiles: "z/row/col" -> entry. */
        private var m_parents:Object = {};
        /**
         * Tiles whose image failed: "z/row/col" -> true when they do not exist (400, 404, 410, or not an image), or
         * the time (getTimer) until which they are not asked again (other errors, or a status Flash does not give).
         */
        private var m_failed:Object = {};
        private var m_statResampled:int = 0;
        private var m_statBlocks:int = 0;

        override public function get ready():Boolean
        {
            return m_ready;
        }

        override public function load(loader:ResourceLoader, url:String):void
        {
            m_generation++;
            m_loader = loader;
            if (url == null || url.length == 0)
            {
                return;
            }
            if (format == FORMAT_TILED)
            {
                loadTiled(url);
            }
            else if (format == FORMAT_ESRI)
            {
                loadEsri(url);
            }
            else
            {
                host.contentFailed("Unknown raster format '" + format + "' (esri, tiled)");
            }
        }

        override public function unload():void
        {
            m_generation++;
            // before the loader is dropped: clearData cancels the requests of the ancestor images with it
            clearData();
            m_loader = null;
            m_ready = false;
            m_lods = null;
            m_servers = null;
            m_path = null;
            m_tilemap = false;
            tileInfo = null;
            fullExtent = null;
            initialExtent = null;
            spatialReference = null;
            copyright = null;
            minScale = 0;
            maxScale = 0;
        }

        override public function refresh():void
        {
            m_refreshTS = new Date().time;
        }

        // ------------------------------------------------------------------
        // "tiled" (as WebTiledLayer)
        // ------------------------------------------------------------------

        private function loadTiled(template:String):void
        {
            var sr:SpatialReference = new SpatialReference(WebMercator.WKID);
            var info:TileInfo = new TileInfo();
            info.width = 256;
            info.height = 256;
            info.dpi = WebMercator.DPI;
            info.origin = WebMercator.origin(sr);
            info.spatialReference = sr;
            var last:int = isNaN(maxLevel) ? TILED_MAX_LEVEL : Math.max(0, Math.min(30, int(maxLevel)));
            info.lods = WebMercator.lods(256, last);
            spatialReference = sr;
            fullExtent = WebMercator.world(sr);
            initialExtent = fullExtent;
            m_query = null;
            m_path = null;
            m_tilemap = false;
            // as WebTiledLayer: one template per sub-domain, taken in turn by row
            m_servers = [];
            if (template.indexOf("{subDomain}") >= 0 && subDomains != null && subDomains.length > 0)
            {
                for each (var domain:Object in subDomains)
                {
                    m_servers.push(template.split("{subDomain}").join(String(domain)));
                }
            }
            else
            {
                m_servers.push(template);
            }
            copyright = copyrightText;
            setTileInfo(info);
        }

        // ------------------------------------------------------------------
        // "esri" (as ArcGISTiledMapServiceLayer)
        // ------------------------------------------------------------------

        private function loadEsri(service:String):void
        {
            var query:int = service.indexOf("?");
            var path:String = query >= 0 ? service.substr(0, query) : service;
            m_query = query >= 0 ? service.substr(query + 1) : null;
            while (path.length > 0 && path.charAt(path.length - 1) == "/")
            {
                path = path.substr(0, path.length - 1);
            }
            var generation:int = m_generation;
            var metadata:String = path + "?" + (m_query != null && m_query.length > 0 ? m_query + "&" : "") + "f=json";
            m_loader.load(metadata, false, function(text:String, request:ResourceRequest):void
            {
                if (generation != m_generation)
                {
                    return;
                }
                var json:Object;
                try
                {
                    json = JSON.parse(text);
                }
                catch (error:Error)
                {
                    host.contentFailed("Not a map service (invalid JSON): " + path);
                    return;
                }
                if (json.error != null)
                {
                    host.contentFailed("Cannot read the map service " + path + ": " + json.error.message);
                    return;
                }
                if (json.tileInfo == null || !(json.tileInfo.lods is Array))
                {
                    host.contentFailed("Not a tiled map service: " + path);
                    return;
                }
                esriLoaded(json, path);
            }, function(message:String, request:ResourceRequest):void
            {
                if (generation == m_generation)
                {
                    host.contentFailed("Cannot read the map service " + path + ": " + message);
                }
            });
        }

        private function esriLoaded(json:Object, path:String):void
        {
            var source:Object = json.tileInfo;
            var sr:SpatialReference = ServiceJson.spatialReference(json.spatialReference != null ? json.spatialReference : source.spatialReference);
            var info:TileInfo = new TileInfo();
            info.width = Number(source.cols);
            info.height = Number(source.rows);
            info.dpi = Number(source.dpi);
            info.format = source.format;
            info.origin = new MapPoint(Number(source.origin.x), Number(source.origin.y), sr);
            info.spatialReference = sr;
            info.lods = ServiceJson.lods(source.lods, maxLevel);
            spatialReference = sr;
            fullExtent = ServiceJson.extent(json.fullExtent, sr);
            initialExtent = ServiceJson.extent(json.initialExtent, sr);
            if (initialExtent == null)
            {
                initialExtent = fullExtent;
            }
            m_servers = esriTileServers(path, tileServers != null && tileServers.length > 0 ? tileServers :
                (json.tileServers as Array));
            m_path = path;
            m_tilemap = json.capabilities is String && /(^|,)\s*tilemap\s*(,|$)/i.test(String(json.capabilities));
            copyright = copyrightText != null ? copyrightText : json.copyrightText;
            minScale = Number(json.minScale) > 0 ? Number(json.minScale) : 0;
            maxScale = Number(json.maxScale) > 0 ? Number(json.maxScale) : 0;
            setTileInfo(info);
        }

        /**
         * The servers of the tiles, chosen as ArcGISTiledMapServiceLayer does: the ones given, or the ones the
         * service declares, or for ArcGIS Online both server.arcgisonline.com and services.arcgisonline.com.
         */
        private static function esriTileServers(path:String, servers:Array):Array
        {
            var list:Array = [];
            if (servers != null && servers.length > 0)
            {
                for each (var server:Object in servers)
                {
                    list.push(String(server).replace(/\/+$/, ""));
                }
                return list;
            }
            if (/^https?:\/\/server\.arcgisonline\.com/i.test(path))
            {
                return [path, path.replace(/server\.arcgisonline/i, "services.arcgisonline")];
            }
            if (/^https?:\/\/services\.arcgisonline\.com/i.test(path))
            {
                return [path, path.replace(/services\.arcgisonline/i, "server.arcgisonline")];
            }
            return [path];
        }

        /** The levels are known: the content is ready. */
        private function setTileInfo(info:TileInfo):void
        {
            m_lods = info.lods.concat();
            m_lods.sortOn("resolution", Array.NUMERIC | Array.DESCENDING);
            if (m_lods.length == 0)
            {
                host.contentFailed("The raster basemap has no levels");
                return;
            }
            tileInfo = info;
            m_tileSize = info.width > 0 ? info.width : 256;
            originX = info.origin.x;
            originY = info.origin.y;
            if (fullExtent == null)
            {
                fullExtent = WebMercator.world(spatialReference);
                initialExtent = fullExtent;
            }
            m_ready = true;
            host.contentReady();
        }

        // ------------------------------------------------------------------
        // tile grid: the level of the view is the index of the nearest level of the service
        // ------------------------------------------------------------------

        override public function levelFor(resolution:Number):Number
        {
            var best:int = 0;
            var bestDistance:Number = Number.MAX_VALUE;
            for (var i:int = 0; i < m_lods.length; i++)
            {
                var distance:Number = Math.abs(Math.log(LOD(m_lods[i]).resolution / resolution));
                // the finer one when two are as near
                if (distance <= bestDistance + 1e-9)
                {
                    bestDistance = distance;
                    best = i;
                }
                else
                {
                    break;
                }
            }
            return best;
        }

        override public function tileLevel(level:int):int
        {
            return Math.max(0, Math.min(m_lods.length - 1, level));
        }

        override public function span(level:int):Number
        {
            return LOD(m_lods[level]).resolution * m_tileSize;
        }

        override public function worldColumns(level:int):int
        {
            return worldColumnsOf(span(level));
        }

        override public function tileRange(level:int):Rectangle
        {
            var size:Number = span(level);
            var epsilon:Number = size * 1e-6;
            var col0:int = Math.max(0, Math.floor((fullExtent.xmin - originX + epsilon) / size));
            var col1:int = Math.max(col0, Math.floor((fullExtent.xmax - originX - epsilon) / size));
            var row0:int = Math.max(0, Math.floor((originY - fullExtent.ymax + epsilon) / size));
            var row1:int = Math.max(row0, Math.floor((originY - fullExtent.ymin - epsilon) / size));
            return new Rectangle(col0, row0, col1 - col0, row1 - row0);
        }

        // ------------------------------------------------------------------
        // tiles
        // ------------------------------------------------------------------

        /** URL of a tile, before the token and the proxy (z is the index of the level). */
        public function tileURL(z:int, row:int, col:int):String
        {
            var lod:LOD = m_lods[z] as LOD;
            var server:String = m_servers[Math.abs(row) % m_servers.length];
            var url:String;
            if (format == FORMAT_TILED)
            {
                // as WebTiledLayer: the level value of the LOD when it has one
                var level:String = lod.levelValue ? lod.levelValue : String(lod.level);
                url = server.split("{level}").join(level).split("{row}").join(String(row)).split("{col}").join(String(col));
            }
            else
            {
                url = server + "/tile/" + lod.level + "/" + row + "/" + col;
                if (m_query != null && m_query.length > 0)
                {
                    url += "?" + m_query;
                }
            }
            if (!isNaN(m_refreshTS))
            {
                url += (url.indexOf("?") >= 0 ? "&" : "?") + "_ts=" + m_refreshTS;
            }
            return url;
        }

        // phases of a tile
        private static const PHASE_IMAGE:int = 0;
        private static const PHASE_RESAMPLE:int = 1;
        private static const PHASE_DONE:int = 2;
        // states of a tile of a lower level used for resampling
        private static const PARENT_LOADING:int = 0;
        private static const PARENT_READABLE:int = 1;
        private static const PARENT_UNREADABLE:int = 2;
        private static const PARENT_FAILED:int = 3;
        /** Side of the blocks of tiles asked to the tilemap of the service (aligned to multiples of it). */
        private static const TILEMAP_BLOCK:int = 32;
        /** How many levels above a missing tile are tried. */
        private static const MAX_RESAMPLE_LEVELS:int = 8;
        /** How long an image that failed for an unknown or temporary reason is not asked again (ms). */
        private static const RETRY_MS:int = 30000;

        override public function createTile(tile:Object):void
        {
            tile.phase = PHASE_IMAGE;
            if (hasFailed(tile.z, tile.y, tile.x))
            {
                // failed a moment ago: not asked again yet, and not kept in the cache of the layer
                tile.incomplete = m_failed[tile.z + "/" + tile.y + "/" + tile.x] !== true;
                resample(tile, tile.z - 1);
                return;
            }
            // with a tilemap, its answer and the image are asked together: no time is lost when the tile exists
            tile.available = availability(tile.z, tile.y, tile.x, function():void
            {
                tileAvailabilityKnown(tile);
            });
            if (tile.available == 0)
            {
                resample(tile, tile.z - 1);
                return;
            }
            tile.load = loadImage(tileURL(tile.z, tile.y, tile.x), function(display:DisplayObject, size:Number):void
            {
                tile.load = null;
                if (tile.available == -1)
                {
                    // shown when the tilemap says that it is a real tile
                    tile.loaded = display;
                    tile.loadedSize = size;
                }
                else
                {
                    finishTile(tile, display, size);
                }
            }, function(absent:Boolean):void
            {
                tile.load = null;
                imageFailed(tile.z, tile.y, tile.x, absent);
                // a temporary failure: not kept in the cache of the layer, asked again when the tile comes back
                tile.incomplete = !absent;
                resample(tile, tile.z - 1);
            });
        }

        private function tileAvailabilityKnown(tile:Object):void
        {
            if (tile.released || tile.phase != PHASE_IMAGE)
            {
                return;
            }
            tile.available = availability(tile.z, tile.y, tile.x, null);
            if (tile.available == 0)
            {
                // the image is the "not available" one of the service: never shown
                cancelImage(tile.load);
                tile.load = null;
                disposeDisplay(tile.loaded as DisplayObject);
                tile.loaded = null;
                resample(tile, tile.z - 1);
            }
            else if (tile.loaded != null)
            {
                var display:DisplayObject = tile.loaded as DisplayObject;
                tile.loaded = null;
                finishTile(tile, display, tile.loadedSize);
            }
        }

        private function finishTile(tile:Object, display:DisplayObject, size:Number):void
        {
            tile.phase = PHASE_DONE;
            tile.image = display;
            tile.nativeSize = size;
            host.tileReady(tile);
        }

        // ------------------------------------------------------------------
        // which tiles exist (tilemap of the service, and the images that failed)
        // ------------------------------------------------------------------

        /** Whether the image of the tile is not to be asked: it does not exist, or it failed less than RETRY_MS ago. */
        private function hasFailed(z:int, row:int, col:int):Boolean
        {
            var key:String = z + "/" + row + "/" + col;
            var failed:* = m_failed[key];
            if (failed === undefined)
            {
                return false;
            }
            if (failed === true || getTimer() < failed)
            {
                return true;
            }
            delete m_failed[key];
            return false;
        }

        private function imageFailed(z:int, row:int, col:int, absent:Boolean):void
        {
            m_failed[z + "/" + row + "/" + col] = absent ? true : getTimer() + RETRY_MS;
        }

        /**
         * 1 if the tile exists (or nobody says otherwise), 0 if it does not, -1 while the tilemap is being read:
         * onKnown is called when it is known.
         */
        private function availability(z:int, row:int, col:int, onKnown:Function):int
        {
            if (hasFailed(z, row, col))
            {
                return 0;
            }
            if (!resampling || !m_tilemap || m_path == null)
            {
                return 1;
            }
            var level:int = LOD(m_lods[z]).level;
            var top:int = Math.floor(row / TILEMAP_BLOCK) * TILEMAP_BLOCK;
            var left:int = Math.floor(col / TILEMAP_BLOCK) * TILEMAP_BLOCK;
            var key:String = level + "/" + top + "/" + left;
            var block:Object = m_blocks[key];
            if (block == null)
            {
                block = {pending: true, waiting: [], data: null};
                m_blocks[key] = block;
                requestBlock(block, level, top, left);
            }
            if (block.pending)
            {
                if (onKnown != null)
                {
                    block.waiting.push(onKnown);
                }
                return -1;
            }
            if (block.data == null)
            {
                // the tilemap could not be read: as without it
                return 1;
            }
            var r:int = row - block.top;
            var c:int = col - block.left;
            if (r < 0 || c < 0 || r >= block.height || c >= block.width)
            {
                return 1;
            }
            return Number(block.data[r * block.width + c]) == 0 ? 0 : 1;
        }

        private function requestBlock(block:Object, level:int, top:int, left:int):void
        {
            var generation:int = m_generation;
            var url:String = m_path + "/tilemap/" + level + "/" + top + "/" + left + "/" + TILEMAP_BLOCK + "/" + TILEMAP_BLOCK +
                "?" + (m_query != null && m_query.length > 0 ? m_query + "&" : "") + "f=json";
            m_statBlocks++;
            // ahead of the tiles: they wait for it
            m_loader.load(url, false, function(text:String, request:ResourceRequest):void
            {
                if (generation != m_generation)
                {
                    return;
                }
                try
                {
                    var json:Object = JSON.parse(text);
                    var location:Object = json.location;
                    if (json.data is Array && location != null && json.valid !== false)
                    {
                        block.top = int(location.top);
                        block.left = int(location.left);
                        block.width = int(location.width);
                        block.height = int(location.height);
                        if ((json.data as Array).length >= block.width * block.height)
                        {
                            block.data = json.data;
                        }
                    }
                }
                catch (error:Error)
                {
                    // not a tilemap: as without it
                }
                blockKnown(block);
            }, function(message:String, request:ResourceRequest):void
            {
                if (generation == m_generation)
                {
                    blockKnown(block);
                }
            }, true);
        }

        private function blockKnown(block:Object):void
        {
            block.pending = false;
            var waiting:Array = block.waiting;
            block.waiting = [];
            for each (var onKnown:Function in waiting)
            {
                onKnown();
            }
        }

        // ------------------------------------------------------------------
        // resampling: the part of a tile of a lower level, enlarged
        // ------------------------------------------------------------------

        /**
         * Shows in place of the tile the part of the nearest tile of level z or above that exists, enlarged;
         * nothing when there is none (or resampling is off).
         */
        private function resample(tile:Object, z:int):void
        {
            if (tile.released)
            {
                return;
            }
            tile.phase = PHASE_RESAMPLE;
            if (resampling)
            {
                for (; z >= 0 && tile.z - z <= MAX_RESAMPLE_LEVELS; z--)
                {
                    var part:Object = partOf(tile, z);
                    if (part == null)
                    {
                        continue;
                    }
                    var available:int = availability(z, part.row, part.col, resampleLater(tile, z));
                    if (available == -1)
                    {
                        // again when the tilemap of that level is known
                        return;
                    }
                    if (available == 1)
                    {
                        usePart(tile, z, part);
                        return;
                    }
                }
            }
            finishTile(tile, null, 0);
        }

        private function resampleLater(tile:Object, z:int):Function
        {
            return function():void
            {
                resample(tile, z);
            };
        }

        /**
         * The tile of level z that covers the tile, and the square of it that does, in pixels of a tile of the
         * service: {row, col, x, y, size}. Null when the levels are not aligned (a size ratio that is not a whole
         * number dividing the tile).
         */
        private function partOf(tile:Object, z:int):Object
        {
            var ratio:Number = span(z) / span(tile.z);
            var times:int = Math.round(ratio);
            if (times < 2 || Math.abs(ratio - times) > ratio * 1e-6 || m_tileSize % times != 0)
            {
                return null;
            }
            var col:int = Math.floor(tile.x / times);
            var row:int = Math.floor(tile.y / times);
            var size:int = m_tileSize / times;
            return {row: row, col: col, x: (tile.x - col * times) * size, y: (tile.y - row * times) * size, size: size};
        }

        private function usePart(tile:Object, z:int, part:Object):void
        {
            var key:String = z + "/" + part.row + "/" + part.col;
            var parent:Object = m_parents[key];
            if (parent == null)
            {
                parent = {key: key, state: PARENT_LOADING, url: tileURL(z, part.row, part.col), data: null, refs: 0, waiting: []};
                m_parents[key] = parent;
                parent.load = loadImage(parent.url, function(display:DisplayObject, size:Number):void
                {
                    parent.load = null;
                    var bitmap:Bitmap = display as Bitmap;
                    if (bitmap != null)
                    {
                        parent.data = bitmap.bitmapData;
                        parent.state = PARENT_READABLE;
                    }
                    else
                    {
                        // an image that cannot be read can be shown once: every tile loads its own copy
                        disposeDisplay(display);
                        parent.state = PARENT_UNREADABLE;
                    }
                    parentKnown(parent);
                }, function(absent:Boolean):void
                {
                    parent.load = null;
                    parent.state = PARENT_FAILED;
                    parent.absent = absent;
                    imageFailed(z, part.row, part.col, absent);
                    parentKnown(parent);
                });
            }
            parent.refs++;
            tile.parent = parent;
            tile.part = part;
            tile.partLevel = z;
            if (parent.state == PARENT_LOADING)
            {
                parent.waiting.push(tile);
            }
            else
            {
                showPart(tile);
            }
        }

        private function parentKnown(parent:Object):void
        {
            var waiting:Array = parent.waiting;
            parent.waiting = [];
            for each (var tile:Object in waiting)
            {
                if (!tile.released && tile.parent == parent)
                {
                    showPart(tile);
                }
            }
        }

        private function showPart(tile:Object):void
        {
            var parent:Object = tile.parent;
            var part:Object = tile.part;
            var level:int = tile.partLevel;
            if (parent.state == PARENT_FAILED)
            {
                if (!parent.absent)
                {
                    tile.incomplete = true;
                }
                releaseParent(tile);
                resample(tile, level - 1);
                return;
            }
            if (parent.state == PARENT_READABLE)
            {
                // a copy of the part: the tile of the lower level is dropped when no tile waits for it. The copy
                // has one more pixel on every side (within the tile of the lower level), hidden by a scrollRect:
                // when enlarged with smoothing, the pixels of the edge blend with those of the neighbors, so that
                // the parts of neighboring tiles join without a visible edge
                var data:BitmapData = parent.data as BitmapData;
                var scale:Number = data.width / m_tileSize;
                var size:int = Math.max(1, Math.round(part.size * scale));
                var x0:int = Math.round(part.x * scale);
                var y0:int = Math.round(part.y * scale);
                var left:int = x0 > 0 ? 1 : 0;
                var top:int = y0 > 0 ? 1 : 0;
                var right:int = x0 + size < data.width ? 1 : 0;
                var bottom:int = y0 + size < data.height ? 1 : 0;
                var copy:BitmapData = new BitmapData(size + left + right, size + top + bottom, true, 0);
                copy.copyPixels(data, new Rectangle(x0 - left, y0 - top, copy.width, copy.height), new Point(0, 0));
                releaseParent(tile);
                var bitmap:Bitmap = new Bitmap(copy);
                bitmap.x = -left;
                bitmap.y = -top;
                var holder:Sprite = new Sprite();
                holder.addChild(bitmap);
                holder.scrollRect = new Rectangle(0, 0, size, size);
                m_statResampled++;
                finishTile(tile, holder, size);
                return;
            }
            // not readable (another domain, loaded by Flash): its own copy of the image, cut by a scrollRect
            releaseParent(tile);
            var url:String = parent.url;
            tile.load = loadImage(url, function(display:DisplayObject, nativeSize:Number):void
            {
                tile.load = null;
                var scale:Number = nativeSize > 0 ? nativeSize / m_tileSize : 1;
                var holder:Sprite = new Sprite();
                holder.addChild(display);
                display.x = -part.x * scale;
                display.y = -part.y * scale;
                holder.scrollRect = new Rectangle(0, 0, part.size * scale, part.size * scale);
                m_statResampled++;
                finishTile(tile, holder, part.size * scale);
            }, function():void
            {
                tile.load = null;
                resample(tile, level - 1);
            });
        }

        private function releaseParent(tile:Object):void
        {
            var parent:Object = tile.parent;
            tile.parent = null;
            if (parent == null)
            {
                return;
            }
            parent.refs--;
            if (parent.refs <= 0)
            {
                cancelImage(parent.load);
                parent.load = null;
                if (parent.data != null)
                {
                    BitmapData(parent.data).dispose();
                    parent.data = null;
                }
                if (m_parents[parent.key] == parent)
                {
                    delete m_parents[parent.key];
                }
            }
        }

        // ------------------------------------------------------------------
        // images
        // ------------------------------------------------------------------

        /**
         * Loads an image with the transport of the layer. onDone(display, size): a Bitmap when its pixels can be
         * read (decoded from the bytes of the page, or readable anyway), otherwise the Loader that shows it; size
         * is its width in pixels. onFail(absent:Boolean): it cannot be loaded or decoded; absent when that is final
         * (400, 404, 410, or an answer that is not an image), false for other errors and unknown statuses. Returns
         * what cancelImage needs.
         */
        private function loadImage(url:String, onDone:Function, onFail:Function):Object
        {
            var direct:Boolean = !host.proxyTiles;
            var generation:int = m_generation;
            var image:Loader = new Loader();
            var handle:Object = {loader: image, request: null, cancelled: false};
            // HTTP status of the answer (0: not known), and whether an answer was given to the decoder
            var status:int = 0;
            var bytesReceived:Boolean = false;
            var statusHandler:Function = function(event:HTTPStatusEvent):void
            {
                status = event.status;
            };
            var done:Function = function(event:Event):void
            {
                image.contentLoaderInfo.removeEventListener(HTTPStatusEvent.HTTP_STATUS, statusHandler);
                image.contentLoaderInfo.removeEventListener(Event.COMPLETE, done);
                image.contentLoaderInfo.removeEventListener(IOErrorEvent.IO_ERROR, done);
                image.contentLoaderInfo.removeEventListener(SecurityErrorEvent.SECURITY_ERROR, done);
                if (generation != m_generation || handle.cancelled)
                {
                    return;
                }
                if (event.type != Event.COMPLETE)
                {
                    onFail(bytesReceived || isAbsentStatus(status));
                    return;
                }
                var bitmap:Bitmap = null;
                try
                {
                    bitmap = image.content as Bitmap;
                }
                catch (error:Error)
                {
                    // an image of another domain loaded by Flash: shown, but not readable
                }
                if (bitmap != null)
                {
                    // keep only the bitmap
                    onDone(new Bitmap(bitmap.bitmapData), bitmap.bitmapData.width);
                    return;
                }
                var size:Number = NaN;
                try
                {
                    size = image.contentLoaderInfo.width;
                }
                catch (error:Error)
                {
                }
                onDone(image, size);
            };
            image.contentLoaderInfo.addEventListener(HTTPStatusEvent.HTTP_STATUS, statusHandler);
            image.contentLoaderInfo.addEventListener(Event.COMPLETE, done);
            image.contentLoaderInfo.addEventListener(IOErrorEvent.IO_ERROR, done);
            image.contentLoaderInfo.addEventListener(SecurityErrorEvent.SECURITY_ERROR, done);
            if (host.transport == AbstractTileLayer.TRANSPORT_JAVASCRIPT)
            {
                // the page loads the bytes, Flash decodes them
                handle.request = m_loader.load(url, true, function(bytes:ByteArray, request:ResourceRequest):void
                {
                    handle.request = null;
                    if (generation != m_generation || handle.cancelled)
                    {
                        return;
                    }
                    bytesReceived = true;
                    try
                    {
                        image.loadBytes(bytes);
                    }
                    catch (error:Error)
                    {
                        onFail(true);
                    }
                }, function(message:String, request:ResourceRequest):void
                {
                    handle.request = null;
                    if (generation == m_generation && !handle.cancelled)
                    {
                        onFail(isAbsentStatus(request.status));
                    }
                }, false, direct);
            }
            else
            {
                // Flash loads and shows the image: no policy file needed (its pixels are not read)
                try
                {
                    image.load(new URLRequest(m_loader.buildURL(url, direct)), new LoaderContext(false));
                }
                catch (error:Error)
                {
                    onFail(false);
                }
            }
            return handle;
        }

        /** A status that says the tile does not exist (OpenStreetMap answers 400 beyond its levels). */
        private static function isAbsentStatus(status:int):Boolean
        {
            return status == 400 || status == 404 || status == 410;
        }

        private function cancelImage(handle:Object):void
        {
            if (handle == null)
            {
                return;
            }
            handle.cancelled = true;
            if (handle.request != null && m_loader != null)
            {
                m_loader.cancel(handle.request as ResourceRequest);
            }
            handle.request = null;
            try
            {
                Loader(handle.loader).close();
            }
            catch (error:Error)
            {
            }
        }

        private static function disposeDisplay(display:DisplayObject):void
        {
            // a part cut by a scrollRect (resampling): what it holds
            var holder:Sprite = display as Sprite;
            if (holder != null && holder.numChildren > 0)
            {
                display = holder.getChildAt(0);
                holder.removeChildAt(0);
            }
            var bitmap:Bitmap = display as Bitmap;
            if (bitmap != null && bitmap.bitmapData != null)
            {
                bitmap.bitmapData.dispose();
            }
            var loader:Loader = display as Loader;
            if (loader != null)
            {
                try
                {
                    loader.close();
                }
                catch (error:Error)
                {
                }
                loader.unload();
            }
        }

        override public function renderTile(tile:Object):DisplayObject
        {
            return tile.image as DisplayObject;
        }

        override public function nativeSize(tile:Object):Number
        {
            var size:Number = Number(tile.nativeSize);
            return size > 0 ? size : m_tileSize;
        }

        override public function releaseTile(tile:Object):void
        {
            tile.released = true;
            cancelImage(tile.load);
            tile.load = null;
            disposeDisplay(tile.loaded as DisplayObject);
            tile.loaded = null;
            releaseParent(tile);
            disposeDisplay(tile.image as DisplayObject);
            tile.image = null;
        }

        override public function clearData():void
        {
            for each (var parent:Object in m_parents)
            {
                cancelImage(parent.load);
                if (parent.data != null)
                {
                    BitmapData(parent.data).dispose();
                }
            }
            m_parents = {};
            m_blocks = {};
            m_failed = {};
        }

        override public function get timings():String
        {
            return resampling && (m_statResampled > 0 || m_statBlocks > 0) ?
                "resampled " + m_statResampled + " tiles, tilemap blocks " + m_statBlocks + ", " : "";
        }

        override public function resetStats():void
        {
            m_statResampled = 0;
            m_statBlocks = 0;
        }
    }
}
