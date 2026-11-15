package org.falpi.ags.net
{
    import flash.external.ExternalInterface;
    import flash.utils.ByteArray;

    /**
     * Requests made by the page that hosts the SWF (fetch) instead of by Flash, through ExternalInterface: the
     * browser applies its CORS rules instead of the crossdomain.xml policies of Flash, so data of servers without a
     * policy but with CORS (the Esri basemap servers) can be read without a proxy.
     *
     * <p>The script of the page is installed by the SWF itself. The answers come back as base64 text (binary data
     * cannot cross ExternalInterface) and are decoded here.</p>
     */
    public final class JavaScriptTransport
    {
        /** Script installed in the page: window.__vtFetch(callback, id, url) and window.__vtAbort(id). */
        private static const SCRIPT:String = "function(){" +
            "if(window.__vtFetch){return true;}" +
            "var controllers={};" +
            "function target(cb){var list=document.querySelectorAll('embed,object');" +
            "for(var i=0;i<list.length;i++){try{if(typeof list[i][cb]==='function'){return list[i];}}catch(e){}}return null;}" +
            "function answer(cb,id,status,data,error){var element=target(cb);if(element){element[cb](id,status,data,error);}}" +
            "window.__vtFetch=function(cb,id,url){" +
            // the requests of every SWF of the page share the script: keyed by callback (one per SWF) and id
            "var key=cb+'#'+id;" +
            "var controller=window.AbortController?new AbortController():null;if(controller){controllers[key]=controller;}" +
            "fetch(url,controller?{signal:controller.signal}:{}).then(function(response){" +
            "return response.arrayBuffer().then(function(buffer){" +
            "var reader=new FileReader();" +
            "reader.onload=function(){delete controllers[key];var text=reader.result;answer(cb,id,response.status,text.substr(text.indexOf(',')+1),null);};" +
            "reader.onerror=function(){delete controllers[key];answer(cb,id,0,null,'read error');};" +
            "reader.readAsDataURL(new Blob([buffer]));});" +
            "})['catch'](function(error){delete controllers[key];if(error&&error.name==='AbortError'){return;}answer(cb,id,0,null,String(error));});" +
            "return true;};" +
            "window.__vtAbort=function(cb,id){var key=cb+'#'+id;var controller=controllers[key];if(controller){delete controllers[key];controller.abort();}return true;};" +
            "return true;}";

        private static const LOOKUP:Vector.<int> = buildLookup();

        /** 0: not tried yet, 1: installed, -1: not available. */
        private static var s_state:int = 0;
        private static var s_callback:String;
        private static var s_pending:Object = {};
        private static var s_next:int = 1;

        /** Whether the page can make the requests (installs the script the first time). */
        public static function get available():Boolean
        {
            if (s_state == 0)
            {
                s_state = -1;
                try
                {
                    if (ExternalInterface.available)
                    {
                        s_callback = "vtFetchResult" + int(Math.random() * 1000000000);
                        ExternalInterface.addCallback(s_callback, answer);
                        if (ExternalInterface.call(SCRIPT) === true)
                        {
                            s_state = 1;
                        }
                    }
                }
                catch (error:Error)
                {
                }
            }
            return s_state == 1;
        }

        /**
         * Starts a request. onDone receives (bytes:ByteArray, status:int, error:String): bytes is null when the
         * request failed. Returns the id to cancel it.
         */
        public static function load(url:String, onDone:Function):int
        {
            var id:int = s_next++;
            s_pending[id] = onDone;
            try
            {
                ExternalInterface.call("__vtFetch", s_callback, id, url);
            }
            catch (error:Error)
            {
                delete s_pending[id];
                onDone(null, 0, error.message);
            }
            return id;
        }

        public static function cancel(id:int):void
        {
            if (s_pending[id] === undefined)
            {
                return;
            }
            delete s_pending[id];
            try
            {
                ExternalInterface.call("__vtAbort", s_callback, id);
            }
            catch (error:Error)
            {
            }
        }

        /** Called by the page with the answer of a request. */
        private static function answer(id:int, status:int, data:String, error:String):void
        {
            var onDone:Function = s_pending[id] as Function;
            if (onDone == null)
            {
                return;
            }
            delete s_pending[id];
            var bytes:ByteArray = data != null ? decode(data) : null;
            onDone(bytes, status, error);
        }

        private static function buildLookup():Vector.<int>
        {
            var table:Vector.<int> = new Vector.<int>(256, true);
            for (var i:int = 0; i < 256; i++)
            {
                table[i] = -1;
            }
            var alphabet:String = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
            for (i = 0; i < 64; i++)
            {
                table[alphabet.charCodeAt(i)] = i;
            }
            return table;
        }

        /** Decodes base64 text (no line breaks, padding optional). */
        public static function decode(text:String):ByteArray
        {
            var bytes:ByteArray = new ByteArray();
            var length:int = text.length;
            while (length > 0 && text.charCodeAt(length - 1) == 61)
            {
                length--;
            }
            var table:Vector.<int> = LOOKUP;
            var full:int = length - length % 4;
            var i:int = 0;
            var n:int;
            while (i < full)
            {
                n = (table[text.charCodeAt(i)] << 18) | (table[text.charCodeAt(i + 1)] << 12) |
                    (table[text.charCodeAt(i + 2)] << 6) | table[text.charCodeAt(i + 3)];
                bytes.writeByte(n >> 16);
                bytes.writeByte(n >> 8);
                bytes.writeByte(n);
                i += 4;
            }
            var rest:int = length - full;
            if (rest >= 2)
            {
                n = (table[text.charCodeAt(i)] << 18) | (table[text.charCodeAt(i + 1)] << 12);
                if (rest == 3)
                {
                    n |= table[text.charCodeAt(i + 2)] << 6;
                }
                bytes.writeByte(n >> 16);
                if (rest == 3)
                {
                    bytes.writeByte(n >> 8);
                }
            }
            bytes.position = 0;
            return bytes;
        }
    }
}
