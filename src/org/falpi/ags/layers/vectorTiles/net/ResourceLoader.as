package org.falpi.ags.layers.vectorTiles.net
{
    import org.falpi.ags.layers.vectorTiles.util.UrlUtil;

    import flash.events.Event;
    import flash.events.HTTPStatusEvent;
    import flash.events.IOErrorEvent;
    import flash.events.SecurityErrorEvent;
    import flash.net.URLLoader;
    import flash.net.URLLoaderDataFormat;
    import flash.net.URLRequest;
    import flash.utils.ByteArray;

    /**
     * Queued loader for the text and binary resources of a vector basemap
     * (style, service metadata, tiles, sprites, glyphs). Applies the proxy
     * and the token, limits the number of parallel connections and
     * transparently inflates gzip payloads.
     */
    public final class ResourceLoader
    {
        /** Proxy page URL; requests are sent as proxyURL?targetURL (ArcGIS proxy convention). */
        public var proxyURL:String;
        /** Token (or API key) appended to http(s) requests. */
        public var token:String;
        /** Name of the query parameter carrying the token. */
        public var tokenParameter:String = "token";
        public var maxConnections:int = 6;

        private var m_queue:Vector.<ResourceRequest> = new Vector.<ResourceRequest>();
        private var m_active:int = 0;
        private var m_running:Vector.<ResourceRequest> = new Vector.<ResourceRequest>();

        /**
         * Queues a request.
         * onComplete receives (data:*, request:ResourceRequest) where data is a String or a ByteArray.
         * onError receives (message:String, request:ResourceRequest).
         */
        public function load(url:String, binary:Boolean, onComplete:Function, onError:Function, urgent:Boolean = false):ResourceRequest
        {
            var request:ResourceRequest = new ResourceRequest();
            request.url = url;
            request.binary = binary;
            request.onComplete = onComplete;
            request.onError = onError;
            if (urgent)
            {
                m_queue.unshift(request);
            }
            else
            {
                m_queue.push(request);
            }
            pump();
            return request;
        }

        public function cancel(request:ResourceRequest):void
        {
            if (request == null || request.finished)
            {
                return;
            }
            request.cancelled = true;
            request.finished = true;
            var index:int = m_queue.indexOf(request);
            if (index >= 0)
            {
                m_queue.splice(index, 1);
                return;
            }
            if (request.loader != null)
            {
                untrack(request);
                release(request);
                try
                {
                    request.loader.close();
                }
                catch (error:Error)
                {
                }
                request.loader = null;
                m_active--;
                pump();
            }
        }

        public function cancelAll():void
        {
            var pending:Vector.<ResourceRequest> = m_queue.concat(m_running);
            for each (var request:ResourceRequest in pending)
            {
                cancel(request);
            }
        }

        /** Builds the URL actually requested (token and proxy applied). */
        public function buildURL(url:String):String
        {
            var isHttp:Boolean = /^https?:/i.test(url);
            if (isHttp && token != null && token.length > 0 && url.indexOf(tokenParameter + "=") < 0)
            {
                url = UrlUtil.appendQuery(url, tokenParameter + "=" + encodeURIComponent(token));
            }
            if (isHttp && proxyURL != null && proxyURL.length > 0)
            {
                url = proxyURL + "?" + url;
            }
            return url;
        }

        private function pump():void
        {
            while (m_active < maxConnections && m_queue.length > 0)
            {
                start(m_queue.shift());
            }
        }

        private function start(request:ResourceRequest):void
        {
            var loader:URLLoader = new URLLoader();
            loader.dataFormat = request.binary ? URLLoaderDataFormat.BINARY : URLLoaderDataFormat.TEXT;
            request.loader = loader;
            request.handler = function(event:Event):void
            {
                handle(request, event);
            };
            loader.addEventListener(Event.COMPLETE, request.handler);
            loader.addEventListener(IOErrorEvent.IO_ERROR, request.handler);
            loader.addEventListener(SecurityErrorEvent.SECURITY_ERROR, request.handler);
            loader.addEventListener(HTTPStatusEvent.HTTP_STATUS, request.handler);
            m_active++;
            m_running.push(request);
            try
            {
                loader.load(new URLRequest(buildURL(request.url)));
            }
            catch (error:Error)
            {
                finish(request, null, error.message);
            }
        }

        private function untrack(request:ResourceRequest):void
        {
            var index:int = m_running.indexOf(request);
            if (index >= 0)
            {
                m_running.splice(index, 1);
            }
        }

        private function release(request:ResourceRequest):void
        {
            var loader:URLLoader = request.loader;
            if (loader != null && request.handler != null)
            {
                loader.removeEventListener(Event.COMPLETE, request.handler);
                loader.removeEventListener(IOErrorEvent.IO_ERROR, request.handler);
                loader.removeEventListener(SecurityErrorEvent.SECURITY_ERROR, request.handler);
                loader.removeEventListener(HTTPStatusEvent.HTTP_STATUS, request.handler);
            }
            request.handler = null;
        }

        private function handle(request:ResourceRequest, event:Event):void
        {
            if (event is HTTPStatusEvent)
            {
                request.status = (event as HTTPStatusEvent).status;
                return;
            }
            if (event.type == Event.COMPLETE)
            {
                var data:* = request.loader.data;
                try
                {
                    if (request.binary)
                    {
                        data = gunzipIfNeeded(data as ByteArray);
                    }
                    else if (data is String && String(data).charCodeAt(0) == 0xFEFF)
                    {
                        data = String(data).substr(1);
                    }
                }
                catch (error:Error)
                {
                    finish(request, null, "Invalid compressed data: " + error.message);
                    return;
                }
                finish(request, data, null);
            }
            else
            {
                var text:String = event.hasOwnProperty("text") ? String(event["text"]) : event.type;
                finish(request, null, text);
            }
        }

        private function finish(request:ResourceRequest, data:*, error:String):void
        {
            if (request.finished)
            {
                return;
            }
            request.finished = true;
            untrack(request);
            release(request);
            request.loader = null;
            m_active--;
            if (error != null)
            {
                if (request.onError != null)
                {
                    request.onError(error + " [" + request.url + "]", request);
                }
            }
            else if (request.onComplete != null)
            {
                request.onComplete(data, request);
            }
            pump();
        }

        /** Inflates a gzip stream; any other payload is returned untouched. */
        public static function gunzipIfNeeded(bytes:ByteArray):ByteArray
        {
            if (bytes == null || bytes.length < 18 || bytes[0] != 0x1f || bytes[1] != 0x8b || bytes[2] != 8)
            {
                return bytes;
            }
            var flags:uint = bytes[3];
            var pos:uint = 10;
            if (flags & 4)
            {
                pos += 2 + (bytes[pos] | (bytes[pos + 1] << 8));
            }
            if (flags & 8)
            {
                while (pos < bytes.length && bytes[pos++] != 0)
                {
                }
            }
            if (flags & 16)
            {
                while (pos < bytes.length && bytes[pos++] != 0)
                {
                }
            }
            if (flags & 2)
            {
                pos += 2;
            }
            var out:ByteArray = new ByteArray();
            out.writeBytes(bytes, pos, bytes.length - pos - 8);
            out.inflate();
            out.position = 0;
            return out;
        }
    }
}
