package org.falpi.ags.layers.vectorTiles.render
{
    import org.falpi.ags.layers.vectorTiles.net.ResourceLoader;
    import org.falpi.ags.layers.vectorTiles.net.ResourceRequest;

    import flash.display.Bitmap;
    import flash.display.BitmapData;
    import flash.display.Loader;
    import flash.events.Event;
    import flash.events.IOErrorEvent;
    import flash.geom.Matrix;
    import flash.geom.Point;
    import flash.geom.Rectangle;
    import flash.utils.ByteArray;

    /**
     * The sprite sheets of a style: icons and fill patterns addressed by name. A style may have several
     * sheets ("sprite" as an array of {id, url}): the images of the sheet "default" are named as they are,
     * those of the others are prefixed with "id:".
     */
    public final class SpriteAtlas
    {
        private static const ZEROS:Array = buildZeros();
        private static const ORIGIN:Point = new Point(0, 0);
        /** Edge of the shape in an SDF icon (alpha 0.75), as in the glyphs. */
        private static const SDF_EDGE:Number = 0.75;
        /** Half width of the antialiased edge of SDF icons, in alpha units at icon-size 1. */
        private static const SDF_GAMMA:Number = 0.09;

        /** id -> {index, sheet} */
        private var m_sheets:Object = {};
        private var m_pending:int = 0;
        private var m_loaded:int = 0;
        private var m_images:Object = {};
        private var m_colored:Object = {};
        private var m_onReady:Function;

        private static function buildZeros():Array
        {
            var zeros:Array = [];
            for (var i:int = 0; i < 256; i++)
            {
                zeros[i] = 0;
            }
            return zeros;
        }

        /** True when at least one sheet is available. */
        public function get ready():Boolean
        {
            return m_loaded > 0;
        }

        /**
         * Loads url + ".json" and url + ".png" for every sheet.
         * @param source a URL (one sheet named "default") or an Array of {id, url}
         * @param onReady called with (success:Boolean) when all the sheets are done; success when at least
         *        one of them loaded
         */
        public function load(source:*, loader:ResourceLoader, onReady:Function):void
        {
            m_onReady = onReady;
            var list:Array = source is Array ? source as Array : [{id: "default", url: String(source)}];
            m_pending = list.length;
            if (m_pending == 0)
            {
                done();
                return;
            }
            for each (var item:Object in list)
            {
                loadSheet(String(item.id), String(item.url), loader);
            }
        }

        private function loadSheet(id:String, url:String, loader:ResourceLoader):void
        {
            var entry:Object = {index: null, sheet: null, failed: false};
            var base:String = url;
            var query:String = "";
            var q:int = url.indexOf("?");
            if (q >= 0)
            {
                base = url.substr(0, q);
                query = url.substr(q);
            }
            var finished:Boolean = false;
            var finish:Function = function(ok:Boolean):void
            {
                if (finished)
                {
                    return;
                }
                if (ok && (entry.index == null || entry.sheet == null))
                {
                    return; // the other half is still loading
                }
                finished = true;
                if (ok)
                {
                    m_sheets[id] = entry;
                    m_loaded++;
                }
                m_pending--;
                if (m_pending == 0)
                {
                    done();
                }
            };
            var fail:Function = function(message:String, request:ResourceRequest):void
            {
                finish(false);
            };
            loader.load(base + ".json" + query, false, function(text:String, request:ResourceRequest):void
            {
                try
                {
                    entry.index = JSON.parse(text);
                }
                catch (error:Error)
                {
                    finish(false);
                    return;
                }
                finish(true);
            }, fail);
            loader.load(base + ".png" + query, true, function(bytes:ByteArray, request:ResourceRequest):void
            {
                var decoder:Loader = new Loader();
                decoder.contentLoaderInfo.addEventListener(Event.COMPLETE, function(event:Event):void
                {
                    var bitmap:Bitmap = decoder.content as Bitmap;
                    entry.sheet = bitmap != null ? bitmap.bitmapData : null;
                    finish(entry.sheet != null);
                });
                decoder.contentLoaderInfo.addEventListener(IOErrorEvent.IO_ERROR, function(event:Event):void
                {
                    finish(false);
                });
                try
                {
                    decoder.loadBytes(bytes);
                }
                catch (error:Error)
                {
                    finish(false);
                }
            }, fail);
        }

        private function done():void
        {
            var callback:Function = m_onReady;
            m_onReady = null;
            if (callback != null)
            {
                callback(m_loaded > 0);
            }
        }

        /** The sheet and the name inside it: [entry, name], or null. */
        private function locate(name:String):Array
        {
            if (name == null)
            {
                return null;
            }
            var colon:int = name.indexOf(":");
            if (colon > 0)
            {
                var prefixed:Object = m_sheets[name.substr(0, colon)];
                if (prefixed != null && name.substr(0, colon) != "default")
                {
                    return [prefixed, name.substr(colon + 1)];
                }
            }
            var entry:Object = m_sheets["default"];
            return entry != null ? [entry, name] : null;
        }

        /** Sprite metadata ({x, y, width, height, pixelRatio, sdf}) or null. */
        public function getInfo(name:String):Object
        {
            var found:Array = locate(name);
            if (found == null)
            {
                return null;
            }
            var index:Object = found[0].index;
            return index != null && index.hasOwnProperty(found[1]) ? index[found[1]] : null;
        }

        /** The sprite as its own BitmapData (cached), or null when unknown. */
        public function getImage(name:String):BitmapData
        {
            if (!ready || name == null)
            {
                return null;
            }
            var cached:* = m_images[name];
            if (cached !== undefined)
            {
                return cached as BitmapData;
            }
            var image:BitmapData = null;
            var found:Array = locate(name);
            var info:Object = getInfo(name);
            if (info != null && info.width > 0 && info.height > 0)
            {
                image = new BitmapData(int(info.width), int(info.height), true, 0);
                image.copyPixels(found[0].sheet, new Rectangle(int(info.x), int(info.y), int(info.width), int(info.height)), ORIGIN);
            }
            m_images[name] = image;
            return image;
        }

        public function getPixelRatio(name:String):Number
        {
            var info:Object = getInfo(name);
            return (info != null && info.pixelRatio > 0) ? Number(info.pixelRatio) : 1;
        }

        /** True for the icons whose alpha is a distance field to be drawn in the icon-color of the style. */
        public function isSdf(name:String):Boolean
        {
            var info:Object = getInfo(name);
            return info != null && info.sdf == true;
        }

        /**
         * An SDF icon drawn in a color at its final size (cached): the distance field is scaled first and
         * converted to coverage afterwards, so the edges stay sharp at every icon-size.
         * @param scale drawn pixels per sprite pixel
         */
        public function getSdfImage(name:String, argb:uint, scale:Number):BitmapData
        {
            var key:String = name + "|" + argb + "|" + scale;
            var cached:* = m_colored[key];
            if (cached !== undefined)
            {
                return cached as BitmapData;
            }
            var result:BitmapData = null;
            var image:BitmapData = getImage(name);
            if (image != null && scale > 0)
            {
                var w:int = Math.max(1, Math.ceil(image.width * scale));
                var h:int = Math.max(1, Math.ceil(image.height * scale));
                var scaled:BitmapData = new BitmapData(w, h, true, 0);
                scaled.draw(image, new Matrix(scale, 0, 0, scale), null, null, null, true);
                var size:Number = scale * getPixelRatio(name);
                var gamma:Number = SDF_GAMMA / Math.max(0.25, size);
                result = new BitmapData(w, h, true, 0);
                result.paletteMap(scaled, scaled.rect, ORIGIN, ZEROS, ZEROS, ZEROS, coverageTable(argb, SDF_EDGE, gamma));
                scaled.dispose();
            }
            m_colored[key] = result;
            return result;
        }

        /** Alpha (distance) 0..255 -> the color with the matching coverage. */
        private static function coverageTable(argb:uint, edge:Number, gamma:Number):Array
        {
            var table:Array = new Array(256);
            var rgb:uint = argb & 0xffffff;
            var alpha:Number = (argb >>> 24) / 255;
            var e0:Number = edge - gamma;
            var e1:Number = edge + gamma;
            for (var i:int = 0; i < 256; i++)
            {
                var t:Number = (i / 255 - e0) / (e1 - e0);
                t = t < 0 ? 0 : (t > 1 ? 1 : t);
                var coverage:Number = t * t * (3 - 2 * t) * alpha;
                table[i] = (uint(coverage * 255 + 0.5) << 24) | rgb;
            }
            return table;
        }
    }
}
