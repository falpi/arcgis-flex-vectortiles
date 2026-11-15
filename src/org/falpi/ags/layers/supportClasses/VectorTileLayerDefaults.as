package org.falpi.ags.layers.supportClasses
{
    /**
     * Defaults of the vector basemaps (VectorTileLayer.defaults): those of every tile layer (see TileLayerDefaults),
     * here for the vector basemaps only, and the settings of the vector basemaps.
     */
    public class VectorTileLayerDefaults extends TileLayerDefaults
    {
        public function VectorTileLayerDefaults()
        {
            // "arcgis" written here: this object is created while VectorContent is initialized, before its
            // constants can be read
            super({tilingScheme: "arcgis", labelsVisible: true, minimumHaloWidth: 1.5, minimumHaloAlpha: 0.8});
        }

        [Inspectable(enumeration="arcgis,service")]
        /** Levels of detail of the vector basemaps: "arcgis" or "service" (library: "arcgis"). */
        public function get tilingScheme():String
        {
            return getValue("tilingScheme") as String;
        }

        public function set tilingScheme(value:String):void
        {
            store("tilingScheme", value != null && value.length > 0 ? value : null);
        }

        /** Whether labels and icons are shown (library: true). */
        public function get labelsVisible():Boolean
        {
            return getValue("labelsVisible") == true;
        }

        public function set labelsVisible(value:Boolean):void
        {
            store("labelsVisible", value);
        }

        /** Halo width given to the labels whose style has none (library: 1.5). */
        public function get minimumHaloWidth():Number
        {
            var value:* = getValue("minimumHaloWidth");
            return value is Number ? Number(value) : NaN;
        }

        public function set minimumHaloWidth(value:Number):void
        {
            store("minimumHaloWidth", value);
        }

        /** Color of that halo as 0xRRGGBB (library: NaN, white or black depending on the text). */
        public function get minimumHaloColor():Number
        {
            var value:* = getValue("minimumHaloColor");
            return value is Number ? Number(value) : NaN;
        }

        public function set minimumHaloColor(value:Number):void
        {
            store("minimumHaloColor", value);
        }

        /** Opacity of that halo, 0 to 1 (library: 0.8). */
        public function get minimumHaloAlpha():Number
        {
            var value:* = getValue("minimumHaloAlpha");
            return value is Number ? Number(value) : NaN;
        }

        public function set minimumHaloAlpha(value:Number):void
        {
            store("minimumHaloAlpha", value);
        }
    }
}
