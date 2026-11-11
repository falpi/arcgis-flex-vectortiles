package org.falpi.ags.layers.vectorTiles.style
{
    import org.falpi.ags.layers.vectorTiles.util.UrlUtil;

    /** A parsed Mapbox GL style document (version 8). */
    public final class Style
    {
        public var name:String;
        public var version:int = 8;
        /** Layers in drawing order. */
        public var layers:Vector.<StyleLayer> = new Vector.<StyleLayer>();
        /** Raw "sources" object of the style. */
        public var sources:Object = {};
        /** Absolute sprite URL without extension, or null. */
        public var spriteURL:String;
        /** Absolute glyphs URL template ({fontstack}, {range}), or null. */
        public var glyphsURL:String;
        public var hasSymbols:Boolean = false;

        public function Style(json:Object, baseURL:String)
        {
            if (json == null || !(json.layers is Array))
            {
                throw new Error("Invalid style document: 'layers' is missing");
            }
            name = json.name;
            if (json.hasOwnProperty("version"))
            {
                version = int(json.version);
            }
            if (json.sources != null)
            {
                sources = json.sources;
            }
            if (json.sprite is String)
            {
                spriteURL = UrlUtil.resolve(baseURL, UrlUtil.normalizeMapbox(String(json.sprite)));
            }
            if (json.glyphs is String)
            {
                glyphsURL = UrlUtil.resolve(baseURL, UrlUtil.normalizeMapbox(String(json.glyphs)));
            }
            var byId:Object = {};
            var list:Array = json.layers as Array;
            for (var i:int = 0; i < list.length; i++)
            {
                var layerJson:Object = list[i];
                if (layerJson == null)
                {
                    continue;
                }
                if (layerJson.hasOwnProperty("ref") && byId.hasOwnProperty(layerJson.ref))
                {
                    // style spec v7 "ref" layers share type, source and filter with another layer
                    layerJson = mergeRef(layerJson, byId[layerJson.ref]);
                }
                byId[layerJson.id] = layerJson;
                var layer:StyleLayer = new StyleLayer(layerJson, layers.length);
                layers.push(layer);
                if (layer.type == "symbol" && layer.visible)
                {
                    hasSymbols = true;
                }
            }
        }

        private static function mergeRef(layer:Object, parent:Object):Object
        {
            var merged:Object = {};
            var key:String;
            for (key in layer)
            {
                merged[key] = layer[key];
            }
            for each (key in ["type", "source", "source-layer", "minzoom", "maxzoom", "filter", "layout"])
            {
                if (parent.hasOwnProperty(key))
                {
                    merged[key] = parent[key];
                }
            }
            return merged;
        }
    }
}
