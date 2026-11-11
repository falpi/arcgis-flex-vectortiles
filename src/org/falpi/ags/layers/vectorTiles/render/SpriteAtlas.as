package org.falpi.ags.layers.vectorTiles.render
{
    import org.falpi.ags.layers.vectorTiles.net.ResourceLoader;
    import org.falpi.ags.layers.vectorTiles.net.ResourceRequest;

    import flash.display.Bitmap;
    import flash.display.BitmapData;
    import flash.display.Loader;
    import flash.events.Event;
    import flash.events.IOErrorEvent;
    import flash.geom.Point;
    import flash.geom.Rectangle;
    import flash.utils.ByteArray;

    /** The sprite sheet of a style: icons and fill patterns addressed by name. */
    public final class SpriteAtlas
    {
        private var m_index:Object;
        private var m_sheet:BitmapData;
        private var m_images:Object = {};
        private var m_decoder:Loader;
        private var m_onReady:Function;

        public function get ready():Boolean
        {
            return m_index != null && m_sheet != null;
        }

        /**
         * Loads url + ".json" and url + ".png".
         * onReady is called with (success:Boolean).
         */
        public function load(url:String, loader:ResourceLoader, onReady:Function):void
        {
            m_onReady = onReady;
            var base:String = url;
            var query:String = "";
            var q:int = url.indexOf("?");
            if (q >= 0)
            {
                base = url.substr(0, q);
                query = url.substr(q);
            }
            loader.load(base + ".json" + query, false, function(text:String, request:ResourceRequest):void
            {
                try
                {
                    m_index = JSON.parse(text);
                }
                catch (error:Error)
                {
                    done(false);
                    return;
                }
                check();
            }, failed);
            loader.load(base + ".png" + query, true, function(bytes:ByteArray, request:ResourceRequest):void
            {
                m_decoder = new Loader();
                m_decoder.contentLoaderInfo.addEventListener(Event.COMPLETE, decoded);
                m_decoder.contentLoaderInfo.addEventListener(IOErrorEvent.IO_ERROR, decodeFailed);
                try
                {
                    m_decoder.loadBytes(bytes);
                }
                catch (error:Error)
                {
                    done(false);
                }
            }, failed);
        }

        private function decoded(event:Event):void
        {
            var bitmap:Bitmap = m_decoder.content as Bitmap;
            if (bitmap != null)
            {
                m_sheet = bitmap.bitmapData;
            }
            m_decoder = null;
            if (m_sheet == null)
            {
                done(false);
            }
            else
            {
                check();
            }
        }

        private function decodeFailed(event:Event):void
        {
            m_decoder = null;
            done(false);
        }

        private function failed(message:String, request:ResourceRequest):void
        {
            done(false);
        }

        private function check():void
        {
            if (ready)
            {
                done(true);
            }
        }

        private function done(success:Boolean):void
        {
            var callback:Function = m_onReady;
            m_onReady = null;
            if (callback != null)
            {
                callback(success);
            }
        }

        /** Sprite metadata ({x, y, width, height, pixelRatio, sdf}) or null. */
        public function getInfo(name:String):Object
        {
            return (m_index != null && name != null && m_index.hasOwnProperty(name)) ? m_index[name] : null;
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
            var info:Object = getInfo(name);
            if (info != null && info.width > 0 && info.height > 0)
            {
                image = new BitmapData(int(info.width), int(info.height), true, 0);
                image.copyPixels(m_sheet, new Rectangle(int(info.x), int(info.y), int(info.width), int(info.height)), new Point(0, 0));
            }
            m_images[name] = image;
            return image;
        }

        public function getPixelRatio(name:String):Number
        {
            var info:Object = getInfo(name);
            return (info != null && info.pixelRatio > 0) ? Number(info.pixelRatio) : 1;
        }
    }
}
