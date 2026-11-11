package org.falpi.ags.layers.vectorTiles.style
{
    import org.falpi.ags.layers.vectorTiles.mvt.MvtFeature;

    /** One layer of a Mapbox GL style document. */
    public final class StyleLayer
    {
        // property name -> [type, default]
        private static const SPEC:Object = {
            "background-color": ["color", "#000000"], "background-opacity": ["number", 1], "background-pattern": ["string", null],
            "fill-antialias": ["boolean", true], "fill-opacity": ["number", 1], "fill-color": ["color", "#000000"],
            "fill-outline-color": ["color", null], "fill-translate": ["array", [0, 0]], "fill-pattern": ["string", null],
            "fill-extrusion-color": ["color", "#000000"], "fill-extrusion-opacity": ["number", 1],
            "fill-extrusion-translate": ["array", [0, 0]],
            "line-opacity": ["number", 1], "line-color": ["color", "#000000"], "line-translate": ["array", [0, 0]],
            "line-width": ["number", 1], "line-gap-width": ["number", 0], "line-offset": ["number", 0],
            "line-blur": ["number", 0], "line-dasharray": ["dash", null], "line-pattern": ["string", null],
            "circle-radius": ["number", 5], "circle-color": ["color", "#000000"], "circle-opacity": ["number", 1],
            "circle-stroke-width": ["number", 0], "circle-stroke-color": ["color", "#000000"],
            "circle-stroke-opacity": ["number", 1], "circle-translate": ["array", [0, 0]],
            "icon-opacity": ["number", 1], "icon-color": ["color", "#000000"], "icon-translate": ["array", [0, 0]],
            "text-opacity": ["number", 1], "text-color": ["color", "#000000"], "text-halo-color": ["color", "rgba(0,0,0,0)"],
            "text-halo-width": ["number", 0], "text-halo-blur": ["number", 0], "text-translate": ["array", [0, 0]],
            "visibility": ["string", "visible"],
            "line-cap": ["string", "butt"], "line-join": ["string", "miter"], "line-miter-limit": ["number", 2],
            "symbol-placement": ["string", "point"], "symbol-spacing": ["number", 250], "symbol-avoid-edges": ["boolean", false],
            "symbol-sort-key": ["number", 0],
            "icon-allow-overlap": ["boolean", false], "icon-ignore-placement": ["boolean", false], "icon-optional": ["boolean", false],
            "icon-rotation-alignment": ["string", "auto"], "icon-size": ["number", 1], "icon-image": ["string", null],
            "icon-rotate": ["number", 0], "icon-padding": ["number", 2], "icon-keep-upright": ["boolean", false],
            "icon-offset": ["array", [0, 0]], "icon-anchor": ["string", "center"],
            "text-rotation-alignment": ["string", "auto"], "text-field": ["string", ""],
            "text-font": ["strings", ["Open Sans Regular", "Arial Unicode MS Regular"]], "text-size": ["number", 16],
            "text-max-width": ["number", 10], "text-line-height": ["number", 1.2], "text-letter-spacing": ["number", 0],
            "text-justify": ["string", "center"], "text-anchor": ["string", "center"], "text-max-angle": ["number", 45],
            "text-rotate": ["number", 0], "text-padding": ["number", 2], "text-keep-upright": ["boolean", true],
            "text-transform": ["string", "none"], "text-offset": ["array", [0, 0]], "text-allow-overlap": ["boolean", false],
            "text-ignore-placement": ["boolean", false], "text-optional": ["boolean", false]
        };

        public var id:String;
        public var type:String;
        public var source:String;
        public var sourceLayer:String;
        public var minzoom:Number = 0;
        public var maxzoom:Number = 99;
        public var filter:Filter;
        public var visible:Boolean = true;
        /** Position of the layer in the style (drawing order). */
        public var index:int;

        private var m_properties:Object = {};
        private var m_specified:Object = {};

        public function StyleLayer(json:Object, index:int)
        {
            this.index = index;
            id = json.id;
            type = json.type;
            source = json.source;
            sourceLayer = json["source-layer"];
            if (json.hasOwnProperty("minzoom"))
            {
                minzoom = Number(json.minzoom);
            }
            if (json.hasOwnProperty("maxzoom"))
            {
                maxzoom = Number(json.maxzoom);
            }
            filter = new Filter(json.hasOwnProperty("filter") ? json.filter : null);
            addProperties(json.paint);
            addProperties(json.layout);
            visible = value("visibility", 0) != "none";
        }

        private function addProperties(group:Object):void
        {
            if (group == null)
            {
                return;
            }
            for (var name:String in group)
            {
                m_properties[name] = createProperty(name, group[name]);
                m_specified[name] = true;
            }
        }

        private static function createProperty(name:String, raw:*):StyleProperty
        {
            var spec:Array = SPEC[name] as Array;
            var type:String = spec != null ? spec[0] : "string";
            var fallback:* = spec != null ? spec[1] : null;
            if (type == "color")
            {
                fallback = fallback == null ? null : StyleColor.parse(String(fallback));
            }
            var propertyType:String = type;
            if (type == "strings" || type == "dash")
            {
                // arrays that must not be interpolated between stops
                propertyType = StyleProperty.STRING;
            }
            return new StyleProperty(name, raw, propertyType, fallback);
        }

        /** True when the style explicitly sets the property. */
        public function has(name:String):Boolean
        {
            return m_specified.hasOwnProperty(name);
        }

        public function property(name:String):StyleProperty
        {
            var p:StyleProperty = m_properties[name] as StyleProperty;
            if (p == null)
            {
                p = createProperty(name, null);
                m_properties[name] = p;
            }
            return p;
        }

        /** Evaluates a paint or layout property. */
        public function value(name:String, zoom:Number, feature:MvtFeature = null):*
        {
            return property(name).evaluate(zoom, feature);
        }

        public function isVisibleAt(zoom:Number):Boolean
        {
            return visible && zoom >= minzoom && zoom < maxzoom;
        }
    }
}
