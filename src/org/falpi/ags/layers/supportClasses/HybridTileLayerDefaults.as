package org.falpi.ags.layers.supportClasses
{
    /**
     * Defaults of HybridTileLayer (HybridTileLayer.defaults): the criteria that choose the basemap, not settings
     * of the tile layer. The settings of the layer come from AbstractTileLayer.defaults and from the defaults of
     * the kind of basemap shown (RasterTileLayer.defaults, VectorTileLayer.defaults). All start not set.
     *
     * <listing version="3.0">
     * HybridTileLayer.defaults.layerMap = new XML(String(new BasemapsFile()));
     * HybridTileLayer.defaults.layerType = "vector";   // every HybridTileLayer: the vector form of its basemap
     * </listing>
     */
    public class HybridTileLayerDefaults extends LayerDefaults
    {
        public function HybridTileLayerDefaults()
        {
            super();
        }

        /** The map of basemaps of the layers that set none: XML (or its text) or JSON (parsed or its text). */
        public function get layerMap():Object
        {
            return getValue("layerMap");
        }

        public function set layerMap(value:Object):void
        {
            store("layerMap", value);
        }

        [Inspectable(enumeration="vector,raster")]
        /** layerType of the layers that set none: "vector" or "raster" (not set: the first layer of the basemap). */
        public function get layerType():String
        {
            return getValue("layerType") as String;
        }

        public function set layerType(value:String):void
        {
            store("layerType", value != null && value.length > 0 ? value : null);
        }

        [Inspectable(enumeration="esri,tiled")]
        /** layerFormat of the layers that set none: "esri" or "tiled" (not set: the first raster layer). */
        public function get layerFormat():String
        {
            return getValue("layerFormat") as String;
        }

        public function set layerFormat(value:String):void
        {
            store("layerFormat", value != null && value.length > 0 ? value : null);
        }
    }
}
