package org.falpi.ags.layers.vectorTiles.util
{
    /** URL helpers (relative resolution, query handling, mapbox:// scheme). */
    public final class UrlUtil
    {
        private static const SCHEME:RegExp = /^[a-zA-Z][a-zA-Z0-9+.\-]*:/;

        public static function isAbsolute(url:String):Boolean
        {
            return SCHEME.test(url) || url.indexOf("//") == 0;
        }

        public static function stripQuery(url:String):String
        {
            var i:int = url.indexOf("?");
            if (i >= 0)
            {
                url = url.substr(0, i);
            }
            i = url.indexOf("#");
            return i >= 0 ? url.substr(0, i) : url;
        }

        public static function getQuery(url:String):String
        {
            var i:int = url.indexOf("?");
            if (i < 0)
            {
                return "";
            }
            var q:String = url.substr(i + 1);
            i = q.indexOf("#");
            return i >= 0 ? q.substr(0, i) : q;
        }

        public static function appendQuery(url:String, query:String):String
        {
            if (query == null || query.length == 0)
            {
                return url;
            }
            return url + (url.indexOf("?") >= 0 ? "&" : "?") + query;
        }

        /** Resolves a possibly relative URL against a base URL. */
        public static function resolve(base:String, relative:String):String
        {
            if (relative == null || relative.length == 0)
            {
                return base;
            }
            if (isAbsolute(relative))
            {
                // absolute URLs keep their own base; only "." and ".." segments are collapsed
                // (some CDNs reject them)
                var path0:String = stripQuery(relative);
                if (path0.indexOf("/./") < 0 && path0.indexOf("/../") < 0)
                {
                    return relative;
                }
                var cut:int = path0.lastIndexOf("/") + 1;
                var last:String = relative.substr(cut);
                return resolve(relative.substr(0, cut), last.length > 0 ? last : ".");
            }
            if (base == null)
            {
                return relative;
            }
            var path:String = stripQuery(base);
            var originEnd:int = 0;
            var schemeMatch:Object = SCHEME.exec(path);
            if (schemeMatch != null)
            {
                originEnd = String(schemeMatch[0]).length;
                if (path.substr(originEnd, 2) == "//")
                {
                    var slash:int = path.indexOf("/", originEnd + 2);
                    originEnd = slash < 0 ? path.length : slash;
                }
            }
            var origin:String = path.substr(0, originEnd);
            var basePath:String = path.substr(originEnd);
            if (relative.charAt(0) == "/")
            {
                return origin + normalize(relative);
            }
            var dir:String = basePath.substr(0, basePath.lastIndexOf("/") + 1);
            return origin + normalize(dir + relative);
        }

        private static function normalize(path:String):String
        {
            var query:String = "";
            var q:int = path.indexOf("?");
            if (q >= 0)
            {
                query = path.substr(q);
                path = path.substr(0, q);
            }
            var leading:Boolean = path.charAt(0) == "/";
            var segments:Array = path.split("/");
            var out:Array = [];
            for (var i:int = 0; i < segments.length; i++)
            {
                var segment:String = segments[i];
                var last:Boolean = i == segments.length - 1;
                if (segment == "..")
                {
                    if (out.length > 0 && out[out.length - 1] != "..")
                    {
                        out.pop();
                    }
                    else if (!leading)
                    {
                        // relative base: keep climbing
                        out.push("..");
                    }
                    if (last)
                    {
                        out.push("");
                    }
                }
                else if (segment == ".")
                {
                    if (last)
                    {
                        out.push("");
                    }
                }
                else if (segment.length > 0 || last)
                {
                    out.push(segment);
                }
            }
            return (leading ? "/" : "") + out.join("/") + query;
        }

        /** Converts mapbox:// URLs into https://api.mapbox.com URLs. */
        public static function normalizeMapbox(url:String):String
        {
            if (url == null || url.indexOf("mapbox://") != 0)
            {
                return url;
            }
            var rest:String = url.substr(9);
            var api:String = "https://api.mapbox.com";
            if (rest.indexOf("styles/") == 0)
            {
                return api + "/styles/v1/" + rest.substr(7);
            }
            if (rest.indexOf("sprites/") == 0)
            {
                return api + "/styles/v1/" + rest.substr(8) + "/sprite";
            }
            if (rest.indexOf("fonts/") == 0)
            {
                return api + "/fonts/v1/" + rest.substr(6);
            }
            return api + "/v4/" + rest + ".json?secure";
        }

        /** Replaces {name} tokens using the given values object. */
        public static function template(url:String, values:Object):String
        {
            return url.replace(/\{([^{}]+)\}/g, function(...args):String
            {
                var key:String = args[1];
                return values.hasOwnProperty(key) ? String(values[key]) : args[0];
            });
        }
    }
}
