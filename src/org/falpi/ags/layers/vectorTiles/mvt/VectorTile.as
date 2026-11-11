package org.falpi.ags.layers.vectorTiles.mvt
{
    import org.falpi.ags.layers.vectorTiles.pbf.PbfReader;

    import flash.utils.ByteArray;

    /**
     * A decoded Mapbox Vector Tile (specification 1.x / 2.x).
     * Layers are indexed by name; features are decoded lazily per layer.
     */
    public final class VectorTile
    {
        /** Layer name -> MvtLayer. */
        public var layers:Object = {};

        public function VectorTile(bytes:ByteArray)
        {
            var pbf:PbfReader = new PbfReader(bytes);
            while (pbf.next())
            {
                if (pbf.tag == 3 && pbf.wireType == PbfReader.BYTES)
                {
                    var start:uint = pbf.readRange();
                    var layer:MvtLayer = new MvtLayer(bytes, start, pbf.lastLength);
                    if (layer.name != null)
                    {
                        layers[layer.name] = layer;
                    }
                }
                else
                {
                    pbf.skip();
                }
            }
        }

        public function getLayer(name:String):MvtLayer
        {
            return layers[name] as MvtLayer;
        }
    }
}
